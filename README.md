# WireGuard on VPS via Docker

This stack runs `WireGuard` in a separate folder and only exposes `51820/udp`, so it should not conflict with a website already using `80/443`.

## What you need

- Public `IP` or domain of the `VPS`
- Peer names for your devices, for example `phone,laptop`

You do not need to pre-generate `WireGuard` keys. They are created automatically on the server during first start.

## One-command deploy

After this repo is on GitHub, the server-side one-liner will look like this:

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/wireguard-vps.git /root/wireguard-vps && cd /root/wireguard-vps && bash install.sh --server-url YOUR_VPS_IP --peers phone,laptop --tz Asia/Vladivostok
```

If Docker is not installed yet and the server is `Ubuntu` or `Debian`, add `--install-docker`:

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/wireguard-vps.git /root/wireguard-vps && cd /root/wireguard-vps && bash install.sh --server-url YOUR_VPS_IP --peers phone,laptop --tz Asia/Vladivostok --install-docker
```

## Files

- `docker-compose.yml` - container definition
- `.env.example` - variable reference
- `install.sh` - writes `.env`, starts the container, and opens `51820/udp` in `ufw` if active
- `show-peer.sh` - prints the peer QR code and config path
- `./config/` - generated server keys and client configs

## After install

Check the running container:

```bash
docker compose ps
docker exec -it wireguard wg show
```

Show the QR code for a device:

```bash
bash show-peer.sh phone
```

Or open the generated config file directly:

```bash
cat ./config/peer_phone/peer_phone.conf
```

Import that config into the `WireGuard` app on your phone or computer.

## Add more devices later

1. Edit `.env`
2. Extend `PEERS`, for example `phone,laptop,tablet`
3. Recreate the container:

```bash
docker compose up -d
```

## Notes

- Keep the generated `./config` directory private: it contains private keys.
- If your hosting provider has a cloud firewall, allow `51820/UDP` there too.
- Docker's docs warn that published container ports can bypass some `ufw` expectations, so provider firewall rules are a good extra layer.
- If `SERVERURL=auto` gives the wrong address, use the exact public IP instead.
