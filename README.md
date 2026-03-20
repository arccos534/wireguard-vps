# OpenVPN on VPS

This repo now uses a native `OpenVPN` setup on the host. No `Docker`, no `wg-easy`, no extra panel.

## What it does

- installs `OpenVPN` and `easy-rsa`
- creates a server config on the host
- generates one client profile as a ready-to-import `.ovpn`
- enables IP forwarding and NAT

## Install

For your current server:

```bash
cd /root/wireguard-vps
git pull
bash install.sh --host 138.124.88.205 --client phone --port 1194
```

After that the client file will be here:

```text
/root/wireguard-vps/openvpn-clients/phone/phone.ovpn
```

Import that file into `OpenVPN Connect`.

## Optional flags

```bash
bash install.sh --host YOUR_VPS_IP --client phone --port 1194 --dns 1.1.1.1,1.0.0.1 --subnet 10.8.0.0/24
```

## Notes

- `1194/udp` is the default `OpenVPN` port and does not conflict with a website on `80/443`.
- If your provider has an external firewall, open `1194/udp`.
- Existing `WireGuard` clients from the old stack should be considered obsolete.

## Check status

```bash
systemctl status openvpn-server@server --no-pager
systemctl status openvpn-server@server
```

## Sources

- https://openvpn.net/community-docs/
- https://openvpn.net/community-docs/community-articles/openvpn-2-4-manual.html
