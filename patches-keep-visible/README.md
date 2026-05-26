# keep-visible patches

Lets a specific KSU module mount survive `copy_mnt_ns()` substitution so apps
can open files on it, while every *other* module mount continues to be
substituted with a fake `struct mount` by susfs — i.e. stealth posture
unchanged for everything we don't explicitly mark.

## Why

`susfs`'s `clone_mnt()` patch replaces any mount with `mnt_id >=
DEFAULT_KSU_MNT_ID` with an empty `susfs_alloc_unshare_ksu_vfsmnt()` placeholder
whenever the namespace is being cloned by `copy_mnt_ns()` (= every app fork
from zygote). The placeholder has no `mnt_root` / `mnt_sb`, so path lookups
walking through it fall through to the underlying mount — and any file unique
to the KSU mount becomes invisible to apps.

For our FixMiPay use case we need the *opposite*: a specific bind-mounted file
(the CN MITSMClient.apk overlaying the EEA stub) must be visible to apps so
PMS / ART / launcher can read it. Without it, `com.miui.tsmclient` fails to
load its own dex/resources and crashes on every launch with `Resources.getConfiguration()`
on a null reference.

## Design

A new mount-flag bit `VFSMOUNT_MNT_FLAGS_KSU_KEEP_VISIBLE = 0x40000000` opts
a single mount out of the substitution. Apply it via a new susfs command
`CMD_SUSFS_ADD_KEEP_VISIBLE = 0x60030` from userspace (added to ksud as
`ksud susfs keep-visible add <path>`).

- `/proc/self/mounts` filter (`m_show`) is left alone — the mount still has
  `mnt_id >= DEFAULT_KSU_MNT_ID`, so `hide_sus_mnts_for_non_su_procs` still
  filters it out of procfs for non-su processes. Apps doing
  `cat /proc/self/mounts | grep adb` still see nothing.
- Only `clone_mnt()` is taught to honor the flag: when cloning for
  `CL_COPY_MNT_NS` (= zygote-fork), the substitution is skipped and a real
  `alloc_vfsmnt()` clone happens, so the new namespace inherits a working
  mount with proper `mnt_root` / `mnt_sb`. Apps can `open()` the file.

## Files

| Patch | Applied to | What it does |
|---|---|---|
| `01-common-keep-visible.patch` | `common/` (the GKI kernel tree), *after* susfs's `50_add_susfs_in_gki-…patch` | Adds `CMD_SUSFS_ADD_KEEP_VISIBLE` + `VFSMOUNT_MNT_FLAGS_KSU_KEEP_VISIBLE` constants in `include/linux/susfs_def.h`. Adds `st_susfs_keep_visible` struct + `susfs_add_keep_visible()` handler in `fs/susfs.c`. Patches `fs/namespace.c`'s susfs-injected `clone_mnt()` logic to skip the fake-substitution when the source mount has the flag set. |
| `02-kernelsu-dispatch.patch` | `KernelSU/` (the ReSukiSU drop-in) | Adds `case CMD_SUSFS_ADD_KEEP_VISIBLE` to `ksu_handle_susfs_cmd()` in `kernel/supercall/dispatch.c`. |
| `03-ksud-cli.patch` | `KernelSU/userspace/ksud/` | Adds `ksud susfs keep-visible add <path>` subcommand. New function in `src/android/susfs.rs`. New `clap` enum in `src/android/cli.rs`. |
| `workflow.patch` | `.github/workflows/fastbuild_6.12.23_gki.yml` | Adds a `git apply` step after the existing susfs / ReSukiSU clones to apply 01/02/03 from this directory. |

## Build + flash

Once these patches are pushed to the workflow fork and CI builds:

1. Download the `AnyKernel3_ReSukiSU_*.zip` artifact.
2. Flash the kernel image (`anykernel.sh` via recovery/twrp or `fastboot flash boot`).
3. Push the new ksud (extracted from the workflow's `ksud-aarch64-linux-android`
   artifact) to `/data/adb/ksud`.
4. Update the FixMiPay module's `post-fs-data.sh` (already done in this repo)
   so it runs `ksud susfs keep-visible add /product/app/MITSMClientGlobal/MITSMClientGlobal.apk`
   immediately after the `mount --bind` of the CN APK.
5. Reboot. `com.miui.tsmclient` should now launch.

## Stealth invariants this patch preserves

- Every existing module's mount continues to be substituted with the fake
  placeholder in app namespaces — they have no `KSU_KEEP_VISIBLE` flag set.
- `/proc/self/mounts` filtering is unchanged. The kept-visible mount has a
  `mnt_id >= DEFAULT_KSU_MNT_ID`, so it's still filtered out of procfs.
- No new kernel symbols are exported to userland beyond the existing susfs
  ioctl/syscall surface — we add one new CMD inside the existing
  `ksu_handle_susfs_cmd()` switch, nothing more.
- The flag is *opt-in per mount, set from userspace post-mount*. No mount
  becomes visible without explicit `ksud susfs keep-visible add`.
