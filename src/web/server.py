#!/usr/bin/env python3

import argparse
import base64
import errno
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
from pathlib import Path
import plistlib
import secrets
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
import xml.etree.ElementTree as ET

from websockets.exceptions import WebSocketException
from websockets.sync.client import connect

SERIAL = "X01200UWX4Y2"
WIFI_MAC = bytes.fromhex("38e7c07bde72")
CHALLENGE_KEY = "F3A278B8-1C6F-44A9-9D89-F1979CA4C6F1"
KEYS = frozenset({
    "Home", "Back", "Info", "Up", "Down", "Left", "Right", "Select",
    "Play", "Rev", "Fwd", "InstantReplay", "VolumeUp", "VolumeDown",
    "VolumeMute", "ChannelUp", "ChannelDown",
})
PICTURE_FIELDS = frozenset({"gamma", "color_temp", "noise_reduction", "color_space"})
POWER_SETTLE_SECONDS = 10


class TVError(Exception):
    def __init__(self, message, status=502):
        super().__init__(message)
        self.status = status


def required_text(value, name):
    if not isinstance(value, str) or not value:
        raise TVError(f"Missing or invalid {name}.", 400)
    return value


def mac_command(arguments, timeout=8):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise TVError("macOS control timed out. An app or picker may already have opened; no action was repeated.", 503) from error
    except OSError as error:
        raise TVError(f"Cannot run the macOS control: {error}", 503) from error
    if result.returncode:
        raise TVError(result.stderr.strip() or f"macOS control exited with status {result.returncode}.", 503)
    return result.stdout


def browser_address(address):
    if not isinstance(address, str):
        raise TVError("Enter a website address or search text.", 400)
    text = address.strip()
    if not text:
        return "about:blank"
    if any(ord(character) < 32 or ord(character) == 127 for character in text):
        raise TVError("The address contains control characters.", 400)
    try:
        parsed = urllib.parse.urlsplit(text)
        if parsed.scheme:
            if parsed.scheme.lower() not in {"http", "https"}:
                raise TVError("Only HTTP and HTTPS website addresses can be opened.", 400)
            if not parsed.hostname or any(character.isspace() for character in text):
                raise ValueError("Invalid website address")
            parsed.port
            return text
        if not any(character.isspace() for character in text) and ("." in text.split("/", 1)[0] or text.startswith("//") or text.split("/", 1)[0] == "localhost"):
            candidate = "https:" + text if text.startswith("//") else "https://" + text
            parsed = urllib.parse.urlsplit(candidate)
            if not parsed.hostname:
                raise ValueError("Missing website host")
            parsed.port
            return candidate
    except ValueError as error:
        raise TVError(f"Invalid website address: {error}", 400) from error
    return "https://duckduckgo.com/?" + urllib.parse.urlencode({"q": text})


def mac_display_state():
    try:
        report = json.loads(mac_command(["/usr/sbin/system_profiler", "SPDisplaysDataType", "-json"]))
        adapters = report["SPDisplaysDataType"]
        if not isinstance(adapters, list):
            raise ValueError("Unexpected display inventory")
        displays = []
        for adapter in adapters:
            for display in adapter.get("spdisplays_ndrvs", []):
                mirror_code = display.get("spdisplays_mirror")
                displays.append({
                    "name": display.get("_name"), "id": display.get("_spdisplays_displayID"),
                    "online": {"spdisplays_yes": True, "spdisplays_no": False}.get(display.get("spdisplays_online")),
                    "mirroring": {"spdisplays_on": True, "spdisplays_off": False}.get(mirror_code),
                    "mirror_code": mirror_code, "connection_type": display.get("spdisplays_connection_type"),
                })
        active = [display for display in displays if display["online"] is True]
        if any(display["mirroring"] is True for display in active):
            mirror_status = "detected"
        elif active and all(display["mirroring"] is False for display in active):
            mirror_status = "not_detected"
        else:
            mirror_status = "unknown"
        return {"desktop_mirroring": mirror_status, "displays": displays, "observed_at": time.time()}
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        raise TVError(f"Cannot interpret macOS display state: {error}", 503) from error


def open_mirroring_picker():
    script = Path(__file__).with_name("mirroring.applescript")
    return mac_command(["/usr/bin/osascript", str(script)]).strip()


