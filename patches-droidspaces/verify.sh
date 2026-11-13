#!/usr/bin/env bash
# After the kernel build: fail unless every Droidspaces option survived Kconfig
# and the VINTF mask took, then collect the evidence needed to judge, before
# flashing, whether the phone's vendor modules will still load.
# Usage: verify.sh <evidence-dir>   (CWD at $kernel_workspace/common)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ev="${1:?usage: verify.sh <evidence-dir>}"
mkdir -p "$ev"
fail=0

cfg=out/.config
data=out/kernel/config_data
for f in "$cfg" "$data" out/vmlinux.symvers out/vmlinux; do
    [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 2; }
done

while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    if grep -qx "$line" "$cfg"; then
        echo "[ok]   $line"
    else
        echo "[FAIL] $line not in .config (Kconfig dropped it): $(grep -E "^(# )?${line%%=*}[ =]" "$cfg" || echo absent)"
        fail=1
    fi
done < "$here/options.txt"

for key in CONFIG_SYSVIPC CONFIG_IP6_NF_NAT; do
    if grep -qx "# $key is not set" "$data"; then
        echo "[ok]   /proc/config.gz will show '# $key is not set'"
    else
        echo "[FAIL] VINTF mask missing for $key: $(grep -E "$key[ =]" "$data" || echo absent)"
        fail=1
    fi
done
grep -qx 'CONFIG_PID_NS=y' "$data" || { echo "[FAIL] config_data lacks CONFIG_PID_NS=y"; fail=1; }

cp "$cfg" "$ev/config"
cp "$data" "$ev/config_data"
cp out/vmlinux.symvers "$ev/vmlinux.symvers"
if command -v pahole >/dev/null; then
    pahole --version > "$ev/task_struct.pahole"
    pahole -C task_struct out/vmlinux >> "$ev/task_struct.pahole" 2>&1 || echo "WARN: pahole failed" >&2
else
    echo "WARN: pahole not installed; no task_struct layout in evidence" >&2
fi

exit "$fail"
