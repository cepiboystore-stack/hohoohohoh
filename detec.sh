#!/bin/sh
# b.sh - Server info + panel detect + domains + docroot + DNS IP compare
# POSIX sh compatible

set -eu

hr() { echo "--------------------------------------------------------------------------------"; }
say() { printf "%s\n" "$*"; }

# ---------- Basic helpers ----------
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

get_os_pretty() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${PRETTY_NAME:-UNKNOWN}"
    return
  fi
  uname -s 2>/dev/null || echo "UNKNOWN"
}

get_kernel() { uname -r 2>/dev/null || echo "UNKNOWN"; }

get_uptime() {
  if cmd_exists uptime; then
    uptime -p 2>/dev/null || uptime 2>/dev/null || true
  elif [ -r /proc/uptime ]; then
    awk '{print int($1)}' /proc/uptime
  else
    echo "UNKNOWN"
  fi
}

get_cpu_model() {
  awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "UNKNOWN"
}

get_cpu_cores_threads() {
  threads="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo "")"
  [ -z "${threads:-}" ] && threads="$(awk '/^processor/{c++} END{print c+0}' /proc/cpuinfo 2>/dev/null || echo 0)"
  # physical cores estimate (not always accurate in VPS)
  cores="$(awk -F': ' '
    /^cpu cores/{print $2; exit}
  ' /proc/cpuinfo 2>/dev/null || echo "")"
  [ -z "${cores:-}" ] && cores="$threads"
  echo "$cores|$threads"
}

get_load() { awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null || echo "UNKNOWN"; }

get_mem() {
  # Returns: totalMB|usedMB|freeMB
  if cmd_exists free; then
    free -m | awk '
      /^Mem:/ {t=$2; u=$3; f=$4; print t"|"u"|"f; exit}
    '
  else
    t="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    a="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    u=$((t - a))
    echo "$t|$u|$a"
  fi
}

get_swap() {
  if cmd_exists free; then
    free -m | awk '
      /^Swap:/ {t=$2; u=$3; f=$4; print t"|"u"|"f; exit}
    '
  else
    echo "0|0|0"
  fi
}

get_disk_root() {
  if cmd_exists df; then
    df -h / 2>/dev/null | awk 'NR==2{print $2"|"$3"|"$4"|"$5}'
  else
    echo "UNKNOWN"
  fi
}

detect_virt() {
  if cmd_exists systemd-detect-virt; then
    v="$(systemd-detect-virt 2>/dev/null || true)"
    [ -n "${v:-}" ] && echo "$v" && return
  fi
  # best-effort fallback
  if [ -f /proc/1/environ ] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -qi container; then
    echo "container"
    return
  fi
  echo "UNKNOWN"
}

get_public_ip() {
  if cmd_exists curl; then
    ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [ -n "${ip:-}" ] && echo "$ip" && return
  fi
  if cmd_exists wget; then
    ip="$(wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || true)"
    [ -n "${ip:-}" ] && echo "$ip" && return
  fi
  echo ""
}

