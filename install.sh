#!/usr/bin/env bash
# Create a new Proxmox LXC and install Hermes Agent + nesquena/hermes-webui.
# Does not modify any existing container.
set -euo pipefail

PROXMOX_HOST="${PROXMOX_HOST:-}"
CT_HOSTNAME="${CT_HOSTNAME:-hermes-webui}"
MEMORY_MB="${MEMORY_MB:-4096}"
CORES="${CORES:-4}"
DISK_GB="${DISK_GB:-16}"
BRIDGE="${BRIDGE:-vmbr0}"
TEMPLATE="${TEMPLATE:-}"
WEBUI_PORT="${WEBUI_PORT:-8787}"
WEBUI_HOST="${WEBUI_HOST:-0.0.0.0}"

prompt() {
  local var=$1 msg=$2 def=${3-}
  if [ -n "${!var:-}" ]; then
    return 0
  fi
  if [ -t 0 ]; then
    if [ -n "$def" ]; then
      echo -n "$msg [$def] "
    else
      echo -n "$msg "
    fi
    read -r val
    val=${val:-$def}
  else
    val=$def
  fi
  printf -v "$var" '%s' "$val"
}

prompt_secret() {
  local var=$1 msg=$2
  if [ -n "${!var+x}" ]; then
    return 0
  fi
  if [ -t 0 ]; then
    echo -n "$msg (blank if none) "
    read -rs val
    echo
  else
    val=
  fi
  printf -v "$var" '%s' "$val"
}

prompt MODEL_URL "OpenAI-compatible base URL (must end in /v1)" "http://spark01.lan:8000/v1"
MODEL_URL="${MODEL_URL%/}"
case "$MODEL_URL" in
  */v1) ;;
  *) MODEL_URL="$MODEL_URL/v1" ;;
esac

prompt_secret MODEL_API_KEY "API key for that endpoint"

