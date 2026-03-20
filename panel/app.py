from __future__ import annotations

import hashlib
import hmac
import os
import re
import secrets
import shutil
import subprocess
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from functools import wraps
from pathlib import Path

from flask import (
    Flask,
    Response,
    abort,
    flash,
    redirect,
    render_template,
    request,
    send_file,
    session,
    url_for,
)
import qrcode
from qrcode.image.svg import SvgPathImage

try:
    import fcntl
except ImportError:  # pragma: no cover - Windows fallback for local editing.
    fcntl = None


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ENV_PATH = PROJECT_ROOT / ".env"
CONFIG_DIR = PROJECT_ROOT / "config"
SYNC_SCRIPT_PATH = PROJECT_ROOT / "wireguard_sync.py"
DELETED_DIR = CONFIG_DIR / "_deleted"
LOCK_PATH = PROJECT_ROOT / ".panel.lock"
WIREGUARD_CONTAINER = "wireguard"
PEER_RE = re.compile(r"^[A-Za-z0-9]+$")
ENV_ORDER = [
    "PUID",
    "PGID",
    "TZ",
    "SERVERURL",
    "SERVERPORT",
    "PEERS",
    "PEERDNS",
    "CLIENT_MTU",
    "CLIENT_PERSISTENTKEEPALIVE",
    "INTERNAL_SUBNET",
    "ALLOWEDIPS",
    "PERSISTENTKEEPALIVE_PEERS",
    "LOG_CONFS",
]
_WINDOWS_LOCK = threading.Lock()


@dataclass
class PeerInfo:
    name: str
    has_config: bool
    config_text: str
    modified_label: str
    size_label: str


def create_app() -> Flask:
    app = Flask(__name__)
    app.config.update(
        PANEL_PORT=int(os.environ.get("WG_PANEL_PORT", "51821")),
        PANEL_HOST=os.environ.get("WG_PANEL_HOST", "0.0.0.0"),
        PANEL_PASSWORD_HASH=os.environ.get("WG_PANEL_PASSWORD_HASH", ""),
        PANEL_URL=os.environ.get("WG_PANEL_URL", ""),
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_SECURE=os.environ.get("WG_PANEL_COOKIE_SECURE", "false").lower()
        == "true",
    )

    secret_key = os.environ.get("WG_PANEL_SECRET_KEY", "")
    if not secret_key:
        raise RuntimeError("WG_PANEL_SECRET_KEY is missing.")
    if not app.config["PANEL_PASSWORD_HASH"]:
        raise RuntimeError("WG_PANEL_PASSWORD_HASH is missing.")
    app.secret_key = secret_key

    @app.context_processor
    def inject_layout_context() -> dict[str, object]:
        return {
            "csrf_token": ensure_csrf_token(),
            "panel_port": app.config["PANEL_PORT"],
            "panel_url": app.config["PANEL_URL"],
        }

    @app.after_request
    def add_security_headers(response: Response) -> Response:
        response.headers.setdefault("Cache-Control", "no-store, private")
        response.headers.setdefault("Pragma", "no-cache")

        vary = response.headers.get("Vary", "")
        vary_values = [item.strip() for item in vary.split(",") if item.strip()]
        if "Cookie" not in vary_values:
            vary_values.append("Cookie")
            response.headers["Vary"] = ", ".join(vary_values)

        return response

    @app.get("/health")
    def health() -> tuple[dict[str, str], int]:
        return {"status": "ok"}, 200

    @app.route("/login", methods=["GET", "POST"])
    def login() -> Response:
        if request.method == "POST":
            validate_csrf(request.form.get("csrf_token", ""))
            password = request.form.get("password", "")

            if verify_password(app.config["PANEL_PASSWORD_HASH"], password):
                session.clear()
                session["authenticated"] = True
                ensure_csrf_token()
                flash("Panel unlocked.", "success")
                return redirect(url_for("dashboard"))

            flash("Wrong password.", "error")
            return redirect(url_for("login"))

        if session.get("authenticated"):
            return redirect(url_for("dashboard"))

        return render_template("login.html")

    @app.post("/logout")
    @login_required
    def logout() -> Response:
        validate_csrf(request.form.get("csrf_token", ""))
        session.clear()
        flash("You have been logged out.", "success")
        return redirect(url_for("login"))

    @app.get("/")
    @login_required
    def dashboard() -> str:
        try:
            env_values = read_env_values(ENV_PATH)
        except PanelError as exc:
            flash(str(exc), "error")
            env_values = {}
        peer_names = parse_peers(env_values.get("PEERS", ""))
        peers = [read_peer_info(name) for name in peer_names]
        peers.sort(key=lambda peer: peer.name.lower())

        return render_template(
            "dashboard.html",
            peers=peers,
            peer_count=len(peers),
            container_status=get_container_status(),
            server_url=env_values.get("SERVERURL", "-"),
            server_port=env_values.get("SERVERPORT", "-"),
            peer_dns=env_values.get("PEERDNS", "-"),
            internal_subnet=env_values.get("INTERNAL_SUBNET", "-"),
            allowed_ips=env_values.get("ALLOWEDIPS", "-"),
        )

    @app.post("/peers")
    @login_required
    def add_peer() -> Response:
        validate_csrf(request.form.get("csrf_token", ""))
        peer_name = request.form.get("name", "").strip()

        if not PEER_RE.fullmatch(peer_name):
            flash("Use only letters and numbers in the peer name.", "error")
            return redirect(url_for("dashboard"))

        try:
            add_peer_to_wireguard(peer_name)
        except PanelError as exc:
            flash(str(exc), "error")
        else:
            flash(f"Peer '{peer_name}' created.", "success")

        return redirect(url_for("dashboard"))

    @app.post("/peers/<peer_name>/delete")
    @login_required
    def delete_peer(peer_name: str) -> Response:
        validate_csrf(request.form.get("csrf_token", ""))
        if not PEER_RE.fullmatch(peer_name):
            abort(404)

        try:
            remove_peer_from_wireguard(peer_name)
        except PanelError as exc:
            flash(str(exc), "error")
        else:
            flash(f"Peer '{peer_name}' deleted.", "success")

        return redirect(url_for("dashboard"))

    @app.get("/peers/<peer_name>/download")
    @login_required
    def download_peer(peer_name: str) -> Response:
        if not PEER_RE.fullmatch(peer_name):
            abort(404)
        config_path = peer_config_path(peer_name)
        if not config_path.exists():
            abort(404)
        return send_file(
            config_path,
            as_attachment=True,
            download_name=f"{peer_name}.conf",
            mimetype="text/plain",
        )

    @app.get("/peers/<peer_name>/qr.svg")
    @login_required
    def peer_qr(peer_name: str) -> Response:
        if not PEER_RE.fullmatch(peer_name):
            abort(404)
        config_path = peer_config_path(peer_name)
        if not config_path.exists():
            abort(404)

        payload = config_path.read_text(encoding="utf-8")
        qr_image = qrcode.make(payload, image_factory=SvgPathImage)
        svg_markup = qr_image.to_string(encoding="unicode")
        if isinstance(svg_markup, bytes):
            svg_markup = svg_markup.decode("utf-8")
        return Response(svg_markup, mimetype="image/svg+xml")

    return app


