# vpn-fr

French VPNBook connection with auto-failover.

`vpn-fr.sh` connects to one of the `vpnbook-fr*.ovpn` configs in this folder,
checks the exit IP is really in France, keeps the fastest server, and switches
to another one automatically if the tunnel drops.

The France check uses `https://1.1.1.1/cdn-cgi/trace` (the `loc=` field). It's a
fixed anycast IP, so it works even though the VPN doesn't configure a DNS
resolver — `curl https://ipinfo.io/country` would need name resolution and can
hang once all traffic is redirected into the tunnel.

## Requirements

- `bash`, `curl`, and `openvpn` (Debian/Ubuntu: `sudo apt install openvpn curl`)
- `sudo` rights — bringing up a tunnel needs root

## Setup

1. Get the current VPNBook free credentials: <https://www.vpnbook.com/freevpn>
   (they rotate the password regularly).
2. Create the auth file:

   ```bash
   cp vpnbook.auth.example vpnbook.auth
   $EDITOR vpnbook.auth      # line 1: username, line 2: password
   chmod 600 vpnbook.auth
   ```

VPNBook rotates this password every 1-2 weeks; when it does, `openvpn.log`
shows `AUTH_FAILED`. `vpn-fr.sh` tries to recover on its own (see below), but
you can also refresh it by hand:

```bash
./fetch-vpnbook-creds.sh          # scrapes vpnbook.com and updates vpnbook.auth
./fetch-vpnbook-creds.sh --print  # just print what it found, don't write
```

It's a best-effort headless-Chrome scraper (needs `google-chrome` or
`chromium`) and can break if VPNBook reshapes their page — it never touches
`vpnbook.auth` unless it got two plausible values back.

## Usage

```bash
./vpn-fr.sh            # benchmark all configs, connect to the best, then monitor
./vpn-fr.sh test       # just benchmark and print a latency table
./vpn-fr.sh status     # is the VPN up? what's the exit IP?
./vpn-fr.sh stop       # tear it down cleanly
./vpn-fr.sh restart
```

Flags for `start`:

| flag | effect |
|------|--------|
| `-f`, `--force-bench` | ignore the cached benchmark, re-test every config |
| `-q`, `--quick` | skip benchmarking, connect to the first working config |
| `-n`, `--no-monitor` | connect and exit, no failover monitoring |

Example run:

```
[*] Testing fr200 UDP 25000...
[+] Connected - FR - 85.10.x.x  (0.184s)
...
[+] VPN up via fr200 UDP 25000 — exit IP 85.10.x.x (FR)

[*] VPN active
[*] Monitoring connection...
[!] Connection lost
[*] Switching to fr200 TCP 443...
[+] Connected
```

`./vpn-fr.sh` keeps running in the foreground while it monitors. Stop it with
Ctrl-C, or `./vpn-fr.sh stop` from another terminal.

## Graphical interface (system tray)

`gui/vpn_tray.py` is an optional GTK system-tray app for `vpn-fr.sh`: a status
icon (connected / connecting / disconnected / wrong-country / credentials
expired) plus a right-click menu with Start, Stop, Restart, Test, Update
credentials..., and View logs. It just shells out to `vpn-fr.sh` — no VPN
logic lives in the GUI.

If `vpn-fr.sh`'s own auto-fetch (see Setup) can't recover from `AUTH_FAILED`,
the tray icon changes and a "Update VPNBook credentials" dialog pops up on
its own: a link to the page with the current username/password, entry fields
to type them in, a "Try auto-fetch" button (same scraper, one more shot), and
Save & Restart. It's also available any time from the menu.

1. Install the GTK/AppIndicator bindings (already present on stock
   Ubuntu/GNOME except the appindicator gir package):

   ```bash
   sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7
   ```

2. Allow the GUI to run `sudo openvpn` / `sudo kill` etc. without a password.
   This is required — the tray app has no terminal to prompt you in, and its
   auto-failover reconnects need to happen unattended:

   ```bash
   ./gui/install-sudoers.sh
   ```

   It prints the exact sudoers rule it's about to install (scoped to this
   repo's files and to the specific commands `vpn-fr.sh` runs — not blanket
   root access) and asks for confirmation before writing anything. To revoke
   later: `sudo rm /etc/sudoers.d/vpn-fr-$(whoami)`.

3. Launch it:

   ```bash
   /usr/bin/python3 gui/vpn_tray.py
   ```

   (use `/usr/bin/python3` explicitly if you have a virtualenv active — the
   GTK bindings live in the system Python, not in venvs.)

To start it automatically on login, copy the launcher into autostart:

```bash
cp gui/vpn-fr-tray.desktop ~/.config/autostart/
```

Quitting the tray app (via its menu) only closes the GUI — the VPN tunnel and
its failover monitor, if running, are a separate background process and keep
running.

## State / files

Runtime files live in `.run/`:

- `openvpn.pid`, `openvpn.log` — the running tunnel and its log
- `current.conf` — which config is active
- `bench.tsv` — cached benchmark, fastest first (refreshed every 24h or with `-f`)
- `monitor.pid`, `stop.flag` — used to coordinate `stop`

## Notes / limitations

- DNS is not pushed into the system resolver. Name resolution keeps using your
  normal resolver (a leak, and it can be flaky while the tunnel carries all
  traffic). That's why the health check talks to `1.1.1.1` by IP. For real
  browsing you may want to point your resolver at `1.1.1.1` while connected.
- The health check needs outbound HTTPS to `1.1.1.1`. If you're offline, the
  monitor will keep retrying.
- Only one tunnel is up at a time; starting again while one runs is refused
  (use `restart`).