if [ -z "${MODEL_ID:-}" ]; then
  echo "Listing models at $MODEL_URL/models ..."
  if [ -n "${MODEL_API_KEY:-}" ]; then
    models_json=$(curl -fsS -H "Authorization: Bearer $MODEL_API_KEY" "$MODEL_URL/models" || true)
  else
    models_json=$(curl -fsS "$MODEL_URL/models" || true)
  fi
  model_ids=$(printf '%s' "$models_json" | python3 -c '
import json,sys
s=sys.stdin.read().strip()
if not s:
    raise SystemExit(0)
d=json.loads(s)
rows=d.get("data") or d.get("models") or []
for row in rows:
    if isinstance(row,str) and row.strip():
        print(row.strip())
    elif isinstance(row,dict) and row.get("id"):
        print(row["id"])
' 2>/dev/null || true)
  if [ -n "$model_ids" ]; then
    echo "Available models:"
    i=1
    while IFS= read -r id; do
      echo "  $i) $id"
      i=$((i + 1))
    done <<< "$model_ids"
    if [ -t 0 ]; then
      echo -n "Pick a number, or type a model id: "
      read -r choice
      if [ -z "$choice" ]; then
        MODEL_ID=$(echo "$model_ids" | sed -n '1p')
      elif [ "$choice" -eq "$choice" ] 2>/dev/null; then
        MODEL_ID=$(echo "$model_ids" | sed -n "${choice}p")
      else
        MODEL_ID=$choice
      fi
    else
      MODEL_ID=$(echo "$model_ids" | sed -n '1p')
    fi
  fi
fi
prompt MODEL_ID "Model id" "${MODEL_ID:-}"
if [ -z "$MODEL_ID" ]; then
  echo "Need MODEL_ID." >&2
  exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
  if [ -z "$PROXMOX_HOST" ] && [ -t 0 ]; then
    echo -n "Proxmox SSH target (user@host): "
    read -r PROXMOX_HOST
  fi
  if [ -z "$PROXMOX_HOST" ]; then
    echo "Set PROXMOX_HOST or run this script on the Proxmox host." >&2
    exit 1
  fi
  exec ssh -o BatchMode=yes "$PROXMOX_HOST" \
    env CT_HOSTNAME="$CT_HOSTNAME" MEMORY_MB="$MEMORY_MB" CORES="$CORES" DISK_GB="$DISK_GB" \
      BRIDGE="$BRIDGE" TEMPLATE="${TEMPLATE:-}" WEBUI_PORT="$WEBUI_PORT" WEBUI_HOST="$WEBUI_HOST" \
      VMID="${VMID:-}" MODEL_URL="$MODEL_URL" MODEL_ID="$MODEL_ID" \
      MODEL_API_KEY="${MODEL_API_KEY-}" WEBUI_PASSWORD="${WEBUI_PASSWORD:-}" \
      bash -s < "$0"
fi

command -v pct >/dev/null
command -v pvesh >/dev/null

if [ -z "${TEMPLATE:-}" ]; then
  TEMPLATE=$(pveam list local 2>/dev/null | awk '/debian-13-standard/{print $1; exit}')
  TEMPLATE="${TEMPLATE:-$(pveam list local 2>/dev/null | awk '/debian-12-standard/{print $1; exit}')}"
fi
if [ -z "$TEMPLATE" ]; then
  echo "No debian-12/13 template in local storage. Download one with pveam." >&2
  exit 1
fi

VMID="${VMID:-$(pvesh get /cluster/nextid)}"
if [ -f "/etc/pve/lxc/${VMID}.conf" ]; then
  echo "CT $VMID already exists. Set VMID to a free id." >&2
  exit 1
fi

ROOT_PASSWORD="${ROOT_PASSWORD:-$(openssl rand -base64 18)}"
WEBUI_PASSWORD="${WEBUI_PASSWORD:-$(openssl rand -base64 18)}"
CREDS="/root/${CT_HOSTNAME}-${VMID}.creds"

echo
echo "Will create NEW CT $VMID ($CT_HOSTNAME) from $TEMPLATE"
echo "  model: $MODEL_ID @ $MODEL_URL"
echo "  resources: ${MEMORY_MB}MB RAM, ${CORES} cores, ${DISK_GB}G disk"
echo "Existing containers will not be changed."
if [ -t 0 ]; then
  echo -n "Continue? [y/N] "
  read -r yn
  case "$yn" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

umask 077
cat > "$CREDS" <<EOF
vmid=$VMID
hostname=$CT_HOSTNAME
model_url=$MODEL_URL
model_id=$MODEL_ID
root_password=$ROOT_PASSWORD
webui_password=$WEBUI_PASSWORD
EOF
chmod 600 "$CREDS"

echo "Creating CT $VMID ..."
pct create "$VMID" "$TEMPLATE" \
  --hostname "$CT_HOSTNAME" \
  --memory "$MEMORY_MB" \
  --cores "$CORES" \
  --swap 512 \
  --rootfs "local-lvm:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged 0 \
  --features nesting=1 \
  --onboot 1 \
  --ostype debian \
  --arch amd64 \
  --password "$ROOT_PASSWORD" \
  --start 1

ip=""
for _ in $(seq 1 30); do
  ip=$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}')
  if [ -n "$ip" ]; then
    break
  fi
  sleep 2
done
printf 'ip=%s\nwebui=http://%s:%s\n' "$ip" "$ip" "$WEBUI_PORT" >> "$CREDS"
echo "CT $VMID is up${ip:+ at $ip}"

echo "Installing packages ..."
pct exec "$VMID" -- bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates python3 python3-venv python3-pip python3-dev build-essential sudo openssl
id hermes >/dev/null 2>&1 || useradd -m -s /bin/bash hermes
'

echo "Installing Hermes Agent (this can take several minutes) ..."
pct exec "$VMID" -- su - hermes -c '
set -e
export HOME=/home/hermes
export PATH="$HOME/.local/bin:$PATH"
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh -o /tmp/hermes-install.sh
bash /tmp/hermes-install.sh
command -v hermes
'

echo "Configuring custom model endpoint ..."
pct exec "$VMID" -- su - hermes -c "
set -e
export PATH=\"\$HOME/.local/bin:\$PATH\"
hermes config set model.provider custom
hermes config set model.base_url '$MODEL_URL'
hermes config set model.default '$MODEL_ID'
"

