#!/usr/bin/env python3

from __future__ import annotations

import argparse
import subprocess
import time
from pathlib import Path


DEFAULT_CLIENT_MTU = "1280"
DEFAULT_CLIENT_KEEPALIVE = "25"
DEFAULT_ALLOWED_IPS = "0.0.0.0/0"
DEFAULT_PEER_DNS = "1.1.1.1,1.0.0.1"
SERVER_CONFIG_RELATIVE = Path("config") / "wg_confs" / "wg0.conf"
WIREGUARD_CONTAINER = "wireguard"
MANAGED_SERVER_LINES = (
    "PostUp = iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu",
    "PostUp = iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu",
    "PostDown = iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu",
    "PostDown = iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu",
)


class SyncError(RuntimeError):
    """Controlled synchronization failure."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Normalize generated WireGuard configs for mobile clients."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    sync_parser = subparsers.add_parser("sync")
    sync_parser.add_argument("--project-root", default=".")
    sync_parser.add_argument("--timeout", type=int, default=30)
    sync_parser.add_argument("--restart-container", action="store_true")

    return parser.parse_args()


def read_env_values(path: Path) -> dict[str, str]:
    if not path.exists():
        raise SyncError(f"Missing environment file: {path}")

    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def parse_peers(value: str) -> list[str]:
    return [peer for peer in (item.strip() for item in value.split(",")) if peer]


def peer_config_path(project_root: Path, peer_name: str) -> Path:
    return project_root / "config" / f"peer_{peer_name}" / f"peer_{peer_name}.conf"


def wait_for_file(path: Path, timeout_seconds: int) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if path.exists() and path.stat().st_size > 0:
            return
        time.sleep(1)
    raise SyncError(f"Timed out waiting for {path}")


def wait_for_generated_configs(project_root: Path, env_values: dict[str, str], timeout_seconds: int) -> list[str]:
    peer_names = parse_peers(env_values.get("PEERS", ""))
    if not peer_names:
        raise SyncError("No peers are configured in .env.")

    wait_for_file(project_root / SERVER_CONFIG_RELATIVE, timeout_seconds)
    for peer_name in peer_names:
        wait_for_file(peer_config_path(project_root, peer_name), timeout_seconds)
    return peer_names


def parse_sections(text: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    current_section: str | None = None

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()

        if stripped.startswith("[") and stripped.endswith("]"):
            current_section = stripped[1:-1]
            sections.setdefault(current_section, [])
            continue

        if current_section is not None:
            sections[current_section].append(line)

    return sections


def read_section_value(lines: list[str], key: str) -> str | None:
    prefix = f"{key} ="
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(prefix):
            return stripped.split("=", 1)[1].strip()
    return None


def require_section_value(sections: dict[str, list[str]], section: str, key: str, source: Path) -> str:
    value = read_section_value(sections.get(section, []), key)
    if not value:
        raise SyncError(f"Missing '{key}' in section [{section}] of {source}")
    return value


def normalize_address(value: str) -> str:
    value = value.strip()
    if "/" in value:
        return value
    return f"{value}/32"


def build_client_config(source: Path, env_values: dict[str, str]) -> str:
    sections = parse_sections(source.read_text(encoding="utf-8-sig"))
    interface_private_key = require_section_value(sections, "Interface", "PrivateKey", source)
    interface_address = normalize_address(
        require_section_value(sections, "Interface", "Address", source)
    )
    server_public_key = require_section_value(sections, "Peer", "PublicKey", source)
    preshared_key = read_section_value(sections.get("Peer", []), "PresharedKey")
    endpoint = f"{env_values['SERVERURL']}:{env_values['SERVERPORT']}"
    allowed_ips = env_values.get("ALLOWEDIPS", DEFAULT_ALLOWED_IPS)
    dns_value = env_values.get("PEERDNS", DEFAULT_PEER_DNS)
    client_mtu = env_values.get("CLIENT_MTU", DEFAULT_CLIENT_MTU)
    keepalive = env_values.get(
        "CLIENT_PERSISTENTKEEPALIVE",
        DEFAULT_CLIENT_KEEPALIVE,
    )

    lines = [
        "[Interface]",
        f"Address = {interface_address}",
        f"PrivateKey = {interface_private_key}",
        f"DNS = {dns_value}",
        f"MTU = {client_mtu}",
        "",
        "[Peer]",
        f"PublicKey = {server_public_key}",
    ]
    if preshared_key:
        lines.append(f"PresharedKey = {preshared_key}")
    lines.extend(
        [
            f"Endpoint = {endpoint}",
            f"AllowedIPs = {allowed_ips}",
            f"PersistentKeepalive = {keepalive}",
            "",
        ]
    )
    return "\n".join(lines)


def normalize_peer_configs(project_root: Path, env_values: dict[str, str], peer_names: list[str]) -> None:
    for peer_name in peer_names:
        config_path = peer_config_path(project_root, peer_name)
        config_path.write_text(build_client_config(config_path, env_values), encoding="utf-8")


def patch_server_config(project_root: Path, env_values: dict[str, str]) -> None:
    config_path = project_root / SERVER_CONFIG_RELATIVE
    client_mtu = env_values.get("CLIENT_MTU", DEFAULT_CLIENT_MTU)
    lines = config_path.read_text(encoding="utf-8-sig").splitlines()
    output: list[str] = []
    in_interface = False

    def append_managed_lines() -> None:
        output.append(f"MTU = {client_mtu}")
        output.extend(MANAGED_SERVER_LINES)

    for line in lines:
        stripped = line.strip()

        if stripped.startswith("[") and stripped.endswith("]"):
            if in_interface:
                append_managed_lines()
            in_interface = stripped == "[Interface]"
            output.append(line)
            continue

        if in_interface and (
            stripped.startswith("MTU =")
            or stripped in MANAGED_SERVER_LINES
        ):
            continue

        output.append(line)

    if in_interface:
        append_managed_lines()

    config_path.write_text("\n".join(output).rstrip() + "\n", encoding="utf-8")


def run_command(command: list[str], project_root: Path) -> None:
    try:
        subprocess.run(
            command,
            cwd=project_root,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        details = (exc.stderr or exc.stdout or "").strip() or "Unknown command error."
        raise SyncError(details) from exc
    except OSError as exc:
        raise SyncError(str(exc)) from exc


def wait_for_container_running(timeout_seconds: int) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            result = subprocess.run(
                ["docker", "inspect", "-f", "{{.State.Status}}", WIREGUARD_CONTAINER],
                check=True,
                capture_output=True,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError):
            time.sleep(1)
            continue

        if result.stdout.strip() == "running":
            return
        time.sleep(1)

    raise SyncError("WireGuard container did not return to 'running' state in time.")


def synchronize(project_root: Path, timeout_seconds: int, restart_container: bool) -> None:
    env_values = read_env_values(project_root / ".env")
    peer_names = wait_for_generated_configs(project_root, env_values, timeout_seconds)
    patch_server_config(project_root, env_values)
    normalize_peer_configs(project_root, env_values, peer_names)

    if restart_container:
        run_command(["docker", "restart", WIREGUARD_CONTAINER], project_root)
        wait_for_container_running(timeout_seconds)
        env_values = read_env_values(project_root / ".env")
        peer_names = wait_for_generated_configs(project_root, env_values, timeout_seconds)
        patch_server_config(project_root, env_values)
        normalize_peer_configs(project_root, env_values, peer_names)


def main() -> int:
    args = parse_args()
    project_root = Path(args.project_root).resolve()

    if args.command == "sync":
        synchronize(
            project_root=project_root,
            timeout_seconds=args.timeout,
            restart_container=args.restart_container,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
