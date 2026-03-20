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
- direct web UI on the VPS
- a temporary no-login setup so we can focus on getting the VPN itself online

## One-command install

If Docker is already installed:

```bash
git clone https://github.com/arccos534/wireguard-vps.git /root/wireguard-vps && cd /root/wireguard-vps && bash install.sh --host YOUR_VPS_IP --wg-device ens3
```

If Docker is missing:

```bash
git clone https://github.com/arccos534/wireguard-vps.git /root/wireguard-vps && cd /root/wireguard-vps && bash install.sh --host YOUR_VPS_IP --wg-device ens3 --install-docker
```

For your current server the intended command is:

```bash
cd /root/wireguard-vps
git pull
bash install.sh --host 138.124.88.205 --wg-port 443 --ui-port 51821 --wg-device ens3
```

## What the installer does

- enables `net.ipv4.ip_forward=1`
- writes `.env`
- backs up the old custom `config/` and panel files
- disables the old `wireguard-panel` systemd service
- starts `wg-easy`
- opens `WG_PORT/udp` and `UI_PORT/tcp` in `ufw` if `ufw` is active

## Admin UI

Open:

```text
http://YOUR_VPS_IP:51821
```

Create clients directly in the `wg-easy` UI and scan the QR there.

Login is intentionally disabled in this temporary setup.

## Files

- `docker-compose.yml` - `wg-easy` stack
- `.env.example` - variable reference
- `install.sh` - install/update entry point
- `show-peer.sh` - quick reminder helper for the new UI flow
- `reset-admin-password.sh` - helper that explains the temporary no-login mode
- `data/` - `wg-easy` persistent state

## Notes

- `443/udp` does not conflict with a website on `443/tcp`.
- The UI is temporarily exposed without login. Restrict access with provider firewall rules if you can.
- Existing clients from the old stack should be considered obsolete. Recreate them in `wg-easy`.

Sources:
- https://github.com/wg-easy/wg-easy
- https://github.com/wg-easy/wg-easy/wiki

## Native fallback

If the Docker UI path still gives you trouble, use the native installer instead. It installs `WireGuard` directly on the host, avoids Docker networking entirely, and creates one mobile-friendly client config plus a terminal QR.

For your current server:

```bash
cd /root/wireguard-vps
git pull
bash install-native.sh --host 138.124.88.205 --peer phone --wg-port 443
```

Then show the QR in the terminal:

```bash
cd /root/wireguard-vps
bash show-native-qr.sh phone
```

Or import the generated file:

```text
/root/wireguard-vps/native-clients/phone/phone.conf
```

This native path is the recommended fallback when the Docker UI is not worth fighting anymore.
