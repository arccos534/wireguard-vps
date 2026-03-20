# wg-easy on VPS via Docker

This repo now uses `wg-easy` as the backend and admin panel. It replaces the earlier custom panel + `linuxserver/wireguard` flow with a simpler stack:

- `WireGuard` server
- built-in web admin UI
- QR generation inside the same product
- built-in client creation and deletion

## Why this switch

The old stack became too fragile on this VPS: container startup, NAT rules, generated configs, and panel behavior all needed too many manual fixes.

`wg-easy` is purpose-built for exactly this use case, and the official docs cover:

- unattended first-time setup
- built-in admin password reset CLI
- no-reverse-proxy setup with `INSECURE=true`

## One-command install

If Docker is already installed:

```bash
git clone https://github.com/arccos534/wireguard-vps.git /root/wireguard-vps && cd /root/wireguard-vps && bash install.sh --host YOUR_VPS_IP --password 'CHANGE_ME_NOW'
```

If Docker is missing:

```bash
git clone https://github.com/arccos534/wireguard-vps.git /root/wireguard-vps && cd /root/wireguard-vps && bash install.sh --host YOUR_VPS_IP --password 'CHANGE_ME_NOW' --install-docker
```

For your current server the intended command is:

```bash
cd /root/wireguard-vps
git pull
bash install.sh --host 138.124.88.205 --wg-port 443 --ui-port 51821 --password 'CHANGE_ME_NOW'
```

## What the installer does

- enables `net.ipv4.ip_forward=1`
- writes `.env`
- backs up the old custom `config/` and panel files
- disables the old `wireguard-panel` systemd service
- starts `wg-easy`
- resets the admin password through the official `wg-easy` CLI
- opens `WG_PORT/udp` and `UI_PORT/tcp` in `ufw` if `ufw` is active

## Admin UI

Open:

```text
http://YOUR_VPS_IP:51821
```

Create clients directly in the `wg-easy` UI and scan the QR there.

## Reset the admin password later

```bash
cd /root/wireguard-vps
docker compose exec -it wg-easy cli db:admin:reset --password 'NEW_PASSWORD'
```

## Files

- `docker-compose.yml` - `wg-easy` stack
- `.env.example` - variable reference
- `install.sh` - install/update entry point
- `show-peer.sh` - quick reminder helper for the new UI flow
- `reset-admin-password.sh` - helper for changing the admin password
- `data/` - `wg-easy` persistent state

## Notes

- `443/udp` does not conflict with a website on `443/tcp`.
- The UI is exposed with `INSECURE=true`, which matches the official no-reverse-proxy docs. Restrict access with provider firewall rules if you can.
- Existing clients from the old stack should be considered obsolete. Recreate them in `wg-easy`.

Sources:
- https://github.com/wg-easy/wg-easy
- https://wg-easy.github.io/wg-easy/latest/advanced/config/unattended-setup/
- https://wg-easy.github.io/wg-easy/latest/guides/cli/
- https://wg-easy.github.io/wg-easy/latest/examples/tutorials/reverse-proxyless/
