# proxmox-lxc-hermes-webui

Create a **new** Proxmox LXC and install [Hermes Agent](https://github.com/NousResearch/hermes-agent) plus [nesquena/hermes-webui](https://github.com/nesquena/hermes-webui), pointed at your OpenAI-compatible `/v1` endpoint.

Existing containers are never modified. The script refuses to reuse a VMID that already has a config file.

## What you get

- Debian LXC (privileged, DHCP on `vmbr0`)
- User `hermes` with Hermes Agent + messaging **gateway** (systemd user service + linger)
- Custom model: `model.provider=custom`, your base URL and model id
- Hermes WebUI on port **8787** (`0.0.0.0`), password-protected, systemd `hermes-webui.service`

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

Other knobs: `MEMORY_MB`, `CORES`, `DISK_GB`, `BRIDGE`, `TEMPLATE`, `WEBUI_PORT`, `WEBUI_HOST`, `WEBUI_PASSWORD`, `ROOT_PASSWORD`.

Without a TTY the script still requires `MODEL_URL` / `MODEL_ID` (or a reachable `/v1/models` list) and will proceed without the “Continue?” prompt only if you are non-interactive **and** those are set — actually looking at the script, non-interactive still asks Continue only if tty. Non-tty skips the confirm... wait, the confirm is `if [ -t 0 ]`. Non-interactive skips confirm. Good.

Passwords are written to `/root/<hostname>-<vmid>.creds` on the Proxmox host (mode 600). They are not printed.

## After install

Open `http://<ct-ip>:8787` and sign in with `webui_password` from the creds file.

```bash
pct enter <vmid>
su - hermes
```

## Notes

- Unprivileged create failed on at least one PVE host (`lxc-usernsexec` extract). This script uses a **privileged** CT.
- Optional Hermes tool `cua-driver` may fail without X11 libs; it is not required for WebUI/chat.
- Hermes Agent install can take several minutes (git clone + uv + tools).
