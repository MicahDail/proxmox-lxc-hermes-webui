#!/usr/bin/env bash
# Create a new Proxmox LXC and install Hermes Agent + nesquena/hermes-webui.
# Does not modify any existing container.
set -euo pipefail

PROXMOX_HOST="${PROXMOX_HOST:-}"
CT_HOSTNAME="${CT_HOSTNAME:-hermes-webui}"
MEMORY_MB="${MEMORY_MB:-4096}"
CORES="${CORES:-4}"
DISK_GB="${DISK_GB:-32}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
TEMPLATE="${TEMPLATE:-}"
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
else
  SCRIPT_DIR=""
fi
FILES="${SCRIPT_DIR:+$SCRIPT_DIR/files}"
FILES_BASE_URL="${FILES_BASE_URL:-https://raw.githubusercontent.com/MicahDail/proxmox-lxc-hermes-webui/master/files}"
WEBUI_PORT="${WEBUI_PORT:-8787}"
WEBUI_HOST="${WEBUI_HOST:-0.0.0.0}"
DOCKER_IMAGE="${DOCKER_IMAGE:-nousresearch/hermes-sandbox:desktop}"

fetch_seed() {
  local rel=$1 dest=$2
  mkdir -p "$(dirname "$dest")"
  if [ -n "$FILES" ] && [ -f "$FILES/$rel" ]; then
    cp "$FILES/$rel" "$dest"
  else
    echo "Fetching files/$rel ..."
    curl -fsSL "$FILES_BASE_URL/$rel" -o "$dest"
  fi
}

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

prompt MODEL_URL "OpenAI-compatible base URL (must end in /v1)" "http://127.0.0.1:8000/v1"
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

if [ -z "${WEBUI_PASSWORD+x}" ]; then
  prompt WEBUI_PASSWORD "WebUI password (blank to generate)" ""
fi
if [ -z "${WEBUI_PASSWORD:-}" ]; then
  WEBUI_PASSWORD="$(openssl rand -base64 18)"
fi

if [ -z "${TS_AUTHKEY+x}" ]; then
  prompt_secret TS_AUTHKEY "Tailscale auth key"
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
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install.sh" ] && [ -f "$FILES/smith/SOUL.md" ]; then
    tar czf - -C "$SCRIPT_DIR" install.sh files | ssh -o BatchMode=yes "$PROXMOX_HOST" \
      "d=\$(mktemp -d) && tar xzf - -C \"\$d\" && chmod +x \"\$d/install.sh\" && \
       env CT_HOSTNAME='$CT_HOSTNAME' MEMORY_MB='$MEMORY_MB' CORES='$CORES' DISK_GB='$DISK_GB' \
         STORAGE='$STORAGE' BRIDGE='$BRIDGE' TEMPLATE='${TEMPLATE:-}' \
         WEBUI_PORT='$WEBUI_PORT' WEBUI_HOST='$WEBUI_HOST' VMID='${VMID:-}' \
         MODEL_URL='$MODEL_URL' MODEL_ID='$MODEL_ID' \
         MODEL_API_KEY='${MODEL_API_KEY-}' WEBUI_PASSWORD='$WEBUI_PASSWORD' \
         TS_AUTHKEY='${TS_AUTHKEY-}' \
         DOCKER_IMAGE='$DOCKER_IMAGE' FILES_BASE_URL='$FILES_BASE_URL' \"\$d/install.sh\""
  else
    ssh -o BatchMode=yes "$PROXMOX_HOST" \
      env CT_HOSTNAME="$CT_HOSTNAME" MEMORY_MB="$MEMORY_MB" CORES="$CORES" DISK_GB="$DISK_GB" \
        STORAGE="$STORAGE" BRIDGE="$BRIDGE" TEMPLATE="${TEMPLATE:-}" \
        WEBUI_PORT="$WEBUI_PORT" WEBUI_HOST="$WEBUI_HOST" VMID="${VMID:-}" \
        MODEL_URL="$MODEL_URL" MODEL_ID="$MODEL_ID" \
        MODEL_API_KEY="${MODEL_API_KEY-}" WEBUI_PASSWORD="$WEBUI_PASSWORD" \
        TS_AUTHKEY="${TS_AUTHKEY-}" \
        DOCKER_IMAGE="$DOCKER_IMAGE" FILES_BASE_URL="$FILES_BASE_URL" \
        bash -s < "${BASH_SOURCE[0]}"
  fi
  exit $?
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
echo "  docker: $DOCKER_IMAGE (workers); smith uses host terminal"
echo "  bind: 0.0.0.0 (LAN) + Tailscale serve"
echo "  storage: $STORAGE"
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
docker_image=$DOCKER_IMAGE
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
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged 0 \
  --features nesting=1 \
  --onboot 1 \
  --ostype debian \
  --arch amd64 \
  --password "$ROOT_PASSWORD" \
  --start 0