get_route_src_ip() {
  ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

# ---------- Panel detection ----------
detect_panel() {
  if [ -d /usr/local/cpanel ] || [ -x /usr/local/cpanel/cpanel ]; then echo "CPANEL/WHM"; return; fi
  if [ -d /usr/local/psa ] || [ -x /usr/sbin/plesk ]; then echo "PLESK"; return; fi
  if [ -d /usr/local/directadmin ] || [ -x /usr/local/directadmin/directadmin ]; then echo "DIRECTADMIN"; return; fi
  if [ -d /usr/local/hestia ] || [ -x /usr/local/hestia/bin/v-list-web-domains ]; then echo "HESTIACP"; return; fi
  if [ -d /usr/local/vesta ] || [ -x /usr/local/vesta/bin/v-list-web-domains ]; then echo "VESTACP"; return; fi
  if [ -d /www/server/panel ]; then echo "AAPANEL"; return; fi
  echo "UNKNOWN"
}

resolve_ip() {
  if cmd_exists getent; then
    getent ahosts "$1" 2>/dev/null | awk '{print $1; exit}'
    return
  fi
  if cmd_exists dig; then
    dig +short A "$1" 2>/dev/null | head -n 1
    return
  fi
  if cmd_exists nslookup; then
    nslookup "$1" 2>/dev/null | awk '/^Address: /{print $2; exit}'
    return
  fi
  echo ""
}

check_docroot() { [ -d "$1" ] && echo "OK" || echo "MISSING"; }

# ---------- Server "bagus apa engga" quick score ----------
score_server() {
  cores="$1"; ram_mb="$2"; disk_gb="$3"
  score=0

  # cores
  if [ "$cores" -ge 8 ]; then score=$((score+3))
  elif [ "$cores" -ge 4 ]; then score=$((score+2))
  elif [ "$cores" -ge 2 ]; then score=$((score+1))
  fi

  # RAM
  if [ "$ram_mb" -ge 16384 ]; then score=$((score+3))
  elif [ "$ram_mb" -ge 8192 ]; then score=$((score+2))
  elif [ "$ram_mb" -ge 4096 ]; then score=$((score+1))
  fi

  # Disk (rough)
  if [ "$disk_gb" -ge 200 ]; then score=$((score+2))
  elif [ "$disk_gb" -ge 80 ]; then score=$((score+1))
  fi

  echo "$score"
}

recommendation_from_score() {
  s="$1"
  case "$s" in
    0|1|2) echo "Kecil/hemat. Cocok untuk situs ringan, dev, 1-10 website kecil." ;;
    3|4)   echo "Menengah. Cocok untuk beberapa website + mail ringan, traffic menengah." ;;
    5|6|7|8) echo "Bagus. Cocok untuk banyak akun/website, workload lebih berat." ;;
    *)     echo "UNKNOWN" ;;
  esac
}

# ========================= MAIN =========================
hr
say "[*] SERVER INFO"
OS="$(get_os_pretty)"
KERNEL="$(get_kernel)"
UP="$(get_uptime)"
CPU_MODEL="$(get_cpu_model)"
CT="$(get_cpu_cores_threads)"; CORES="$(echo "$CT" | cut -d'|' -f1)"; THREADS="$(echo "$CT" | cut -d'|' -f2)"
LOAD="$(get_load)"
MEM="$(get_mem)"; MEM_T="$(echo "$MEM" | cut -d'|' -f1)"; MEM_U="$(echo "$MEM" | cut -d'|' -f2)"; MEM_F="$(echo "$MEM" | cut -d'|' -f3)"
SWP="$(get_swap)"; SWP_T="$(echo "$SWP" | cut -d'|' -f1)"; SWP_U="$(echo "$SWP" | cut -d'|' -f2)"; SWP_F="$(echo "$SWP" | cut -d'|' -f3)"
DISK="$(get_disk_root)"
VIRT="$(detect_virt)"

PUB_IP="$(get_public_ip || true)"
SRC_IP="$(get_route_src_ip || true)"

say "OS            : $OS"
say "Kernel        : $KERNEL"
say "Uptime        : $UP"
say "Virtualization: $VIRT"
say "CPU           : $CPU_MODEL"
say "Cores/Threads : $CORES / $THREADS"
say "Load avg      : $LOAD"
say "RAM (MB)      : total=$MEM_T used=$MEM_U free/avail=$MEM_F"
say "Swap (MB)     : total=$SWP_T used=$SWP_U free=$SWP_F"
say "Disk /        : size|used|avail|use% = $DISK"
say "IP route src  : ${SRC_IP:-UNKNOWN}"
say "IP public     : ${PUB_IP:-UNAVAILABLE}"
hr

# simple evaluation
# parse disk size in GB from df -h (best effort, supports G/T)
DISK_SIZE="$(echo "$DISK" | cut -d'|' -f1)"
DISK_GB=0
case "$DISK_SIZE" in
  *T) DISK_GB="$(echo "$DISK_SIZE" | sed 's/T//' | awk '{printf "%d", $1*1024}')" ;;
  *G) DISK_GB="$(echo "$DISK_SIZE" | sed 's/G//' | awk '{printf "%d", $1}')" ;;
  *M) DISK_GB=1 ;;
  *) DISK_GB=0 ;;
