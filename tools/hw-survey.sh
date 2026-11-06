#!/bin/bash
# hw-survey.sh — hardware survey and health check from an Ubuntu live session.
# Outputs a JSON report to stdout (redirect to file for inventory).
# Works offline; degrades gracefully without root or missing tools.
set -euo pipefail

json_escape() {
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")'
}

have() { command -v "$1" &>/dev/null; }

warn_missing() { echo "WARNING: $1 not found, skipping $2" >&2; }

needs_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "WARNING: not root, skipping $1 (run with sudo for full report)" >&2
        return 1
    fi
    return 0
}

# ---------- timestamp + hostname ----------
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOSTNAME=$(hostname 2>/dev/null || echo "unknown")

# ---------- CPU ----------
cpu_json="{}"
if have lscpu; then
    cpu_model=$(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')
    cpu_arch=$(lscpu | awk -F: '/Architecture/{gsub(/^ +/,"",$2); print $2; exit}')
    cpu_cores=$(lscpu | awk -F: '/^CPU\(s\):/{gsub(/^ +/,"",$2); print $2; exit}')
    cpu_threads_per=$(lscpu | awk -F: '/Thread\(s\) per core/{gsub(/^ +/,"",$2); print $2; exit}')
    cpu_sockets=$(lscpu | awk -F: '/Socket\(s\)/{gsub(/^ +/,"",$2); print $2; exit}')
    cpu_json=$(cat <<CPUEOF
{
  "model": $(json_escape "$cpu_model"),
  "architecture": $(json_escape "$cpu_arch"),
  "cpus": $(json_escape "$cpu_cores"),
  "threads_per_core": $(json_escape "$cpu_threads_per"),
  "sockets": $(json_escape "$cpu_sockets")
}
CPUEOF
    )
else
    warn_missing lscpu "CPU info"
fi

# ---------- Memory ----------
mem_json="{}"
if have free; then
    mem_total_kib=$(free | awk '/^Mem:/{print $2}')
    mem_total_mib=$((mem_total_kib / 1024))
    mem_json="{\"total_mib\": $mem_total_mib}"
else
    warn_missing free "memory info"
fi

# ---------- DMI / BIOS ----------
dmi_json="{}"
if have dmidecode; then
    if needs_root "BIOS/system info (dmidecode)"; then
        bios_vendor=$(dmidecode -s bios-vendor 2>/dev/null || echo "unknown")
        bios_version=$(dmidecode -s bios-version 2>/dev/null || echo "unknown")
        bios_date=$(dmidecode -s bios-release-date 2>/dev/null || echo "unknown")
        sys_manufacturer=$(dmidecode -s system-manufacturer 2>/dev/null || echo "unknown")
        sys_product=$(dmidecode -s system-product-name 2>/dev/null || echo "unknown")
        sys_serial=$(dmidecode -s system-serial-number 2>/dev/null || echo "unknown")
        dmi_json=$(cat <<DMIEOF
{
  "bios_vendor": $(json_escape "$bios_vendor"),
  "bios_version": $(json_escape "$bios_version"),
  "bios_date": $(json_escape "$bios_date"),
  "system_manufacturer": $(json_escape "$sys_manufacturer"),
  "system_product": $(json_escape "$sys_product"),
  "system_serial": $(json_escape "$sys_serial")
}
DMIEOF
        )
    fi
else
    warn_missing dmidecode "BIOS/system info"
fi

# ---------- Disks ----------
disks_json="[]"
if have lsblk; then
    disk_list=$(lsblk -dnpo NAME,SIZE,MODEL,TRAN,TYPE | awk '$5=="disk"{print $1}')
    disks_json="["
    first=true
    for dev in $disk_list; do
        size=$(lsblk -dnpo SIZE "$dev" | xargs)
        model=$(lsblk -dnpo MODEL "$dev" | xargs)
        transport=$(lsblk -dnpo TRAN "$dev" | xargs)

        smart_status="skipped"
        smart_errors=""
        smart_temp=""
        if have smartctl; then
            if needs_root "SMART for $dev"; then
                smart_health=$(smartctl -H "$dev" 2>/dev/null || true)
                if echo "$smart_health" | grep -qi "PASSED"; then
                    smart_status="PASSED"
                elif echo "$smart_health" | grep -qi "FAILED"; then
                    smart_status="FAILED"
                else
                    smart_status="unknown"
                fi
                smart_errors=$(smartctl -l error "$dev" 2>/dev/null \
                    | grep -c "Error" || echo "0")
                smart_temp=$(smartctl -A "$dev" 2>/dev/null \
                    | awk '/Temperature_Celsius|Airflow_Temperature/{print $10; exit}')
            fi
        fi

        $first || disks_json+=","
        first=false
        disks_json+=$(cat <<DISKEOF

    {
      "device": $(json_escape "$dev"),
      "size": $(json_escape "$size"),
      "model": $(json_escape "$model"),
      "transport": $(json_escape "$transport"),
      "smart_status": $(json_escape "$smart_status"),
      "smart_error_count": $(json_escape "${smart_errors:-0}"),
      "temperature_c": $(json_escape "${smart_temp:-n/a}")
    }
DISKEOF
        )
    done
    disks_json+=$'\n  ]'
else
    warn_missing lsblk "disk info"
fi

# ---------- GPU ----------
gpus_json="[]"
if have lspci; then
    gpus_json="["
    first=true
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        $first || gpus_json+=","
        first=false
        gpus_json+=$'\n    '"$(json_escape "$line")"
    done < <(lspci 2>/dev/null | grep -iE 'VGA|3D|Display' | sed 's/^[^ ]* //')
    gpus_json+=$'\n  ]'
else
    warn_missing lspci "GPU info"
fi

# ---------- Network interfaces ----------
net_json="[]"
if have ip; then
    net_json="["
    first=true
    while IFS= read -r iface; do
        [ -z "$iface" ] && continue
        state=$(ip -o link show "$iface" 2>/dev/null | grep -oP 'state \K\S+' || echo "unknown")
        mac=$(ip -o link show "$iface" 2>/dev/null | grep -oP 'link/ether \K\S+' || echo "n/a")
        $first || net_json+=","
        first=false
        net_json+=$(cat <<NETEOF

    {
      "interface": $(json_escape "$iface"),
      "state": $(json_escape "$state"),
      "mac": $(json_escape "$mac")
    }
NETEOF
        )
    done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$')
    net_json+=$'\n  ]'
else
    warn_missing ip "network interfaces"
fi

# ---------- Battery ----------
battery_json="{}"
if have upower; then
    bat_path=$(upower -e 2>/dev/null | grep battery | head -1)
    if [ -n "$bat_path" ]; then
        bat_state=$(upower -i "$bat_path" 2>/dev/null | awk -F: '/state:/{gsub(/^ +/,"",$2); print $2; exit}')
        bat_percent=$(upower -i "$bat_path" 2>/dev/null | awk -F: '/percentage:/{gsub(/^ +| *%/,"",$2); print $2; exit}')
        bat_health=$(upower -i "$bat_path" 2>/dev/null | awk -F: '/capacity:/{gsub(/^ +| *%/,"",$2); print $2; exit}')
        bat_cycles=$(upower -i "$bat_path" 2>/dev/null | awk -F: '/charge-cycles:/{gsub(/^ +/,"",$2); print $2; exit}')
        battery_json=$(cat <<BATEOF
{
    "state": $(json_escape "${bat_state:-unknown}"),
    "percent": $(json_escape "${bat_percent:-n/a}"),
    "health_percent": $(json_escape "${bat_health:-n/a}"),
    "charge_cycles": $(json_escape "${bat_cycles:-n/a}")
  }
BATEOF
        )
    fi
fi

# ---------- Memtest availability ----------
memtest_available="false"
if have memtester || [ -f /boot/memtest86+.bin ] || [ -f /boot/memtest86+x64.efi ]; then
    memtest_available="true"
fi

# ---------- Assemble report ----------
cat <<REPORT
{
  "hw_survey_version": "1.0.0",
  "timestamp": $(json_escape "$TIMESTAMP"),
  "hostname": $(json_escape "$HOSTNAME"),
  "root": $([ "$(id -u)" -eq 0 ] && echo "true" || echo "false"),
  "cpu": $cpu_json,
  "memory": $mem_json,
  "system": $dmi_json,
  "disks": $disks_json,
  "gpus": $gpus_json,
  "network_interfaces": $net_json,
  "battery": $battery_json,
  "memtest_available": $memtest_available
}
REPORT
