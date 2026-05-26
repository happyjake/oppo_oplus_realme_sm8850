#!/usr/bin/env bash
# Add `ksud susfs keep-visible add <path>` CLI to ksud.
# Run with CWD at $kernel_workspace/KernelSU/userspace/ksud/.
set -euo pipefail

log() { printf '[keep-visible/ksud] %s\n' "$*"; }

[ -f src/android/susfs.rs ] || { echo "ERROR: not in ksud src tree"; exit 2; }
[ -f src/android/cli.rs   ] || { echo "ERROR: not in ksud src tree"; exit 2; }

# ---------------------------------------------------------------------------
# 1. src/android/susfs.rs — add the syscall wrapper
# ---------------------------------------------------------------------------
if grep -q "fn add_keep_visible" src/android/susfs.rs; then
    log "susfs.rs already patched, skipping"
else
    log "appending add_keep_visible() to src/android/susfs.rs"
    cat >> src/android/susfs.rs <<'EOF'

// keep-visible — pin a specific mount so susfs's clone_mnt() does not
// substitute a fake vfsmnt for it on zygote fork. The mount becomes visible
// to apps; everything else (and /proc/self/mounts filtering) is unchanged.
const CMD_SUSFS_ADD_KEEP_VISIBLE: u32 = 0x60030;
const SUSFS_MAX_LEN_PATHNAME: usize = 256;

#[repr(C)]
struct SusfsKeepVisible {
    target_pathname: [u8; SUSFS_MAX_LEN_PATHNAME],
    err: i32,
}

pub fn add_keep_visible(path: &str) -> anyhow::Result<()> {
    let bytes = path.as_bytes();
    if bytes.len() >= SUSFS_MAX_LEN_PATHNAME {
        anyhow::bail!("path too long (>= {} bytes)", SUSFS_MAX_LEN_PATHNAME);
    }
    let mut cmd = SusfsKeepVisible {
        target_pathname: [0; SUSFS_MAX_LEN_PATHNAME],
        err: ERR_CMD_NOT_SUPPORTED,
    };
    cmd.target_pathname[..bytes.len()].copy_from_slice(bytes);

    unsafe {
        libc::syscall(
            SYS_reboot,
            KSU_INSTALL_MAGIC1,
            SUSFS_MAGIC,
            CMD_SUSFS_ADD_KEEP_VISIBLE,
            &mut cmd,
        )
    };

    if cmd.err == ERR_CMD_NOT_SUPPORTED {
        anyhow::bail!(
            "CMD_SUSFS_ADD_KEEP_VISIBLE not supported by this kernel \
             (rebuild kernel with the keep-visible patch)"
        );
    }
    if cmd.err != 0 {
        anyhow::bail!("kernel returned err={} for keep-visible add '{}'", cmd.err, path);
    }
    Ok(())
}
EOF
fi

# ---------------------------------------------------------------------------
# 2. src/android/cli.rs — register the subcommand
# ---------------------------------------------------------------------------
if grep -q "KeepVisible" src/android/cli.rs; then
    log "cli.rs already patched, skipping"
else
    log "patching src/android/cli.rs"
    python3 - src/android/cli.rs <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()

# 1. Extend the `enum Susfs` clap subcommands with a KeepVisible variant.
needle_enum = (
    "enum Susfs {\n"
    "    /// Get SUSFS Status\n"
    "    Status,\n"
    "    /// Get SUSFS Version\n"
    "    Version,\n"
    "    /// Get SUSFS enable Features\n"
)
if needle_enum not in src:
    sys.exit("Susfs enum anchor not found in cli.rs — version skew")

# Find the closing brace of the enum to inject before it.
# Simpler: append KeepVisible as a new variant right before the Features variant.
inject_enum = (
    "enum Susfs {\n"
    "    /// Get SUSFS Status\n"
    "    Status,\n"
    "    /// Get SUSFS Version\n"
    "    Version,\n"
    "    /// Pin a mount so it remains visible to apps after zygote fork\n"
    "    /// (skips susfs's clone_mnt fake-vfsmnt substitution for this mount only)\n"
    "    KeepVisible {\n"
    "        #[command(subcommand)]\n"
    "        op: KeepVisibleOp,\n"
    "    },\n"
    "    /// Get SUSFS enable Features\n"
)
src = src.replace(needle_enum, inject_enum, 1)

# Append the KeepVisibleOp subcommand enum after the Susfs enum block.
keep_visible_op = '''
#[derive(clap::Subcommand, Debug)]
enum KeepVisibleOp {
    /// Mark a mount-point's mount as KEEP_VISIBLE so susfs preserves it across forks.
    Add {
        /// path that resolves to the mount we want kept visible (the mount of the path's vfsmnt is marked)
        path: String,
    },
}
'''
# Inject right before the `fn run()` or similar entry — easiest: prepend to the
# end of the file before any `pub fn` (which is rare in cli.rs). We just append
# to the file end, after the existing enums.
src = src.rstrip() + "\n" + keep_visible_op + "\n"

# 2. Add the match arm that dispatches Susfs::KeepVisible.
# Locate the existing Susfs::Features arm and add the KeepVisible arm next to it.
features_arm_needle = "Susfs::Features => println!(\"{}\", susfs::get_susfs_features()),"
if features_arm_needle not in src:
    sys.exit("Susfs::Features arm not found in cli.rs — version skew")
keep_visible_arm = (
    "Susfs::KeepVisible { op } => match op {\n"
    "                    KeepVisibleOp::Add { path } => susfs::add_keep_visible(&path)?,\n"
    "                },\n"
    "                " + features_arm_needle
)
src = src.replace(features_arm_needle, keep_visible_arm, 1)

open(path, 'w').write(src)
PY
fi

log "done."