esac

SCORE="$(score_server "$CORES" "$MEM_T" "$DISK_GB")"
say "[*] VPS Score (kasar): $SCORE / 8"
say "[*] Penilaian: $(recommendation_from_score "$SCORE")"
hr

# ---------- Panel + Domain audit ----------
say "[*] Detecting panel..."
PANEL="$(detect_panel)"
say "[*] Panel detected: $PANEL"

# choose comparison IP: prefer public if available else route src
VPS_IP="${PUB_IP:-}"
[ -z "${VPS_IP:-}" ] && VPS_IP="${SRC_IP:-UNKNOWN}"

say "[*] VPS IP for compare: $VPS_IP"
hr

printf "%-35s | %-15s | %-15s | %-8s | %-30s | %s\n" \
"DOMAIN" "DOMAIN_IP" "VPS_IP" "IP_MATCH" "DOCROOT" "DOCROOT_STATUS"
hr

# ========================= CPANEL =========================
if [ "$PANEL" = "CPANEL/WHM" ] && [ -f /etc/userdomains ]; then
  awk -F': ' 'NF>=2 && $1 !~ /^#/ {print $1" "$2}' /etc/userdomains | while read -r domain user; do
    docroot="/home/$user/public_html"
    domain_ip="$(resolve_ip "$domain")"
    [ -z "${domain_ip:-}" ] && domain_ip="NO_DNS"

    if [ "$VPS_IP" != "UNKNOWN" ] && [ "$domain_ip" = "$VPS_IP" ]; then match="SAME_IP"; else match="WRONG_IP"; fi

    printf "%-35s | %-15s | %-15s | %-8s | %-30s | %s\n" \
      "$domain" "$domain_ip" "$VPS_IP" "$match" "$docroot" "$(check_docroot "$docroot")"
  done
  exit 0
fi

# ========================= PLESK =========================
if [ "$PANEL" = "PLESK" ] && [ -d /var/www/vhosts ]; then
  for d in /var/www/vhosts/*; do
    [ -d "$d" ] || continue
    domain="$(basename "$d")"
    docroot="$d/httpdocs"
    domain_ip="$(resolve_ip "$domain")"
    [ -z "${domain_ip:-}" ] && domain_ip="NO_DNS"
    if [ "$VPS_IP" != "UNKNOWN" ] && [ "$domain_ip" = "$VPS_IP" ]; then match="SAME_IP"; else match="WRONG_IP"; fi

    printf "%-35s | %-15s | %-15s | %-8s | %-30s | %s\n" \
      "$domain" "$domain_ip" "$VPS_IP" "$match" "$docroot" "$(check_docroot "$docroot")"
  done
  exit 0
fi

# ========================= DIRECTADMIN =========================
if [ "$PANEL" = "DIRECTADMIN" ] && [ -d /usr/local/directadmin/data/users ]; then
  for u in /usr/local/directadmin/data/users/*; do
    [ -d "$u" ] || continue
    user="$(basename "$u")"
    [ -d "$u/domains" ] || continue

    for f in "$u/domains"/*.conf; do
      [ -e "$f" ] || continue
      domain="$(basename "$f" .conf)"
      docroot="/home/$user/domains/$domain/public_html"

      domain_ip="$(resolve_ip "$domain")"
      [ -z "${domain_ip:-}" ] && domain_ip="NO_DNS"
      if [ "$VPS_IP" != "UNKNOWN" ] && [ "$domain_ip" = "$VPS_IP" ]; then match="SAME_IP"; else match="WRONG_IP"; fi

      printf "%-35s | %-15s | %-15s | %-8s | %-30s | %s\n" \
        "$domain" "$domain_ip" "$VPS_IP" "$match" "$docroot" "$(check_docroot "$docroot")"
    done
  done
  exit 0
fi

say "[!] Panel tidak dikenali atau domain tidak bisa di-enumerate otomatis pada sistem ini."
say "    Kalau panel UNKNOWN, kirim output ini supaya aku bisa buat parser khusus:"
say "    ls -d /usr/local/cpanel /usr/local/psa /usr/local/directadmin /www/server/panel 2>/dev/null"
