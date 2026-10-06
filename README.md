# proxmox-lxc-hermes-webui

Create a **new** Proxmox LXC and install [Hermes Agent](https://github.com/NousResearch/hermes-agent) plus [nesquena/hermes-webui](https://github.com/nesquena/hermes-webui), pointed at your OpenAI-compatible `/v1` endpoint.

Existing containers are never modified. The script refuses to reuse a VMID that already has a config file.

Run from a **git checkout** (`install.sh` plus `files/`). `curl | bash` will not work.

## What you get

- Debian LXC (privileged, nesting, DHCP)
- User `hermes` in group `docker`; Docker daemon + sandbox image pulled
- Hermes Agent + messaging **gateway** (systemd user service + linger)
- Custom model: `model.provider=custom`, your base URL and model id
- Hermes WebUI on port **8787**, password-protected, systemd `hermes-webui.service`

### Profiles

| Profile | Terminal | Gateway | Role |
|---|---|---|---|
| `default` | Docker | running | General chat. Defers hiring to smith. |
| `agent-template` | Docker | **parked** | Clone source for new workers. Do not run work as this profile. |
| `smith` | **host** (`local`) | running | Only minter. Clones `agent-template`, writes souls. |

Workers minted by smith inherit Docker. Smith is the only profile with host execution (`hermes` is also in `docker`; that is policy, not a jail).

Default soul + skill `defer-onboard`: if asked to mint an agent, tell the user to switch to **smith**. Do not run `hermes profile create`.

Smith skill `onboard-agent`: asks job, personality, pushback, uncertainty, length, avoids, name, model id, and skills; person names (not job slugs); `--description` is the job; always `--clone-from agent-template`; mint a new `API_SERVER_KEY` (clone strips it); never print keys or `/p/` URLs. Minted workers keep `defer-onboard` plus an **Agent onboarding** soul block pointing at smith.

## Run (on the Proxmox host)

```bash
git clone https://github.com/MicahDail/proxmox-lxc-hermes-webui.git
cd proxmox-lxc-hermes-webui
chmod +x install.sh
./install.sh
```

You will be asked for:

- OpenAI-compatible base URL (should end in `/v1`)
- Optional endpoint API key
- Model id (listed from `GET /v1/models` when possible)

Then confirm before `pct create`.

## Run from another machine

```bash
export PROXMOX_HOST=root@pve.example
./install.sh
```

The script tars `install.sh` + `files/` to the host and runs there. `pct` is not required locally.

## Non-interactive

```bash
export MODEL_URL=http://127.0.0.1:8000/v1
export MODEL_ID=your-model-id
export MODEL_API_KEY=          # optional; set empty if unused
export VMID=                   # optional; default is cluster nextid
export CT_HOSTNAME=hermes-webui
./install.sh
```

Other knobs: `MEMORY_MB`, `CORES`, `DISK_GB` (default 32), `STORAGE` (default `local-lvm`), `BRIDGE`, `TEMPLATE`, `WEBUI_PORT`, `WEBUI_HOST`, `WEBUI_PASSWORD`, `ROOT_PASSWORD`, `DOCKER_IMAGE` (default `nousresearch/hermes-sandbox:desktop`).

Non-tty skips the “Continue?” prompt.

Passwords are written to `/root/<hostname>-<vmid>.creds` on the Proxmox host (mode 600). They are not printed.

WebUI listens on `0.0.0.0` by default (password only). Put it behind a trusted LAN or change `WEBUI_HOST`.

## After install

Open `http://<ct-ip>:8787` and sign in with `webui_password` from the creds file.

Talk to **default** for general work. Switch to **smith** to mint a new agent. Open the new profile in the WebUI switcher (or `hermes -p <name> chat`).

A worker can use a different model id on the same endpoint: `hermes -p <name> config set model.default <id>`.

```bash
pct enter <vmid>
su - hermes
hermes profile list
```

If a Docker worker says the kernel/daemon is down but `docker` is running: the gateway was likely started before `hermes` was in group `docker`. Restart the user session, then the gateway:

```bash
systemctl restart user@$(id -u hermes).service
loginctl enable-linger hermes
su - hermes -c 'hermes gateway start'
```

Confirm the gateway PID has group `docker` (`grep ^Groups /proc/<pid>/status`).

## Notes

- Unprivileged create failed on at least one PVE host (`lxc-usernsexec` extract). This script uses a **privileged** CT.
- Optional Hermes tool `cua-driver` may fail without X11 libs; it is not required for WebUI/chat.
- Hermes Agent install can take several minutes (git clone + uv + tools). Docker image pull adds more.
- Soul and skill text lives under `files/`. `install.sh` copies those in; do not duplicate them in the script.
