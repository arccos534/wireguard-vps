# WireGuard on VPS via Docker

This stack runs `WireGuard` in a separate folder and only exposes one UDP port, so it should not conflict with a website already using `80/443`.

It can also install a lightweight web panel for peer management:

- list current peers
- create a peer by name
- delete a peer
- download the `.conf`
- open a QR code for the `WireGuard` app

The exported client profile is normalized after each change, so the panel now generates a mobile-friendly config with:

- `Address = .../32`
- no client `ListenPort`
- `DNS = 1.1.1.1,1.0.0.1`
- `MTU = 1280`
- `PersistentKeepalive = 25`

## What you need

- Public `IP` or domain of the `VPS`
- Peer names for your devices, for example `phone,laptop`

You do not need to pre-generate `WireGuard` keys. They are created automatically on the server during first start.

## One-command deploy

After this repo is on GitHub, the server-side one-liner will look like this:

```bash
git clone https://github.com/arccos534/wireguard-vps.git /root/wireguard-vps && cd /root/wireguard-vps && bash install.sh --server-url YOUR_VPS_IP --peers phone,laptop --tz Asia/Vladivostok
```

If Docker is not installed yet and the server is `Ubuntu` or `Debian`, add `--install-docker`:

```bash
git clone https://github.com/arccos534/wireguard-vps.git /root/wireguard-vps && cd /root/wireguard-vps && bash install.sh --server-url YOUR_VPS_IP --peers phone,laptop --tz Asia/Vladivostok --install-docker
```

If you want the web panel too:

```bash
git clone https://github.com/arccos534/wireguard-vps.git /root/wireguard-vps && cd /root/wireguard-vps && bash install.sh --server-url YOUR_VPS_IP --peers phone,laptop --tz Asia/Vladivostok --with-panel --panel-password 'CHANGE_ME_NOW'
```

Or, if Docker is missing:

```bash
git clone https://github.com/arccos534/wireguard-vps.git /root/wireguard-vps && cd /root/wireguard-vps && bash install.sh --server-url YOUR_VPS_IP --peers phone,laptop --tz Asia/Vladivostok --install-docker --with-panel --panel-password 'CHANGE_ME_NOW'
```

## Files

- `docker-compose.yml` - container definition
- `.env.example` - variable reference
- `install.sh` - writes `.env`, starts the container, normalizes configs, and opens the needed ports in `ufw`
- `show-peer.sh` - prints the peer QR code and config path
- `wireguard_sync.py` - rewrites generated configs into a stable client profile and patches the server tunnel config
- `panel/` - Flask-based admin UI for peer management
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

The QR and `.conf` exported by the panel already include the mobile defaults above, so you should not need to manually tweak the tunnel on iPhone after scanning it. The stack keeps Docker's normal bridge networking and only publishes the chosen UDP port, which is safer for a VPS that is already serving a website over SSH and HTTP(S).

## Web panel

When installed with `--with-panel`, the panel runs as a `systemd` service on `51821/tcp` by default.

Open it in the browser:

```text
http://YOUR_VPS_IP:51821
```

Useful commands:

```bash
systemctl status wireguard-panel
journalctl -u wireguard-panel -n 100 --no-pager
```

If you do not pass `--panel-password`, the installer generates one and prints it once in the terminal.

## Add more devices later

1. Edit `.env`
2. Extend `PEERS`, for example `phone,laptop,tablet`
3. Recreate the container:

```bash
docker compose up -d
```

## Notes

- Keep the generated `./config` directory private: it contains private keys.
- If your hosting provider has a cloud firewall, allow your chosen `SERVERPORT/UDP` there too.
- If you expose the web panel to the internet, protect access with a strong password and ideally a provider firewall rule that only allows your own IP.
- Docker's docs warn that published container ports can bypass some `ufw` expectations, so provider firewall rules are a good extra layer.
- If `SERVERURL=auto` gives the wrong address, use the exact public IP instead.
