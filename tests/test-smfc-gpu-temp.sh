#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Tests bin/smfc-gpu-temp against a fake ssh. No VM, GPU or root needed:
#   bash tests/test-smfc-gpu-temp.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'FAKE'
#!/bin/bash
[ "${FAKE:-}" = "hang" ] && sleep 30
printf "%b" "${FAKE_OUT:-}"; exit "${FAKE_RC:-0}"
FAKE
printf '#!/bin/bash\ntrue\n' > "$T/bin/logger"
chmod +x "$T/bin/ssh" "$T/bin/logger"
sed "s#STATE_FILE=\"/run/smfc-gpu-temp.state\"#STATE_FILE=\"$T/state\"#; s#/etc/default/smfc-gpu-temp#$T/none#g" \
    "$here/bin/smfc-gpu-temp" > "$T/wrapper"

fails=0
check() {  # check <description> <expected> [VAR=value ...]
    local desc=$1 exp=$2; shift 2
    local got; got=$(env PATH="$T/bin:$PATH" "$@" bash "$T/wrapper")
    if [ "$got" = "$exp" ]; then echo "PASS  $desc"; else echo "FAIL  $desc (expected $exp, got $got)"; fails=$((fails+1)); fi
}
check "single GPU"                         53 FAKE_OUT='53\n'
check "two GPUs: reports the hottest"      71 FAKE_OUT='53\n71\n'
check "three GPUs with a blank line"       66 FAKE_OUT='40\n\n66\n52\n'
check "CRLF line endings"                  54 FAKE_OUT='54\r\n'
check "one GPU unreadable: fail-safe"      90 FAKE_OUT='53\n[N/A]\n'
check "no output: fail-safe"               90 FAKE_OUT=''
check "error text: fail-safe"              90 FAKE_OUT='error: no devices\n'
check "out of range: fail-safe"            90 FAKE_OUT='150\n'
check "ssh failed: fail-safe"              90 FAKE_RC=255
start=$(date +%s)
check "ssh hangs: fail-safe"               90 FAKE=hang
took=$(( $(date +%s) - start ))
if [ "$took" -le 6 ]; then echo "PASS  hang cut off after ${took}s"; else echo "FAIL  hang took ${took}s"; fails=$((fails+1)); fi
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