class PanelError(RuntimeError):
    """Controlled error returned to the UI."""


def ensure_csrf_token() -> str:
    token = session.get("csrf_token")
    if not token:
        token = secrets.token_hex(16)
        session["csrf_token"] = token
    return token


def validate_csrf(candidate: str) -> None:
    token = session.get("csrf_token")
    if not token or not candidate or not hmac.compare_digest(token, candidate):
        abort(400, description="Invalid CSRF token.")


def login_required(view):
    @wraps(view)
    def wrapped_view(*args, **kwargs):
        if not session.get("authenticated"):
            return redirect(url_for("login"))
        return view(*args, **kwargs)

    return wrapped_view


def verify_password(stored_hash: str, password: str) -> bool:
    try:
        algorithm, iterations_text, salt_hex, digest_hex = stored_hash.split("$", 3)
    except ValueError:
        return False

    if algorithm != "pbkdf2_sha256":
        return False

    derived = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        bytes.fromhex(salt_hex),
        int(iterations_text),
    ).hex()
    return hmac.compare_digest(derived, digest_hex)


def parse_peers(value: str) -> list[str]:
    return [peer for peer in (item.strip() for item in value.split(",")) if peer]


def read_env_values(path: Path) -> dict[str, str]:
    if not path.exists():
        raise PanelError(f"Missing environment file: {path}")

    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def write_env_values(path: Path, values: dict[str, str]) -> None:
    ordered_keys = [key for key in ENV_ORDER if key in values]
    ordered_keys.extend(key for key in values if key not in ordered_keys)
    lines = [f"{key}={values[key]}" for key in ordered_keys]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def peer_config_path(peer_name: str) -> Path:
    return CONFIG_DIR / f"peer_{peer_name}" / f"peer_{peer_name}.conf"