echo "Enabling /dev/net/tun for Tailscale ..."
cat >> "/etc/pve/lxc/${VMID}.conf" <<'EOF'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
pct start "$VMID"

ip=""
for _ in $(seq 1 30); do
  ip=$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}')
  if [ -n "$ip" ]; then
    break
  fi
  sleep 2
done
printf 'ip=%s\nwebui=http://%s:%s\n' "$ip" "$ip" "$WEBUI_PORT" >> "$CREDS"
if [ -z "$ip" ]; then
  echo "CT $VMID is up but has no DHCP address yet." >&2
else
  echo "CT $VMID is up at $ip"
fi

echo "Installing packages + Docker ..."
pct exec "$VMID" -- env DOCKER_IMAGE="$DOCKER_IMAGE" bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl ca-certificates python3 python3-venv python3-pip python3-dev build-essential sudo openssl docker.io
id hermes >/dev/null 2>&1 || useradd -m -s /bin/bash hermes
usermod -aG docker hermes
systemctl enable --now docker
docker pull "$DOCKER_IMAGE"
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
'

echo "Bringing Tailscale up ..."
if [ -n "${TS_AUTHKEY:-}" ]; then
  pct exec "$VMID" -- tailscale up --auth-key="$TS_AUTHKEY" --hostname="$CT_HOSTNAME" --accept-dns=false
else
  echo "Open the Tailscale login URL printed below, then wait."
  pct exec "$VMID" -- tailscale up --hostname="$CT_HOSTNAME" --accept-dns=false || true
fi
ts_ip=""
for _ in $(seq 1 60); do
  ts_ip=$(pct exec "$VMID" -- tailscale ip -4 2>/dev/null | head -1 || true)
  if [ -n "$ts_ip" ]; then
    break
  fi
  sleep 2
done
if [ -z "$ts_ip" ]; then
  echo "Tailscale has no IPv4 yet. Finish login: pct exec $VMID -- tailscale up" >&2
  exit 1
fi
printf 'tailscale_ip=%s\n' "$ts_ip" >> "$CREDS"
echo "Tailscale IPv4 $ts_ip"

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
hermes config set terminal.backend docker
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
    'API_SERVER_HOST=0.0.0.0',
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

echo "Seeding default soul, agent-template, and smith ..."
seed_dir=$(mktemp -d)
trap 'rm -rf "$seed_dir"' EXIT
fetch_seed default/SOUL.md "$seed_dir/default.SOUL.md"
fetch_seed default/skills/defer-onboard/SKILL.md "$seed_dir/defer-onboard.SKILL.md"
fetch_seed agent-template/SOUL.md "$seed_dir/agent-template.SOUL.md"
fetch_seed smith/SOUL.md "$seed_dir/smith.SOUL.md"
fetch_seed smith/skills/onboard-agent/SKILL.md "$seed_dir/onboard-agent.SKILL.md"

pct exec "$VMID" -- mkdir -p /home/hermes/.hermes/skills/defer-onboard
pct push "$VMID" "$seed_dir/default.SOUL.md" /home/hermes/.hermes/SOUL.md
pct push "$VMID" "$seed_dir/defer-onboard.SKILL.md" /home/hermes/.hermes/skills/defer-onboard/SKILL.md
pct push "$VMID" "$seed_dir/defer-onboard.SKILL.md" /tmp/defer-onboard.SKILL.md
pct push "$VMID" "$seed_dir/agent-template.SOUL.md" /tmp/agent-template.SOUL.md
pct push "$VMID" "$seed_dir/smith.SOUL.md" /tmp/smith.SOUL.md
pct push "$VMID" "$seed_dir/onboard-agent.SKILL.md" /tmp/onboard-agent.SKILL.md
pct exec "$VMID" -- chown -R hermes:hermes /home/hermes/.hermes /tmp/agent-template.SOUL.md /tmp/smith.SOUL.md /tmp/onboard-agent.SKILL.md /tmp/defer-onboard.SKILL.md

pct exec "$VMID" -- su - hermes -c "
set -e
export PATH=\"\$HOME/.local/bin:\$PATH\"
hermes profile create agent-template --description 'Parked clone source. Do not run work as this profile.'
hermes -p agent-template config set terminal.backend docker
hermes -p agent-template config set model.provider custom
hermes -p agent-template config set model.base_url '$MODEL_URL'
hermes -p agent-template config set model.default '$MODEL_ID'
install -m 644 /tmp/agent-template.SOUL.md \$HOME/.hermes/profiles/agent-template/SOUL.md
mkdir -p \$HOME/.hermes/profiles/agent-template/skills/defer-onboard
install -m 644 /tmp/defer-onboard.SKILL.md \$HOME/.hermes/profiles/agent-template/skills/defer-onboard/SKILL.md
python3 - <<'PY'
from pathlib import Path
p = Path.home() / '.hermes' / 'profiles' / 'agent-template' / 'config.yaml'
t = p.read_text() if p.exists() else ''
if 'gateway:' not in t:
    t = t.rstrip() + '\n\ngateway:\n  parked: true\n'