def open_mac_browser(payload, roku):
    if set(payload) != {"address", "show_mirroring"} or not isinstance(payload["show_mirroring"], bool):
        raise TVError("Provide an address and an explicit show_mirroring boolean.", 400)
    url = browser_address(payload["address"])
    mac_command(["/usr/bin/open", "-a", "Safari", url])
    picker = {"requested": payload["show_mirroring"], "opened": False}
    if payload["show_mirroring"]:
        try:
            receiver = roku.airplay_receiver()
            picker["receiver"] = receiver
            folder = Path(__file__).parent
            selection = mac_command([
                "/usr/bin/osascript", str(folder / "connect-mirroring.applescript"),
                receiver["device_id"], str(folder / "mirroring.applescript"),
            ]).strip()
            if selection not in {"already_connected", "connection_requested"}:
                raise TVError("macOS returned an unknown receiver-selection state. Check the picker; no action was repeated.", 503)
            picker["opened"] = True
            picker["selection"] = selection
            picker["message"] = f"{receiver['name']} is already in macOS Currently Mirroring." if selection == "already_connected" else f"AirPlay connection requested for {receiver['name']}; complete any macOS code/sharing prompts."
        except TVError as error:
            picker["error"] = str(error)
    return {
        "browser": "Safari", "launch_accepted": True, "requested_address": payload["address"],
        "url": url, "picker": picker,
        "message": "Safari launch accepted. " + picker["message"] if picker["opened"] else "Safari launch accepted. It appears on the TV only while macOS is sharing its screen or browser window.",
    }


def browser_state(roku):
    try:
        state = mac_display_state()
    except TVError as error:
        state = {"desktop_mirroring": "unknown", "displays": [], "error": str(error)}
    try:
        state["receiver"] = {"available": True, **roku.airplay_receiver()}
    except TVError as error:
        state["receiver"] = {"available": False, "error": str(error)}
    return state


