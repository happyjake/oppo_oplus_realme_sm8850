#!/usr/bin/env bash
# Turn on Droidspaces container support in the 6.12 GKI kernel.
# Source: ravindu644/Droidspaces-OSS Documentation/Kernel-Configuration.md,
# "GKI kernels"; the kABI patch is that repo's
# Documentation/resources/kernel-patches/GKI/kernel-6.12/ at 023013a9.
# Run with CWD at $kernel_workspace/common, after every other source patch and
# defconfig edit, before `make gki_defconfig`.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
log() { printf '[droidspaces] %s\n' "$*"; }

if [ ! -f include/linux/sched.h ] || [ ! -f kernel/Makefile ]; then
    echo "ERROR: not in a kernel tree (run from kernel_workspace/common)" >&2
    exit 2
fi

# 1. kABI. CONFIG_SYSVIPC adds sysvsem/sysvshm to task_struct. The patch moves
#    them into the cache-line hole before `se`, inside __kabi_ignored unions
#    that gendwarfksyms skips, so task_struct offsets and symbol CRCs stay as
#    the stock vendor modules expect. A patch that does not apply cleanly
#    stops the build: a fuzzed hunk here is a bootloop.
kabi="$here/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch"
log "applying $(basename "$kabi")"
patch -p1 --forward --fuzz=0 --dry-run < "$kabi" >/dev/null
patch -p1 --forward --fuzz=0 < "$kabi"

# 2. defconfig: upstream's GKI list, without CONFIG_CFS_BANDWIDTH and
#    CONFIG_CGROUP_PIDS (they break the kABI; upstream leaves them off too).
#    verify.sh checks that each one survived Kconfig.
log "appending options to gki_defconfig"
cat "$here/options.txt" >> arch/arm64/configs/gki_defconfig

# 3. VINTF. The framework compatibility matrices on the phone require
#    CONFIG_SYSVIPC=n and CONFIG_IP6_NF_NAT=n; a mismatch shows "There's an
#    internal problem with your device" at every boot. Report both in
#    /proc/config.gz exactly as the stock kernel does. Droidspaces probes the
#    running kernel and never reads the config, so it still sees them.
mf=kernel/Makefile
if grep -q 'droidspaces-vintf-mask' "$mf"; then
    log "$mf already masked, skipping"
else
    log "masking CONFIG_SYSVIPC and CONFIG_IP6_NF_NAT in config_data"
    python3 - "$mf" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
anchor = "$(obj)/config_data: $(KCONFIG_CONFIG) FORCE\n\t$(call filechk,cat)\n"
if src.count(anchor) != 1:
    sys.exit("ERROR: config_data rule not found exactly once in " + path)
mask = (
    "\t$(Q)sed -i"
    " -e 's/^CONFIG_SYSVIPC=y$$/# CONFIG_SYSVIPC is not set/'"
    " -e 's/^CONFIG_IP6_NF_NAT=y$$/# CONFIG_IP6_NF_NAT is not set/'"
    " $@ # droidspaces-vintf-mask\n"
)
open(path, "w").write(src.replace(anchor, anchor + mask))
PY
fi

log "done"
