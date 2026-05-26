#!/usr/bin/env bash
# Apply keep-visible patches to the GKI common/ tree AFTER susfs's
# 50_add_susfs_in_gki-*.patch has been applied. Run with the workflow's
# CWD already at $kernel_workspace/common/.
#
# What this script changes:
#   include/linux/susfs_def.h  — adds CMD_SUSFS_ADD_KEEP_VISIBLE constant and
#                                 VFSMOUNT_MNT_FLAGS_KSU_KEEP_VISIBLE flag.
#   fs/susfs.c                 — appends susfs_add_keep_visible() handler.
#   fs/namespace.c             — adds two-line "if flag set, goto skip_*" guard
#                                 in clone_mnt() so KEEP_VISIBLE mounts skip
#                                 susfs's fake-vfsmnt substitution and get a
#                                 normal alloc_vfsmnt() clone instead.
set -euo pipefail

log() { printf '[keep-visible/common] %s\n' "$*"; }

if [ ! -f include/linux/susfs_def.h ]; then
    echo "ERROR: not in a kernel common/ tree (missing include/linux/susfs_def.h)" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# 1. susfs_def.h — add CMD + flag
# ---------------------------------------------------------------------------
if grep -q "CMD_SUSFS_ADD_KEEP_VISIBLE" include/linux/susfs_def.h; then
    log "susfs_def.h already patched, skipping"
else
    log "patching include/linux/susfs_def.h"
    # Insert the new CMD right after the last existing CMD_SUSFS_* line.
    # Insert the new mount flag right after VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT.
    python3 - include/linux/susfs_def.h <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
# Insert CMD after the last CMD_SUSFS_ define.
cmd_lines = list(re.finditer(r'^#define CMD_SUSFS_[A-Z_]+ 0x[0-9a-fA-F]+.*$', src, re.M))
if not cmd_lines:
    sys.exit("no CMD_SUSFS_ defines found")
last = cmd_lines[-1]
new_cmd = '#define CMD_SUSFS_ADD_KEEP_VISIBLE 0x60030'
src = src[:last.end()] + '\n' + new_cmd + src[last.end():]
# Insert flag right after VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT.
src = re.sub(
    r'(#define VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT 0x80000000[^\n]*\n)',
    r'\1#define VFSMOUNT_MNT_FLAGS_KSU_KEEP_VISIBLE 0x40000000 /* opt-out of susfs clone_mnt substitution */\n',
    src, count=1
)
open(path, 'w').write(src)
PY
fi

# ---------------------------------------------------------------------------
# 2. fs/susfs.c — append the handler
# ---------------------------------------------------------------------------
if grep -q "susfs_add_keep_visible" fs/susfs.c; then
    log "fs/susfs.c already patched, skipping"
else
    log "appending susfs_add_keep_visible() to fs/susfs.c"
    cat >> fs/susfs.c <<'EOF'

#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
/* keep_visible — mark a single mount so clone_mnt() skips susfs's fake-vfsmnt
 * substitution and uses alloc_vfsmnt() instead, letting the mount survive
 * into apps' namespaces. /proc/self/mounts is still filtered (the mount keeps
 * its mnt_id >= DEFAULT_KSU_MNT_ID), so stealth is unchanged for procfs
 * scanners. Only file-system path lookups see the mount.
 */
struct st_susfs_keep_visible {
    char target_pathname[SUSFS_MAX_LEN_PATHNAME];
    int  err;
};