class Roku:

    def __init__(self, ip):
        self.ip = str(ip)
        self.ws = None
        self.counter = 0
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.power_settle_until = time.monotonic() + POWER_SETTLE_SECONDS

    def close(self):
        connection, self.ws = self.ws, None
        if connection is not None:
            connection.close()

    def wait_power_settle(self):
        remaining = self.power_settle_until - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)

    def command(self, path):
        self.wait_power_settle()
        identity = self.require_control()
        if identity.findtext("power-mode") != "PowerOn":
            raise TVError("The TV display is off or its state is unknown. Use Power on, then Refresh before navigation or sound commands.", 409)
        self.http_post(path)

    def http_post(self, path):
        request = urllib.request.Request(f"http://{self.ip}:8060/{path}", data=b"")
        try:
            with self.http.open(request, timeout=4) as response:
                response.read(4096)
        except urllib.error.HTTPError as error:
            raise TVError(f"TV rejected the command with HTTP {error.code}.", error.code if 400 <= error.code < 500 else 502) from error
        except (OSError, urllib.error.URLError) as error:
            raise TVError(f"TV command was not confirmed: {error}. It may have applied; no retry was sent.") from error

    def exchange(self, operation, params):
        self.counter += 1
        request_id = str(self.counter)
        self.ws.send(json.dumps({"request": operation, "request-id": request_id, **params}))
        deadline = time.monotonic() + 5
        while True:
            response = json.loads(self.ws.recv(timeout=max(0, deadline - time.monotonic())))
            if not isinstance(response, dict):
                raise TVError("Invalid TV response.")
            if response.get("response-id") != request_id:
                continue
            if response.get("response") != operation:
                raise TVError("TV response operation does not match the request.")
            try:
                code = int(response["status"])
            except (KeyError, ValueError, TypeError) as error:
                raise TVError("TV response omitted a valid status.") from error
            if not 200 <= code < 300:
                hint = " Enable Control by mobile apps on the TV." if code == 403 else ""
                raise TVError(f"{operation}: TV returned {code} {response.get('status-msg', '')}.{hint}", code if 400 <= code < 500 else 502)
            return response

    @staticmethod
    def parse_xml(response, root_name):
        try:
            root = ET.fromstring(base64.b64decode(response["content-data"], validate=True))
            if root.tag != root_name:
                raise ValueError(f"Expected {root_name}, received {root.tag}")
            return root
        except (ET.ParseError, ValueError, KeyError, TypeError) as error:
            raise TVError(f"Invalid {root_name} response: {error}") from error

    def open(self):
        self.ws = connect(
            f"ws://{self.ip}:8060/ecp-session", subprotocols=["ecp-2"],
            compression=None, proxy=None, open_timeout=4, close_timeout=1,
            ping_interval=None, user_agent_header=None,
        )
        challenge = json.loads(self.ws.recv(timeout=5))
        if not isinstance(challenge, dict) or challenge.get("notify") != "authenticate" or not isinstance(challenge.get("param-challenge"), str):
            raise TVError("TV did not provide the expected ECP2 authentication challenge.")
        answer = base64.b64encode(hashlib.sha1((challenge["param-challenge"] + CHALLENGE_KEY).encode()).digest()).decode()
        self.exchange("authenticate", {"param-response": answer, "param-client-friendly-name": "CouchKeys", "param-has-microphone": "false"})
        identity = self.parse_xml(self.exchange("query-device-info", {}), "device-info")
        if identity.findtext("serial-number") != SERIAL or identity.findtext("vendor-name") != "TCL":
            raise TVError("Connected device is not your selected TCL. No control command sent.", 409)

    def request(self, operation, **params):
        try:
            if self.ws is None:
                self.open()
            return self.exchange(operation, params)
        except (OSError, WebSocketException, ValueError) as error:
            self.close()
            raise TVError(f"TV connection failed: {error}. A sent command may have applied; no command was retried. Check connection before continuing.") from error
        except TVError:
            self.close()
            raise

    def xml(self, operation, root_name, **params):
        return self.parse_xml(self.request(operation, **params), root_name)

    def require_control(self):
        identity = self.xml("query-device-info", "device-info")
        if identity.findtext("ecp-setting-mode") != "enabled":
            raise TVError("Network control is restricted. Enable Control by mobile apps on the TV before sending commands.", 403)
        return identity

    def airplay_receiver(self):
        identity = self.xml("query-device-info", "device-info")
        if identity.findtext("serial-number") != SERIAL:
            raise TVError("The Roku identity no longer matches your selected TV. No AirPlay receiver was selected.", 409)
        try:
            with self.http.open(f"http://{self.ip}:7000/info", timeout=3) as response:
                raw = response.read(65537)
            if len(raw) > 65536:
                raise ValueError("AirPlay metadata exceeds the 64 KiB local metadata budget")
            receiver = plistlib.loads(raw)
            if not isinstance(receiver, dict):
                raise ValueError("Unexpected AirPlay metadata")
            name, device_id = receiver.get("name"), receiver.get("deviceID")
            if not isinstance(name, str) or not name or not isinstance(device_id, str) or not device_id:
                raise ValueError("AirPlay receiver name or device ID is unknown")
            if receiver.get("manufacturer") != identity.findtext("vendor-name") or receiver.get("model") != identity.findtext("model-number"):
                raise ValueError("AirPlay metadata does not match the verified Roku manufacturer/model")
            return {"name": name, "device_id": device_id, "model": receiver["model"], "ip": self.ip}
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            raise TVError(f"Cannot identify the TCL AirPlay receiver: {error}. No guessed receiver will be selected.", 503) from error

    def apps(self):
        root = self.xml("query-apps", "apps")
        return [{"id": item.get("id"), "name": item.text or item.get("id"), "type": item.get("type")} for item in root.findall("app") if item.get("id")]

    def launch_app(self, app_id):
        app = next((item for item in self.apps() if item["id"] == app_id), None)
        if app is None:
            raise TVError("Select an installed app or input.", 400)
        self.command("launch/" + urllib.parse.quote(app_id, safe=""))
        deadline = time.monotonic() + 8
        while True:
            active = self.xml("query-active-app", "active-app").find("app")
            if active is not None and active.get("id") == app_id:
                return {"accepted": True, "verified": True, "message": f"Verified active on TV: {app['name']}."}
            if time.monotonic() >= deadline:
                return {"accepted": True, "verified": False, "message": f"Launch of {app['name']} was accepted, but the active app was not confirmed within 8 seconds. Refresh to check; no launch was repeated."}
            time.sleep(0.25)

    def set_power(self, on):
        desired = "PowerOn" if on else "DisplayOff"
        self.wait_power_settle()
        identity = self.require_control()
        current = identity.findtext("power-mode")
        if current != desired:
            self.power_settle_until = time.monotonic() + POWER_SETTLE_SECONDS
            if on:
                self.request("key-press", **{"param-key": "PowerOn"})
            else:
                self.http_post("keypress/PowerOff")
        deadline = time.monotonic() + 8
        while True:
            observed = self.xml("query-device-info", "device-info").findtext("power-mode")
            if observed == desired:
                return {"verified": True, "power": observed, "message": f"Verified TV screen state: {observed}."}
            if time.monotonic() >= deadline:
                raise TVError(f"Power command was accepted, but screen state is {observed or 'unknown'}, not {desired}. No second power command was sent.", 409)
            time.sleep(0.25)

    def picture(self):
        settings = self.xml("query-pq-picture-settings", "pq-picture-settings")
        modes = self.xml("query-pq-picture-modes", "pq-picture-modes")
        options = self.xml("query-pq-options", "pq-options")
        input_mode, mode = settings.get("input_mode"), settings.get("picture_mode")
        if not input_mode or not mode or modes.get("input_mode") != input_mode:
            raise TVError("Picture context changed or is unknown. Refresh before adjusting.", 409)
        return {
            "input": input_mode, "mode": mode, "default": settings.get("default"),
            "settings": {item.get("name"): item.get("value") for item in settings.findall("setting") if item.get("name")},
            "modes": [item.get("value") for item in modes.findall("setting[@name='picture_mode']/option") if item.get("value")],
            "options": {item.get("name"): [option.get("value") for option in item.findall("option") if option.get("value") is not None] for item in options.findall("setting") if item.get("name")},
        }

    def state(self):
        identity = self.xml("query-device-info", "device-info")
        if identity.findtext("serial-number") != SERIAL:
            self.close()
            raise TVError("TV identity changed. Controls are blocked.", 409)
        active = self.xml("query-active-app", "active-app").find("app")
        audio = self.xml("query-audio-device", "audio-device").find("global")
        try:
            picture = {"available": True, **self.picture()}
        except TVError as error:
            if error.status not in {400, 403, 404, 409}:
                raise
            picture = {"available": False, "error": str(error)}
        return {
            "name": identity.findtext("friendly-device-name"), "model": identity.findtext("model-name"),
            "software": identity.findtext("software-version"), "ip": self.ip,
            "power": identity.findtext("power-mode"), "control": identity.findtext("ecp-setting-mode"),
            "app": {"id": active.get("id"), "name": active.text, "type": active.get("type")} if active is not None else None,
            "audio": {"volume": audio.findtext("volume"), "muted": audio.findtext("muted")} if audio is not None else None,
            "picture": picture, "apps": self.apps(), "observed_at": time.time(),
        }

    def set_picture(self, payload):
        if set(payload) != {"input", "mode", "name", "value"}:
            raise TVError("Provide picture input, mode, name and value.", 400)
        for key in payload:
            required_text(payload[key], key)
        self.require_control()
        before = self.picture()
        if (before["input"], before["mode"]) != (payload["input"], payload["mode"]):
            raise TVError("The TV input or picture mode changed. Refresh; no setting was written.", 409)
        name, value = payload["name"], payload["value"]
        if name == "picture_mode":
            if value not in before["modes"]:
                raise TVError("That picture mode is not offered for the current signal.", 400)
            operation = "set-pq-picture-mode"
            root = ET.Element(operation, {"input_mode": before["input"]})
        else:
            if name not in PICTURE_FIELDS or name not in before["settings"] or value not in before["options"].get(name, []):
                raise TVError("This picture setting/value is not exposed by your TV.", 400)
            operation = "set-pq-picture-settings"
            root = ET.Element(operation, {"input_mode": before["input"], "picture_mode": before["mode"]})
        ET.SubElement(root, "setting", {"name": name, "value": value})
        self.request(operation, **{"content-type": "text/xml", "param-settings": ET.tostring(root, encoding="unicode")})
        after = self.picture()
        actual = after["mode"] if name == "picture_mode" else after["settings"].get(name)
        expected_mode = value if name == "picture_mode" else before["mode"]
        if after["input"] != before["input"] or after["mode"] != expected_mode or actual != value:
            raise TVError("The TV accepted the request but readback did not confirm the requested value and context. Check the TV; no retry was sent.", 409)
        return {"verified": True, "name": name, "value": actual, "picture": {"available": True, **after}, "message": f"Verified on TV: {name} = {actual} · {after['input']} / {after['mode']}"}