if [ -n "${MODEL_API_KEY:-}" ]; then
  keyf=$(mktemp)
  printf '%s' "$MODEL_API_KEY" > "$keyf"
  pct push "$VMID" "$keyf" /tmp/model.api.key
  rm -f "$keyf"
  pct exec "$VMID" -- chown hermes:hermes /tmp/model.api.key
fi

pct exec "$VMID" -- su - hermes -c "
set -e
python3 - <<'PY'
from pathlib import Path
import secrets
p = Path.home() / '.hermes' / '.env'
p.parent.mkdir(parents=True, exist_ok=True)
skip = (
    'API_SERVER_ENABLED=', 'API_SERVER_HOST=', 'API_SERVER_KEY=',
    'OPENAI_BASE_URL=', 'OPENAI_API_KEY=',
)
lines = [ln for ln in (p.read_text().splitlines() if p.exists() else []) if ln.strip() and not ln.startswith(skip)]
lines += [
    'API_SERVER_ENABLED=true',
    'API_SERVER_HOST=127.0.0.1',
    'API_SERVER_KEY=' + secrets.token_hex(32),
    'OPENAI_BASE_URL=$MODEL_URL',
]
kf = Path('/tmp/model.api.key')
if kf.exists():
    k = kf.read_text().strip()
    if k:
        lines.append('OPENAI_API_KEY=' + k)
    kf.unlink(missing_ok=True)
p.write_text('\\n'.join(lines) + '\\n')
p.chmod(0o600)
print('hermes env ready')
PY
"

echo "Starting Hermes gateway ..."
pct exec "$VMID" -- loginctl enable-linger hermes
pct exec "$VMID" -- su - hermes -c '
export PATH="$HOME/.local/bin:$PATH"
hermes gateway install
hermes gateway start
'

echo "Installing Hermes WebUI ..."
pct exec "$VMID" -- su - hermes -c 'git clone --depth 1 https://github.com/nesquena/hermes-webui.git /home/hermes/hermes-webui'

pwf=$(mktemp)
printf '%s' "$WEBUI_PASSWORD" > "$pwf"
pct push "$VMID" "$pwf" /tmp/webui.pw
rm -f "$pwf"
pct exec "$VMID" -- bash -lc "
umask 077
pw=\$(cat /tmp/webui.pw)
cat > /home/hermes/hermes-webui/.env <<EOF
HERMES_WEBUI_HOST=$WEBUI_HOST
HERMES_WEBUI_PORT=$WEBUI_PORT
HERMES_WEBUI_PASSWORD=\$pw
HERMES_WEBUI_SKIP_ONBOARDING=1
EOF
chown hermes:hermes /home/hermes/hermes-webui/.env
chmod 600 /home/hermes/hermes-webui/.env
rm -f /tmp/webui.pw
"

pct exec "$VMID" -- bash -lc "
cat > /etc/systemd/system/hermes-webui.service <<'EOF'
[Unit]
Description=Hermes WebUI
After=network-online.target
Wants=network-online.target

[Service]
User=hermes
Group=hermes
WorkingDirectory=/home/hermes/hermes-webui
Environment=HOME=/home/hermes
Environment=PATH=/home/hermes/.local/bin:/usr/bin:/bin
EnvironmentFile=/home/hermes/hermes-webui/.env
ExecStart=/usr/bin/python3 /home/hermes/hermes-webui/bootstrap.py --host 0.0.0.0 --foreground --skip-agent-install $WEBUI_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now hermes-webui.service
"

ok=0
for _ in $(seq 1 40); do
  code=$(pct exec "$VMID" -- curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEBUI_PORT}/health" || true)
  if [ "$code" = "200" ]; then
    ok=1
    break
  fi
  sleep 3
done
if [ "$ok" != 1 ]; then
  echo "WebUI did not become healthy. Check: pct exec $VMID -- journalctl -u hermes-webui -n 80" >&2
  exit 1
fi

echo
echo "Done. Existing CTs were not modified."
echo "  WebUI:  http://${ip}:${WEBUI_PORT}"
echo "  Creds:  $CREDS (root + webui passwords; not printed here)"
echo "  Model:  $MODEL_ID @ $MODEL_URL"
echo "  Inside: pct enter $VMID"
