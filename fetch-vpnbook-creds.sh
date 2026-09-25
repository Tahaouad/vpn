#!/usr/bin/env bash
#
# fetch-vpnbook-creds.sh — best-effort scraper for the current VPNBook
# OpenVPN username/password, published (client-side rendered, no login) at
# https://www.vpnbook.com/freevpn/openvpn. VPNBook rotates this password
# every 1-2 weeks, which is what usually breaks vpn-fr.sh with AUTH_FAILED.
#
# This is fragile by nature: it renders the page with headless Chrome and
# scrapes plain text, so it breaks if VPNBook reshapes that page. It never
# touches the existing auth file unless it gets two clean, plausible values.
#
# Usage:
#   ./fetch-vpnbook-creds.sh                # write to ./vpnbook.auth
#   ./fetch-vpnbook-creds.sh /path/to/file  # write to a specific auth file
#   ./fetch-vpnbook-creds.sh --print        # just print "user\npass", don't write
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_URL="https://www.vpnbook.com/freevpn/openvpn"
RENDER_TIMEOUT=30   # seconds allowed for headless Chrome to load+render the page

c_reset=$'\e[0m'; c_info=$'\e[36m'; c_ok=$'\e[32m'; c_err=$'\e[31m'
say()  { printf '%s[*]%s %s\n' "$c_info" "$c_reset" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "$c_ok"   "$c_reset" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_err"  "$c_reset" "$*" >&2; exit 1; }

print_only=0
auth_file="$SCRIPT_DIR/vpnbook.auth"
for a in "$@"; do
    case "$a" in
        --print) print_only=1 ;;
        *) auth_file="$a" ;;
    esac
done

chrome=""
for cand in google-chrome google-chrome-stable chromium chromium-browser; do
    if command -v "$cand" >/dev/null 2>&1; then chrome="$cand"; break; fi
done
[ -n "$chrome" ] || die "No headless-capable Chrome/Chromium found (looked for google-chrome, chromium)."

profile_dir="$(mktemp -d)"
dom_file="$(mktemp)"
trap 'rm -rf "$profile_dir" "$dom_file"' EXIT

say "Rendering $CREDS_URL with headless $chrome..."
if ! timeout "$RENDER_TIMEOUT" "$chrome" \
        --headless=new --disable-gpu --no-sandbox --disable-dev-shm-usage \
        --user-data-dir="$profile_dir" --virtual-time-budget=8000 \
        --dump-dom "$CREDS_URL" > "$dom_file" 2>/dev/null; then
    die "Headless render failed or timed out after ${RENDER_TIMEOUT}s."
fi
[ -s "$dom_file" ] || die "Headless render produced no output."

# Pull the text nodes right after the "Username" / "Password" labels. The
# page shows: Username <value> Copy   Password <value> Copy
parsed="$(python3 - "$dom_file" <<'PYEOF'
import re, sys
html = open(sys.argv[1], encoding="utf-8", errors="replace").read()
text = re.sub(r"<[^>]+>", "\n", html)
lines = [l.strip() for l in text.split("\n") if l.strip()]

def value_after(label):
    for i, l in enumerate(lines):
        if l == label:
            for cand in lines[i + 1:i + 4]:
                if cand and cand != "Copy":
                    return cand
    return None

user = value_after("Username")
pwd = value_after("Password")
if user and pwd:
    print(user)
    print(pwd)
PYEOF
)"

[ -n "$parsed" ] || die "Could not find Username/Password on the rendered page — VPNBook may have changed the page layout. Check manually: $CREDS_URL"

user="$(printf '%s\n' "$parsed" | sed -n 1p)"
pass="$(printf '%s\n' "$parsed" | sed -n 2p)"

# Sanity checks: single token, no whitespace, plausible length, not the labels themselves.
for v in "$user" "$pass"; do
    case "$v" in
        *[[:space:]]*) die "Parsed value contains whitespace ('$v') — page layout probably changed, refusing to use it." ;;
    esac
    [ "${#v}" -ge 3 ] && [ "${#v}" -le 64 ] || die "Parsed value '$v' has an implausible length — refusing to use it."
done
case "$user" in Username|Password|Copy) die "Parsed username is a label ('$user'), not a value — parsing broke." ;; esac
case "$pass" in Username|Password|Copy) die "Parsed password is a label ('$pass'), not a value — parsing broke." ;; esac

if [ "$print_only" -eq 1 ]; then
    printf '%s\n%s\n' "$user" "$pass"
    exit 0
fi

if [ -f "$auth_file" ] && [ "$(sed -n '1p' "$auth_file" 2>/dev/null)" = "$user" ] \
   && [ "$(sed -n '2p' "$auth_file" 2>/dev/null)" = "$pass" ]; then
    say "Fetched credentials are identical to $auth_file — nothing to update."
    exit 0
fi

tmp="$(mktemp "$(dirname "$auth_file")/.vpnbook.auth.XXXXXX")"
printf '%s\n%s\n' "$user" "$pass" > "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$auth_file"
ok "Wrote refreshed credentials to $auth_file (user: $user)."
