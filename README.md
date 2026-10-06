# proxmox-lxc-hermes-webui

Create a **new** Proxmox LXC and install [Hermes Agent](https://github.com/NousResearch/hermes-agent) plus [nesquena/hermes-webui](https://github.com/nesquena/hermes-webui), pointed at your OpenAI-compatible `/v1` endpoint.

Existing containers are never modified. The script refuses to reuse a VMID that already has a config file.

## What you get

- Debian LXC (privileged, nesting, DHCP on `vmbr0`)
- User `hermes` in group `docker`; Docker daemon + sandbox image pulled
- Hermes Agent + messaging **gateway** (systemd user service + linger)
- Custom model: `model.provider=custom`, your base URL and model id
- Hermes WebUI on port **8787** (`0.0.0.0`), password-protected, systemd `hermes-webui.service`

### Profiles

| Profile | Terminal | Gateway | Role |
|---|---|---|---|
| `default` | Docker | running | General chat. Defers hiring to smith. |
| `agent-template` | Docker | **parked** | Clone source for new workers. Do not run work as this profile. |
| `smith` | **host** (`local`) | running | Only minter. Clones `agent-template`, writes souls. |

Workers minted by smith inherit Docker. Smith is the only profile with host execution (`hermes` is also in `docker`; that is policy, not a jail).

Default soul + skill `defer-onboard`: if asked to mint an agent, tell the user to switch to **smith**. Do not run `hermes profile create`.

Smith skill `onboard-agent`: person names (not job slugs), `--description` is the job, always `--clone-from agent-template`, mint a new `API_SERVER_KEY` (clone strips it), never print keys or `/p/` URLs. Minted workers keep `defer-onboard` plus an **Agent onboarding** soul block pointing at smith.

## Run (on the Proxmox host)

```bash
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
export PROXMOX_HOST=root@proxmox01.lan
./install.sh
```

`pct` is not required locally; the script SSHs to the host and re-executes itself there.

## Non-interactive

```bash
export MODEL_URL=http://spark01.lan:8000/v1
export MODEL_ID=qwen3.8-flash-next
export MODEL_API_KEY=          # optional; set empty if unused
export VMID=116                # optional; default is cluster nextid
export CT_HOSTNAME=hermes-webui
./install.sh
```

Other knobs: `MEMORY_MB`, `CORES`, `DISK_GB`, `BRIDGE`, `TEMPLATE`, `WEBUI_PORT`, `WEBUI_HOST`, `WEBUI_PASSWORD`, `ROOT_PASSWORD`, `DOCKER_IMAGE` (default `nousresearch/hermes-sandbox:desktop`).

Non-tty skips the “Continue?” prompt.

Passwords are written to `/root/<hostname>-<vmid>.creds` on the Proxmox host (mode 600). They are not printed.

## After install

Open `http://<ct-ip>:8787` and sign in with `webui_password` from the creds file.

Talk to **default** for general work. Switch to **smith** to mint a new agent. Open the new profile in the WebUI switcher (or `hermes -p <name> chat`).

```bash
pct enter <vmid>
su - hermes
hermes profile list
```

If a Docker worker says the kernel/daemon is down but `docker` is running: the gateway was likely started before `hermes` was in group `docker`. Restart the user session, then the gateway:

```bash
systemctl restart user@1000.service
loginctl enable-linger hermes
su - hermes -c 'hermes gateway start'
```

Confirm the gateway PID has group `docker` (`grep ^Groups /proc/<pid>/status`).

## Notes

- Unprivileged create failed on at least one PVE host (`lxc-usernsexec` extract). This script uses a **privileged** CT.
- Optional Hermes tool `cua-driver` may fail without X11 libs; it is not required for WebUI/chat.
- Hermes Agent install can take several minutes (git clone + uv + tools). Docker image pull adds more.
- Seed files under `files/` match what `install.sh` writes; the script embeds copies so `ssh bash -s` still works.
