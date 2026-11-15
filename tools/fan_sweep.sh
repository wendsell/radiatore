#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 wendsell. Part of Radiatore: https://github.com/wendsell/radiatore
# Fan resonance sweep for IPMI zone 0 (FAN1-6, CPU/system fans) on a Supermicro X10 board.
# Listen while it runs: note the duty steps where the chassis hums or buzzes.
# Pauses SMFC, holds zone 1 (GPU) at 60% (100% if the P100 > 70C), steps zone 0 from 35% to 100% in 5% steps,
# HOLD seconds each, logs duty + RPM per step. Aborts if a CPU package exceeds 75C. Always restarts SMFC on exit.
LOG=${LOG:-./fan_sweep.log}
HOLD=${HOLD:-20}
LEAD=${LEAD:-60}
: > "$LOG"
say() { echo "$(date +%T) $*" | tee -a "$LOG"; }
set_zone() { ipmitool raw 0x30 0x70 0x66 0x01 "$1" "$(printf '0x%02x' "$2")" >/dev/null; }
cpu_max() { cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | sort -n | tail -1 | awk '{print int($1/1000)}'; }
restore() { say "restoring: starting smfc"; systemctl start smfc; sleep 3; say "smfc $(systemctl is-active smfc)"; }
trap restore EXIT

systemctl stop smfc
say "smfc stopped (fans at exit level 100%)"
set_zone 1 60
say "zone 1 (GPU) held at 60%; sweep of zone 0 starts in ${LEAD}s"
sleep "$LEAD"
for duty in $(seq 35 5 100); do
    set_zone 0 "$duty"
    say ">>> zone 0 now ${duty}%"
    sleep "$HOLD"
    g=$(/usr/local/bin/smfc-gpu-temp)
    [ "$g" -gt 70 ] && { set_zone 1 100; say "GPU ${g}C > 70, zone 1 -> 100%"; }
    c=$(cpu_max)
    rpm=$(ipmitool sdr type Fan | awk -F'|' '/^FAN[1-6]/{gsub(/ /,"",$1); gsub(/ RPM/,"",$5); gsub(/ /,"",$5); printf "%s=%s ", $1, $5}')
    say "    duty=${duty}% cpu=${c}C gpu=${g}C ${rpm}"
    if [ "$c" -gt 75 ]; then say "CPU ${c}C > 75, aborting"; exit 1; fi
done
say "sweep complete"
