#!/usr/bin/python3
"""System tray GUI for vpn-fr.sh — start / stop / restart / status / test.

Wraps the existing shell script; all VPN logic (benchmarking, France check,
failover) stays in vpn-fr.sh. This just gives it buttons and a status icon.

Run directly: /usr/bin/python3 gui/vpn_tray.py
(uses the system python3, not any active venv — that's where the gi bindings live)
"""
import os
import re
import subprocess
import threading
import time

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Notify", "0.7")
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator3
except (ValueError, ImportError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3

from gi.repository import GLib, Gtk, Notify

GUI_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(GUI_DIR)
VPN_SCRIPT = os.path.join(REPO_DIR, "vpn-fr.sh")
FETCH_CREDS_SCRIPT = os.path.join(REPO_DIR, "fetch-vpnbook-creds.sh")
AUTH_FILE = os.path.join(REPO_DIR, "vpnbook.auth")
CREDS_URL = "https://www.vpnbook.com/freevpn/openvpn"
RUN_DIR = os.path.join(REPO_DIR, ".run")
LOG_FILE = os.path.join(RUN_DIR, "openvpn.log")
GUI_LOG_FILE = os.path.join(RUN_DIR, "gui.log")

POLL_SECONDS = 10
CONNECTING_TIMEOUT = 180  # worst case: a full re-benchmark of every config

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

ICON_UP = "network-vpn-symbolic"
ICON_BAD_COUNTRY = "network-vpn-no-route-symbolic"
ICON_DOWN = "network-vpn-disabled-symbolic"
ICON_AUTH_ERROR = "dialog-password-symbolic"
ICON_BUSY = "network-vpn-acquiring-symbolic"


def log_has_auth_failed():
    """vpn-fr.sh already tries to auto-fetch fresh credentials once when it
    sees AUTH_FAILED (see maybe_refresh_creds in vpn-fr.sh); if the VPN is
    still down and the log still says AUTH_FAILED, that attempt didn't work
    and a human needs to supply the password."""
    try:
        with open(LOG_FILE, errors="replace") as f:
            return "AUTH_FAILED" in f.read()
    except OSError:
        return False


def strip_ansi(text):
    return ANSI_RE.sub("", text)


def run_script(args, timeout=30):
    """Run vpn-fr.sh synchronously, return (returncode, combined_output)."""
    try:
        proc = subprocess.run(
            [VPN_SCRIPT, *args],
            cwd=REPO_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, strip_ansi(proc.stdout)
    except subprocess.TimeoutExpired as e:
        return 124, strip_ansi(e.stdout or "") + "\n[gui] timed out"
    except FileNotFoundError:
        return 127, f"[gui] {VPN_SCRIPT} not found"


def spawn_detached(args):
    """Launch vpn-fr.sh in the background, independent of this GUI's lifetime."""
    os.makedirs(RUN_DIR, exist_ok=True)
    with open(GUI_LOG_FILE, "a") as log:
        subprocess.Popen(
            [VPN_SCRIPT, *args],
            cwd=REPO_DIR,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )


def parse_status(output):
    """Parse `vpn-fr.sh status` output into a small state dict."""
    up = "VPN is UP via" in output
    label_m = re.search(r"VPN is UP via (.+)", output)
    ip_m = re.search(r"Exit IP (\S+) . (FR)\b", output)
    bad_m = re.search(r"Exit IP (\S+) . country '([^']*)'", output)

    if up and ip_m:
        return {"state": "up", "label": label_m.group(1).strip(), "ip": ip_m.group(1), "country": ip_m.group(2)}
    if up and bad_m:
        return {"state": "up_bad_country", "label": label_m.group(1).strip() if label_m else "?",
                "ip": bad_m.group(1), "country": bad_m.group(2) or "unknown"}
    if up:
        return {"state": "up", "label": label_m.group(1).strip() if label_m else "?", "ip": "?", "country": "?"}
    return {"state": "down"}


class VpnTray:
    def __init__(self):
        Notify.init("vpn-fr")
        self.busy = False
        self.connecting_until = 0.0
        self.last_state = None
        self.auth_error_prompted = False

        self.indicator = AppIndicator3.Indicator.new(
            "vpn-fr", ICON_DOWN, AppIndicator3.IndicatorCategory.APPLICATION_STATUS
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)

        self.menu = Gtk.Menu()

        self.status_item = Gtk.MenuItem(label="Checking status...")
        self.status_item.set_sensitive(False)
        self.menu.append(self.status_item)
        self.menu.append(Gtk.SeparatorMenuItem())

        self.start_item = Gtk.MenuItem(label="Start")
        self.start_item.connect("activate", self.on_start)
        self.menu.append(self.start_item)

        self.stop_item = Gtk.MenuItem(label="Stop")
        self.stop_item.connect("activate", self.on_stop)
        self.menu.append(self.stop_item)

        self.restart_item = Gtk.MenuItem(label="Restart")
        self.restart_item.connect("activate", self.on_restart)
        self.menu.append(self.restart_item)

        self.test_item = Gtk.MenuItem(label="Test (benchmark servers)")
        self.test_item.connect("activate", self.on_test)
        self.menu.append(self.test_item)

        self.menu.append(Gtk.SeparatorMenuItem())

        creds_item = Gtk.MenuItem(label="Update credentials...")
        creds_item.connect("activate", self.on_update_creds)
        self.menu.append(creds_item)

        self.menu.append(Gtk.SeparatorMenuItem())

        logs_item = Gtk.MenuItem(label="View logs")
        logs_item.connect("activate", self.on_view_logs)
        self.menu.append(logs_item)

        self.menu.append(Gtk.SeparatorMenuItem())

        quit_item = Gtk.MenuItem(label="Quit (leaves the VPN running)")
        quit_item.connect("activate", self.on_quit)
        self.menu.append(quit_item)

        self.menu.show_all()
        self.indicator.set_menu(self.menu)

        self.refresh_status()
        GLib.timeout_add_seconds(POLL_SECONDS, self._poll_tick)

    # --- busy / action helpers ------------------------------------------------

    def _set_busy(self, busy, label=None):
        self.busy = busy
        for item in (self.start_item, self.stop_item, self.restart_item, self.test_item):
            item.set_sensitive(not busy)
        if busy:
            self.indicator.set_icon_full(ICON_BUSY, "vpn-fr: working")
            self.status_item.set_label(label or "Working...")

    def run_action_async(self, args, timeout=30, detach=False, on_done=None, busy_label=None):
        if self.busy:
            return
        self._set_busy(True, busy_label)

        def worker():
            if detach:
                spawn_detached(args)
                self.connecting_until = time.time() + CONNECTING_TIMEOUT
                rc, out = 0, ""
            else:
                rc, out = run_script(args, timeout=timeout)
            GLib.idle_add(self._action_done, rc, out, on_done)

        threading.Thread(target=worker, daemon=True).start()

    def _action_done(self, rc, out, on_done):
        self._set_busy(False)
        if on_done:
            on_done(rc, out)
        self.refresh_status()
        return False

    # --- menu actions ----------------------------------------------------------

    def on_start(self, _item):
        self.run_action_async(["start"], detach=True, busy_label="Connecting...")

    def on_stop(self, _item):
        def done(rc, out):
            if rc != 0:
                self._notify("vpn-fr", "Stop failed — see logs")
        self.run_action_async(["stop"], timeout=30, on_done=done, busy_label="Stopping...")

    def on_restart(self, _item):
        self.run_action_async(["restart"], detach=True, busy_label="Restarting...")

    def on_test(self, _item):
        def done(rc, out):
            self._show_text_dialog("Benchmark results", out or "(no output)")
        self.run_action_async(["test"], timeout=600, on_done=done, busy_label="Benchmarking...")

    def on_update_creds(self, _item):
        self._show_creds_dialog()

    def on_view_logs(self, _item):
        text = "(no log file yet — start the VPN at least once)"
        if os.path.exists(LOG_FILE):
            try:
                with open(LOG_FILE, errors="replace") as f:
                    lines = f.readlines()
                text = "".join(lines[-200:])
            except OSError as e:
                text = f"Could not read {LOG_FILE}: {e}"
        self._show_text_dialog("openvpn.log (last 200 lines)", text)

    def on_quit(self, _item):
        Gtk.main_quit()

    # --- status polling ----------------------------------------------------------

    def _poll_tick(self):
        self.refresh_status()
        return True

    def refresh_status(self):
        if self.busy:
            return

        def worker():
            rc, out = run_script(["status"], timeout=20)
            state = parse_status(out)
            GLib.idle_add(self._apply_status, state)

        threading.Thread(target=worker, daemon=True).start()

    def _apply_status(self, state):
        connecting = time.time() < self.connecting_until
        if state["state"] == "up":
            connecting = False

        auth_failed = not connecting and state["state"] == "down" and log_has_auth_failed()
        if state["state"] == "up":
            self.auth_error_prompted = False

        if connecting:
            icon, label = ICON_BUSY, "Connecting..."
        elif state["state"] == "up":
            icon = ICON_UP
            label = f"Connected — {state['label']} — {state['ip']} ({state['country']})"
        elif state["state"] == "up_bad_country":
            icon = ICON_BAD_COUNTRY
            label = f"Wrong exit country: {state['country']} (expected FR)"
        elif auth_failed:
            icon, label = ICON_AUTH_ERROR, "VPNBook login rejected — credentials expired"
        else:
            icon, label = ICON_DOWN, "Disconnected"

        self.indicator.set_icon_full(icon, f"vpn-fr: {label}")
        self.status_item.set_label(label)

        key = (connecting, state["state"], auth_failed)
        if self.last_state is not None and self.last_state != key:
            if key == (False, "up", False):
                self._notify("VPN connected", label)
            elif auth_failed and not self.last_state[2]:
                self._notify("VPN needs new credentials", "vpn-fr.sh's own auto-fetch didn't work — opening the update dialog.")
            elif state["state"] == "down" and self.last_state[1] == "up":
                self._notify("VPN disconnected", "Failover monitor will retry automatically.")
            elif state["state"] == "up_bad_country":
                self._notify("VPN warning", label)
        self.last_state = key

        if auth_failed and not self.auth_error_prompted:
            self.auth_error_prompted = True
            self._show_creds_dialog()
        return False

    # --- small UI helpers ----------------------------------------------------------

    def _notify(self, title, body):
        try:
            Notify.Notification.new(title, body, "network-vpn-symbolic").show()
        except GLib.Error:
            pass

    def _show_creds_dialog(self):
        """Prompt for fresh VPNBook credentials: a link to the page that shows
        them, entry fields to type them in, and a button that tries the same
        auto-fetch vpn-fr.sh itself uses, in case that's all that's needed."""
        dialog = Gtk.Dialog(title="Update VPNBook credentials")
        dialog.set_default_size(420, -1)
        box = dialog.get_content_area()
        box.set_spacing(8)
        box.set_border_width(12)

        info = Gtk.Label(
            label="VPNBook changes its free password every 1-2 weeks, which is why the "
                  "VPN stopped connecting. Open the link below to see the current "
                  "username/password, type them in, then Save & Restart."
        )
        info.set_line_wrap(True)
        info.set_xalign(0)
        box.pack_start(info, False, False, 0)

        link = Gtk.LinkButton.new_with_label(CREDS_URL, "Open vpnbook.com/freevpn/openvpn")
        box.pack_start(link, False, False, 0)

        grid = Gtk.Grid(column_spacing=8, row_spacing=6)
        grid.attach(Gtk.Label(label="Username:", xalign=0), 0, 0, 1, 1)
        user_entry = Gtk.Entry()
        grid.attach(user_entry, 1, 0, 1, 1)
        grid.attach(Gtk.Label(label="Password:", xalign=0), 0, 1, 1, 1)
        pass_entry = Gtk.Entry()
        pass_entry.set_visibility(False)
        grid.attach(pass_entry, 1, 1, 1, 1)
        show_pw = Gtk.CheckButton(label="Show password")
        show_pw.connect("toggled", lambda b: pass_entry.set_visibility(b.get_active()))
        grid.attach(show_pw, 1, 2, 1, 1)
        box.pack_start(grid, False, False, 0)

        try:
            with open(AUTH_FILE, errors="replace") as f:
                lines = [l.strip() for l in f.readlines()]
            if lines and lines[0]:
                user_entry.set_text(lines[0])
            if len(lines) > 1 and lines[1]:
                pass_entry.set_text(lines[1])
        except OSError:
            pass

        status_label = Gtk.Label(label="")
        status_label.set_xalign(0)
        status_label.set_line_wrap(True)
        box.pack_start(status_label, False, False, 0)

        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        auto_button = dialog.add_button("Try auto-fetch", Gtk.ResponseType.APPLY)
        dialog.add_button("Save & Restart", Gtk.ResponseType.OK)
        dialog.show_all()

        def apply_fetch_result(ok, lines):
            auto_button.set_sensitive(True)
            if ok:
                user_entry.set_text(lines[0])
                pass_entry.set_text(lines[1])
                status_label.set_text("Fetched — check the values, then Save & Restart.")
            else:
                status_label.set_text(
                    "Auto-fetch failed (Chrome missing, or VPNBook changed their page) — "
                    "use the link above and type the credentials in by hand."
                )
            return False

        def do_auto_fetch():
            status_label.set_text("Fetching current credentials from vpnbook.com...")
            auto_button.set_sensitive(False)

            def worker():
                try:
                    proc = subprocess.run(
                        [FETCH_CREDS_SCRIPT, "--print"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=40,
                    )
                    lines = [l for l in proc.stdout.splitlines() if l.strip()]
                    ok = proc.returncode == 0 and len(lines) >= 2
                except (subprocess.TimeoutExpired, OSError):
                    ok, lines = False, []
                GLib.idle_add(apply_fetch_result, ok, lines)

            threading.Thread(target=worker, daemon=True).start()

        response = Gtk.ResponseType.CANCEL
        while True:
            response = dialog.run()
            if response == Gtk.ResponseType.APPLY:
                do_auto_fetch()
                continue
            break

        user = user_entry.get_text().strip()
        pwd = pass_entry.get_text().strip()
        dialog.destroy()

        if response != Gtk.ResponseType.OK:
            return
        if not user or not pwd:
            self._notify("vpn-fr", "Username or password left empty — not saved.")
            return
        self._save_creds_and_restart(user, pwd)

    def _save_creds_and_restart(self, user, pwd):
        try:
            tmp_path = AUTH_FILE + ".tmp"
            with open(tmp_path, "w") as f:
                f.write(f"{user}\n{pwd}\n")
            os.chmod(tmp_path, 0o600)
            os.replace(tmp_path, AUTH_FILE)
        except OSError as e:
            self._notify("vpn-fr", f"Could not write {AUTH_FILE}: {e}")
            return
        self._notify("vpn-fr", "Credentials saved — restarting VPN...")
        self.on_restart(None)

    def _show_text_dialog(self, title, text):
        dialog = Gtk.Dialog(title=title)
        dialog.set_default_size(640, 420)
        scrolled = Gtk.ScrolledWindow()
        view = Gtk.TextView()
        view.set_editable(False)
        view.set_monospace(True)
        view.get_buffer().set_text(text)
        scrolled.add(view)
        dialog.get_content_area().pack_start(scrolled, True, True, 0)
        dialog.add_button("Close", Gtk.ResponseType.CLOSE)
        dialog.show_all()
        dialog.run()
        dialog.destroy()


def main():
    if not os.path.exists(VPN_SCRIPT):
        raise SystemExit(f"vpn-fr.sh not found at {VPN_SCRIPT}")
    VpnTray()
    Gtk.main()


if __name__ == "__main__":
    main()