class LocalServer(ThreadingHTTPServer):
    def __init__(self, address, handler):
        super().__init__(address, handler)
        self.connections = threading.BoundedSemaphore(16)

    def process_request(self, request, client_address):
        if not self.connections.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.connections.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connections.release()

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(10)
        return connection, address


def main():
    parser = argparse.ArgumentParser(description="CouchKeys web remote with authenticated Roku ECP2 controls and readback.")
    parser.add_argument("--tv", default="10.0.0.128", type=ipaddress.IPv4Address)
    parser.add_argument("--broadcast", default="10.0.0.255", type=ipaddress.IPv4Address)
    parser.add_argument("--port", default=8765, type=int)
    parser.add_argument("--open", action="store_true")
    args = parser.parse_args()
    roku = Roku(args.tv)
    token = secrets.token_urlsafe(32)
    authorities = {f"127.0.0.1:{args.port}", f"localhost:{args.port}"}
    action_lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def send(self, code, value, html=False):
            body = value.encode() if html else json.dumps(value).encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8" if html else "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            with action_lock:
                self.handle_get()

        def handle_get(self):
            if self.headers.get("Host") not in authorities:
                return self.send(403, {"error": "Localhost access only."})
            if self.path == "/api/health":
                return self.send(200, {"app": "couchkeys", "serial": SERIAL, "ip": str(args.tv)})
            if self.path == "/":
                page = Path(__file__).with_name("index.html").read_text().replace("__SESSION_TOKEN__", token)
                return self.send(200, page, html=True)
            if self.path == "/api/browser-state":
                return self.send(200, browser_state(roku))
            if self.path != "/api/state":
                return self.send(404, {"error": "Not found."})
            try:
                self.send(200, roku.state())
            except TVError as error:
                self.send(error.status, {"error": str(error)})

        def do_POST(self):
            with action_lock:
                self.handle_post()

        def handle_post(self):
            self.close_connection = True
            if (self.headers.get("Host") not in authorities
                or self.headers.get("Origin") not in {None, *(f"http://{host}" for host in authorities)}
                or not hmac.compare_digest(self.headers.get("X-Remote-Token", "").encode(), token.encode())):
                return self.send(403, {"error": "Open the remote locally and refresh the page."})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 65536 or self.headers.get("Transfer-Encoding"):
                    raise ValueError("Invalid request size (local request-body budget: 64 KiB).")
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict):
                    raise ValueError("Expected a JSON object.")
                if self.path == "/api/browser/open":
                    result = open_mac_browser(payload, roku)
                elif self.path == "/api/browser/mirroring":
                    if payload:
                        raise ValueError("The mirroring picker does not accept parameters.")
                    result = {"picker_opened": True, "message": open_mirroring_picker()}
                elif self.path == "/api/picture":
                    result = roku.set_picture(payload)
                elif self.path == "/api/key":
                    if set(payload) != {"key"} or not isinstance(payload["key"], str) or payload["key"] not in KEYS:
                        raise ValueError("Unsupported remote button.")
                    roku.command("keypress/" + payload["key"])
                    result = {"message": f"TV accepted {payload['key']}.", "accepted": True}
                elif self.path == "/api/launch":
                    if set(payload) != {"id"} or not isinstance(payload["id"], str):
                        raise ValueError("Select an installed app or input.")
                    result = roku.launch_app(payload["id"])
                elif self.path == "/api/power":
                    if set(payload) != {"on"} or not isinstance(payload["on"], bool):
                        raise ValueError("Provide an explicit boolean power state.")
                    result = roku.set_power(payload["on"])
                elif self.path == "/api/wake":
                    if payload:
                        raise ValueError("Wake does not accept parameters.")
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
                        sender.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                        sender.sendto(b"\xff" * 6 + WIFI_MAC * 16, (str(args.broadcast), 9))
                    roku.close()
                    result = {"message": "Wake packet sent to your TCL. Power-on is not yet confirmed; wait a few seconds, then Refresh.", "accepted": True}
                else:
                    return self.send(404, {"error": "Not found."})
                self.send(200, result)
            except (ValueError, UnicodeDecodeError) as error:
                self.send(400, {"error": str(error)})
            except TVError as error:
                self.send(error.status, {"error": str(error)})
            except OSError as error:
                self.send(502, {"error": f"Network operation failed: {error}. No automatic retry was sent."})

        def log_message(self, format, *values):
            print(format % values, flush=True)

    try:
        with LocalServer(("127.0.0.1", args.port), Handler) as server:
            url = f"http://127.0.0.1:{args.port}"
            print(f"CouchKeys ready: {url} (TV {args.tv})", flush=True)
            if args.open:
                webbrowser.open(url)
            server.serve_forever()
    except OSError as error:
        if error.errno != errno.EADDRINUSE or not args.open:
            raise
        url = f"http://127.0.0.1:{args.port}"
        http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with http.open(url + "/api/health", timeout=2) as response:
                existing = json.load(response)
            if existing != {"app": "couchkeys", "serial": SERIAL, "ip": str(args.tv)}:
                raise ValueError("Another application or target is using the remote's port.")
        except (OSError, ValueError) as conflict:
            raise SystemExit(f"Cannot reuse {url}: {conflict}") from conflict
        webbrowser.open(url)
        print(f"Opened the existing CouchKeys web remote: {url}", flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        roku.close()


if __name__ == "__main__":
    main()