elif 'parked:' not in t:
    t = t.rstrip() + '\n  parked: true\n'
else:
    import re
    t = re.sub(r'parked:\\s*\\S+', 'parked: true', t)
p.write_text(t if t.endswith('\n') else t + '\n')
PY
hermes profile create smith --no-skills --description 'Mints new Hermes profiles from agent-template. Host terminal.'
hermes -p smith config set terminal.backend local
hermes -p smith config set model.provider custom
hermes -p smith config set model.base_url '$MODEL_URL'
hermes -p smith config set model.default '$MODEL_ID'
hermes -p smith config set tools.exec.timeout 120
for t in browser vision web_search image_gen speech tts web_extract code_execution container mcp; do
  hermes -p smith config set tools.\$t.enabled false 2>/dev/null || true
done
hermes -p smith config set tools.web.enabled true 2>/dev/null || true
python3 - <<'PY'
from pathlib import Path
p = Path.home() / '.hermes' / 'profiles' / 'smith' / 'config.yaml'
t = p.read_text() if p.exists() else ''
if 'platform_toolsets:' not in t:
    t = t.rstrip() + '''
platform_toolsets:
  cli:
    - clarify
    - file
    - memory
    - skills
    - terminal
    - todo
    - web
'''
p.write_text(t if t.endswith('\n') else t + '\n')
PY
install -m 644 /tmp/smith.SOUL.md \$HOME/.hermes/profiles/smith/SOUL.md
mkdir -p \$HOME/.hermes/profiles/smith/skills/onboard-agent
install -m 644 /tmp/onboard-agent.SKILL.md \$HOME/.hermes/profiles/smith/skills/onboard-agent/SKILL.md
python3 - <<'PY'
from pathlib import Path
import secrets, re
root = Path.home() / '.hermes'
base = (root / '.env').read_text() if (root / '.env').exists() else ''
openai_url = next((ln.split('=',1)[1] for ln in base.splitlines() if ln.startswith('OPENAI_BASE_URL=')), '')
openai_key = next((ln.split('=',1)[1] for ln in base.splitlines() if ln.startswith('OPENAI_API_KEY=')), '')
for slug in ('agent-template', 'smith'):
    envp = root / 'profiles' / slug / '.env'
    lines = [ln for ln in (envp.read_text().splitlines() if envp.exists() else []) if ln.strip() and not ln.startswith(('API_SERVER_KEY=', 'OPENAI_BASE_URL=', 'OPENAI_API_KEY=', 'API_SERVER_ENABLED=', 'API_SERVER_HOST='))]
    lines += [
        'API_SERVER_ENABLED=true',
        'API_SERVER_HOST=0.0.0.0',
        'API_SERVER_KEY=' + secrets.token_hex(32),
    ]
    if openai_url:
        lines.append('OPENAI_BASE_URL=' + openai_url)
    if openai_key:
        lines.append('OPENAI_API_KEY=' + openai_key)
    envp.write_text('\\n'.join(lines) + '\\n')
    envp.chmod(0o600)
PY
rm -f /tmp/agent-template.SOUL.md /tmp/smith.SOUL.md /tmp/onboard-agent.SKILL.md /tmp/defer-onboard.SKILL.md
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
After=network-online.target docker.service tailscaled.service
Wants=network-online.target docker.service tailscaled.service

[Service]
User=hermes
Group=hermes
SupplementaryGroups=docker
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

echo "Publishing WebUI and gateway on Tailscale ..."
gw_port="${API_SERVER_PORT:-8642}"
pct exec "$VMID" -- tailscale serve --bg --tcp "$WEBUI_PORT" "tcp://127.0.0.1:${WEBUI_PORT}"
pct exec "$VMID" -- tailscale serve --bg --tcp "$gw_port" "tcp://127.0.0.1:${gw_port}" || true
printf 'webui=http://%s:%s\ngateway=http://%s:%s/v1\n' "$ts_ip" "$WEBUI_PORT" "$ts_ip" "$gw_port" >> "$CREDS"

echo
echo "Done. Existing CTs were not modified."
echo "  WebUI:     http://${ip}:${WEBUI_PORT}  (LAN)"
echo "             http://${ts_ip}:${WEBUI_PORT}  (Tailscale)"
echo "  Password:  $WEBUI_PASSWORD"
echo "  Gateway:   http://${ip}:${gw_port}/v1  (LAN, API key)"
echo "             http://${ts_ip}:${gw_port}/v1  (Tailscale)"
echo "  Creds:     $CREDS (also has root password)"
echo "  Model:     $MODEL_ID @ $MODEL_URL"
echo "  Profiles:  default + agent-template (docker, parked) + smith (host; mints agents)"
echo "  Next:      open WebUI on Tailscale, switch to smith to mint people"
echo "  Inside:    pct enter $VMID"