void susfs_add_keep_visible(void __user **user_info) {
    struct st_susfs_keep_visible info = {0};
    struct path path;
    struct mount *mnt;

    if (copy_from_user(&info, (struct st_susfs_keep_visible __user *)*user_info, sizeof(info))) {
        info.err = -EFAULT;
        goto out_copy_to_user;
    }
    info.target_pathname[sizeof(info.target_pathname) - 1] = '\0';

    info.err = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);
    if (info.err) {
        SUSFS_LOGE("failed opening path '%s'\n", info.target_pathname);
        goto out_copy_to_user;
    }

    mnt = real_mount(path.mnt);
    if (!mnt) {
        info.err = -EINVAL;
        goto out_path_put;
    }

    if (mnt->mnt.mnt_flags & VFSMOUNT_MNT_FLAGS_KSU_KEEP_VISIBLE) {
        SUSFS_LOGI("already marked KEEP_VISIBLE: '%s'\n", info.target_pathname);
    } else {
        mnt->mnt.mnt_flags |= VFSMOUNT_MNT_FLAGS_KSU_KEEP_VISIBLE;
        SUSFS_LOGI("marked KEEP_VISIBLE: '%s' (mnt_id=%d)\n",
                   info.target_pathname, mnt->mnt_id);
    }
    info.err = 0;

out_path_put:
    path_put(&path);
out_copy_to_user:
    if (copy_to_user(&((struct st_susfs_keep_visible __user *)*user_info)->err,
                     &info.err, sizeof(info.err))) {
        info.err = -EFAULT;
    }
    SUSFS_LOGI("CMD_SUSFS_ADD_KEEP_VISIBLE -> ret: %d\n", info.err);
}
#endif /* CONFIG_KSU_SUSFS_SUS_MOUNT */
EOF
fi

# ---------------------------------------------------------------------------
# 3. fs/namespace.c — insert the KEEP_VISIBLE guards in clone_mnt
# ---------------------------------------------------------------------------
if grep -q "VFSMOUNT_MNT_FLAGS_KSU_KEEP_VISIBLE" fs/namespace.c; then
    log "fs/namespace.c already patched, skipping"
else
    log "patching fs/namespace.c clone_mnt()"
    python3 - fs/namespace.c <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()

# Insert KEEP_VISIBLE bypass at the top of the SUS_MOUNT block in clone_mnt.
# We anchor on the line `bool is_mnt_ksu_unshared = false;` which susfs adds.
needle = "bool is_mnt_ksu_unshared = false;\n"
insert = (
    "bool is_mnt_ksu_unshared = false;\n"
    "\t// keep_visible: opt-out of susfs's fake-vfsmnt substitution so this\n"
    "\t// specific mount survives into app namespaces with real mnt_root/mnt_sb.\n"
    "\tif (old->mnt.mnt_flags & VFSMOUNT_MNT_FLAGS_KSU_KEEP_VISIBLE)\n"
    "\t\tgoto skip_susfs_substitution;\n"
)
if needle not in src:
    sys.exit("clone_mnt anchor (is_mnt_ksu_unshared) not found — susfs patch unapplied or version skew")
new = src.replace(needle, insert, 1)

# Add the skip_susfs_substitution label just before the closing #endif of the
# SUS_MOUNT block — i.e. right after the `if (old->mnt_id >= DEFAULT_KSU_MNT_ID)`
# stanza inside clone_mnt and before `mnt = alloc_vfsmnt(old->mnt_devname);`.
endif_block = (
    "\tif (old->mnt_id >= DEFAULT_KSU_MNT_ID) {\n"
    "\t\tmnt = susfs_alloc_non_unshare_ksu_vfsmnt(old->mnt_devname);\n"
    "\t\tgoto bypass_orig_flow;\n"
    "\t}\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
)
new_block = (
    "\tif (old->mnt_id >= DEFAULT_KSU_MNT_ID) {\n"
    "\t\tmnt = susfs_alloc_non_unshare_ksu_vfsmnt(old->mnt_devname);\n"
    "\t\tgoto bypass_orig_flow;\n"
    "\t}\n"
    "skip_susfs_substitution:\n"
    "\t;\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
)
if endif_block not in new:
    sys.exit("clone_mnt endif anchor not found — susfs patch unapplied or version skew")
new = new.replace(endif_block, new_block, 1)

open(path, 'w').write(new)
PY
fi

log "done."