def read_peer_info(peer_name: str) -> PeerInfo:
    config_path = peer_config_path(peer_name)
    if not config_path.exists():
        return PeerInfo(
            name=peer_name,
            has_config=False,
            config_text="Config has not been generated yet.",
            modified_label="pending",
            size_label="-",
        )

    stats = config_path.stat()
    modified_label = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(stats.st_mtime))
    size_label = f"{stats.st_size} bytes"
    return PeerInfo(
        name=peer_name,
        has_config=True,
        config_text=config_path.read_text(encoding="utf-8"),
        modified_label=modified_label,
        size_label=size_label,
    )


def get_container_status() -> str:
    try:
        result = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Status}}", WIREGUARD_CONTAINER],
            cwd=PROJECT_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    return result.stdout.strip() or "unknown"


def detect_compose_command() -> list[str]:
    checks = (
        ["docker", "compose", "version"],
        ["docker-compose", "version"],
    )
    for candidate in checks:
        try:
            subprocess.run(
                candidate,
                cwd=PROJECT_ROOT,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError):
            continue
        return candidate[:-1]
    raise PanelError("Docker Compose is not available on the server.")


def run_compose(*args: str) -> None:
    command = [*detect_compose_command(), *args]
    try:
        subprocess.run(
            command,
            cwd=PROJECT_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        stdout = (exc.stdout or "").strip()
        details = stderr or stdout or "Unknown docker compose error."
        raise PanelError(details) from exc
    except OSError as exc:
        raise PanelError(str(exc)) from exc


def run_wireguard_sync(restart_container: bool = False) -> None:
    python_command = shutil.which("python3") or shutil.which("python")
    if not python_command:
        raise PanelError("Python 3 is required to normalize WireGuard configs.")

    command = [python_command, str(SYNC_SCRIPT_PATH), "sync", "--project-root", str(PROJECT_ROOT)]
    if restart_container:
        command.append("--restart-container")

    try:
        subprocess.run(
            command,
            cwd=PROJECT_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        stdout = (exc.stdout or "").strip()
        details = stderr or stdout or "Unknown WireGuard sync error."
        raise PanelError(details) from exc
    except OSError as exc:
        raise PanelError(str(exc)) from exc


@contextmanager
def project_lock():
    LOCK_PATH.touch(exist_ok=True)
    with LOCK_PATH.open("r+", encoding="utf-8") as lock_handle:
        if fcntl is not None:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
        else:
            with _WINDOWS_LOCK:
                yield


def add_peer_to_wireguard(peer_name: str) -> None:
    with project_lock():
        env_values = read_env_values(ENV_PATH)
        peers = parse_peers(env_values.get("PEERS", ""))
        if peer_name in peers:
            raise PanelError(f"Peer '{peer_name}' already exists.")

        previous_text = ENV_PATH.read_text(encoding="utf-8")
        peers.append(peer_name)
        env_values["PEERS"] = ",".join(peers)
        write_env_values(ENV_PATH, env_values)

        try:
            run_compose("up", "-d", "wireguard")
            run_wireguard_sync(restart_container=True)
        except Exception:
            ENV_PATH.write_text(previous_text, encoding="utf-8")
            run_compose("up", "-d", "wireguard")
            run_wireguard_sync(restart_container=True)
            raise


def remove_peer_from_wireguard(peer_name: str) -> None:
    with project_lock():
        env_values = read_env_values(ENV_PATH)
        peers = parse_peers(env_values.get("PEERS", ""))

        if peer_name not in peers:
            raise PanelError(f"Peer '{peer_name}' does not exist.")
        if len(peers) == 1:
            raise PanelError("Keep at least one peer configured before deleting.")

        previous_text = ENV_PATH.read_text(encoding="utf-8")
        env_values["PEERS"] = ",".join([peer for peer in peers if peer != peer_name])
        write_env_values(ENV_PATH, env_values)

        try:
            run_compose("up", "-d", "wireguard")
            run_wireguard_sync(restart_container=True)
        except Exception:
            ENV_PATH.write_text(previous_text, encoding="utf-8")
            run_compose("up", "-d", "wireguard")
            run_wireguard_sync(restart_container=True)
            raise

        archive_peer_directory(peer_name)


def archive_peer_directory(peer_name: str) -> None:
    source = CONFIG_DIR / f"peer_{peer_name}"
    if not source.exists():
        return

    DELETED_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d%H%M%S")
    target = DELETED_DIR / f"{timestamp}_peer_{peer_name}"
    shutil.move(str(source), str(target))
