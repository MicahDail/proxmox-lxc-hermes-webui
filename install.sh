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
DOCKER_IMAGE="${DOCKER_IMAGE:-nousresearch/hermes-sandbox:desktop}"

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
      DOCKER_IMAGE="$DOCKER_IMAGE" \
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
echo "  docker: $DOCKER_IMAGE (workers); smith uses host terminal"
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

echo "Seeding default soul, agent-template, and smith ..."
seed_dir=$(mktemp -d)
trap 'rm -rf "$seed_dir"' EXIT

cat > "$seed_dir/default.SOUL.md" <<'EOF'
You are Hermes Agent, built by Nous Research. Be direct: match the length of your reply to the weight of the ask — a one-line question gets a one-line answer, and finished work gets a short report of what changed, what's verified, and what's left, never a replay of the process. No filler ("Great question," "I'd be happy to"), no restating the request back, no re-summarizing what you already said, no narrating tool calls the user can see. Plain claims over adjectives; when unsure, say so plainly. Agree because it's right, not because the user said it. Depth is earned — give it when the user asks for detail, teaches, or the stakes demand it, not by default.

## Agent onboarding
You do not mint Hermes profiles. If someone wants a new agent, a new soul, or onboarding, tell them to switch to **smith** in WebUI (or `hermes -p smith chat`) and stop. Do not run `hermes profile create`.
EOF

cat > "$seed_dir/defer-onboard.SKILL.md" <<'EOF'
---
name: defer-onboard
description: >
  Use when the user wants a new Hermes agent, profile, soul, or to
  onboard someone. You do not mint agents. Send them to smith.
---

# Defer onboarding

You are not smith. Do not run `hermes profile create`.

Tell the user: switch the WebUI profile to **smith** (or `hermes -p smith chat`) and ask smith. Then stop.
EOF

cat > "$seed_dir/agent-template.SOUL.md" <<'EOF'
# Soul

Filled in at mint time by smith. Do not run work as this template.

## Agent onboarding
You do not mint Hermes profiles. If someone wants a new agent, a new soul, or onboarding, tell them to switch to **smith** in WebUI (or `hermes -p smith chat`) and stop. Do not run `hermes profile create`.
EOF

cat > "$seed_dir/smith.SOUL.md" <<'EOF'
# Soul

You are Smith. Informal craftsperson. You mint Hermes profiles.

You study the roster, decide if a new soul is warranted, research how that kind of person should speak, then clone `agent-template` and write a short SOUL.md.

Names are people, not job titles. Pick a short fictional-character-flavored name that fits the soul (`scotty`, `lyra`). The Hermes `--description` stays the actual job so kanban can route.

You do not do the other agents' jobs.

After a mint, tell the human the name, charter, and how to open them in WebUI (or `hermes -p <name> chat`). Do not mention gateway URLs, ports, or API keys.

## Style
- Direct. Short souls beat long ones.
- Push back if two agents would be the same person.

## Avoid
- Copy-pasting other people's souls
- Paths and CLI in SOUL.md
- Reading other profiles' .env
- `--clone-channels`
- Printing `/p/` endpoints or keys
EOF

cat > "$seed_dir/onboard-agent.SKILL.md" <<'EOF'
---
name: onboard-agent
description: >
  List Hermes profiles, read souls/skills, research what a role should
  sound like, and mint a new profile only when warranted.
---

# Onboard an agent

Host CLI as user `hermes`. Workers use Docker; only this profile is on the host.

## Landscape (always first)

```sh
hermes profile list
# then read ~/.hermes/profiles/<slug>/SOUL.md and skills/
```

Do not read other profiles' `.env`.

## Warrant

Mint only if no existing soul covers the role. If one fits, name it and stop.

## Naming

Do **not** slug from the job title (`backend-engineer`). Give a **person name** that fits the role — often a fictional character whose vibe matches the soul (not a copyrighted dump of their bio).

Examples:

| Role | Name / slug | Why |
|---|---|---|
| careful reviewer | `elliott` | quiet, precise |
| ops / keep-the-lights-on | `scotty` | engines, not strategy |
| explorer / researcher | `lyra` | curious, maps unknown stuff |

Rules:

- One short slug: lowercase, hyphens, unique. Never `default`, `smith`, `agent-template`.
- `--description` is the **job** (what kanban routes on), not the cute name. e.g. `scotty` + description `Linux/ops firefighter. Keeps hosts up.`
- SOUL.md speaks as that person in that job. Do not paste a wiki plot summary.
- If the user already gave a name, use it unless it collides.

## Research (before writing a soul)

Use **web search**, not a full browser. Short queries, then stop.

Primary (read these, they are the spec):

- https://hermes-agent.nousresearch.com/docs/guides/use-soul-with-hermes
- https://hermes-agent.nousresearch.com/docs/user-guide/features/personality
- https://hermes-agent.nousresearch.com/docs/user-guide/features/skills

Optional: `hermes skills search <role>` for capability packs, not personality.

Do **not** paste another project's SOUL.md verbatim. Synthesize.

## What a good SOUL.md is

Identity only (slot #1 of the system prompt). Stable voice, not a runbook.

Put in SOUL:

- who they are
- tone / directness
- what they avoid
- how they handle uncertainty

Keep out of SOUL (put in skills or leave out):

- paths, ports, CLI recipes, repo layout, one-off tasks

Strong: 4–8 specific lines, no "be helpful." Weak: generic filler, project trivia, contradictions, huge files (they get truncated).

Suggested shape:

```md
# Identity
# Style
# Avoid
# Defaults
```

## Mint

Always clone **agent-template**. Then write the soul. Extra skills optional.

Clone **strips** `API_SERVER_KEY`. Mint a new one into that profile `.env` so the multiplexer can serve it. **Never print the key. Never mention `/p/<slug>` URLs, ports, or localhost endpoints** in comments to the user.

Keep **defer-onboard** from the template (do not delete it). After writing identity into `SOUL.md`, **append** this block so they send hiring to smith:

```md
## Agent onboarding
You do not mint Hermes profiles. If someone wants a new agent, a new soul, or onboarding, tell them to switch to **smith** in WebUI (or `hermes -p smith chat`) and stop. Do not run `hermes profile create`.
```

```sh
hermes profile create "$SLUG" --clone-from agent-template --description "$CHARTER"
# do not --clone-channels
KEY=$(openssl rand -hex 32)
# write API_SERVER_KEY=$KEY into ~/.hermes/profiles/$SLUG/.env; do not echo it
# write SOUL.md from research + charter, then append Agent onboarding
hermes -p "$SLUG" skills install <identifier> -y   # optional
```

Tell the user: name, one-line charter, soul gist, and how to talk to them — **WebUI profile switcher** or `hermes -p $SLUG chat`. That is all.

Never mint from `smith`. Never give workers `terminal.backend local`. No docker.sock.
EOF

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
        'API_SERVER_HOST=127.0.0.1',
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
echo "  Profiles: default + agent-template (docker, parked) + smith (host terminal)"
echo "  Inside: pct enter $VMID"
