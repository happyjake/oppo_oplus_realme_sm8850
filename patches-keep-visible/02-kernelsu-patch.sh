#!/usr/bin/env bash
# Add CMD_SUSFS_ADD_KEEP_VISIBLE dispatch case to ksu_handle_susfs_cmd().
# Run with CWD at $kernel_workspace/KernelSU/ (the ReSukiSU clone).
set -euo pipefail

log() { printf '[keep-visible/kernelsu] %s\n' "$*"; }

DISPATCH=kernel/supercall/dispatch.c
if [ ! -f "$DISPATCH" ]; then
    echo "ERROR: not in a KernelSU tree (missing $DISPATCH)" >&2
    exit 2
fi

if grep -q "CMD_SUSFS_ADD_KEEP_VISIBLE" "$DISPATCH"; then
    log "$DISPATCH already patched, skipping"
    exit 0
fi

log "patching $DISPATCH"
python3 - "$DISPATCH" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()

# Insert our case at the end of the ksu_handle_susfs_cmd switch,
# anchored on the last existing CONFIG_KSU_SUSFS_* block we can find.
# We use the SUS_MAP case as the anchor — it's the last one in the
# current susfs version and pairs with VFSMOUNT_MNT_FLAGS_KSU_*.
needle = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
)
if needle not in src:
    sys.exit("CONFIG_KSU_SUSFS_SUS_MAP anchor not found in dispatch.c — susfs version skew")

inject = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "    case CMD_SUSFS_ADD_KEEP_VISIBLE: {\n"
    "        susfs_add_keep_visible(arg);\n"
    "        return 0;\n"
    "    }\n"
    "#endif //#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
) + needle

src = src.replace(needle, inject, 1)

# Also declare the extern so the compiler is happy without a header change.
# Put it near the top of the file, after the other susfs externs if any,
# otherwise just after the last #include.
extern = "extern void susfs_add_keep_visible(void __user **user_info);\n"
if extern not in src:
    # Find the last #include line and inject after it.
    import re
    m = list(re.finditer(r'^#include[^\n]*\n', src, re.M))
    if not m:
        sys.exit("no #include lines found in dispatch.c — refusing to patch")
    pos = m[-1].end()
    src = src[:pos] + "\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n" + extern + "#endif\n" + src[pos:]

open(path, 'w').write(src)
PY

log "done."
