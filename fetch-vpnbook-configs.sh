#!/usr/bin/env bash
#
# fetch-vpnbook-configs.sh — download VPNBook's France OpenVPN config files
# straight from their config-generator API (no scraping needed for this part,
# unlike fetch-vpnbook-creds.sh — the download button on
# https://www.vpnbook.com/freevpn/openvpn just calls this endpoint client-side).
#
# Usage:
#   ./fetch-vpnbook-configs.sh                # write *.ovpn into this script's dir
#   ./fetch-vpnbook-configs.sh /path/to/dir   # write into a specific directory
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_URL="https://www.vpnbook.com/api/openvpn"
out_dir="${1:-$SCRIPT_DIR}"

# "France Server 1" / "France Server 2" on the page, as of writing.
SERVERS=(fr200.vpnbook.com fr2311.vpnbook.com)
PROTOCOLS=(tcp443 tcp80 udp53 udp25000)

c_reset=$'\e[0m'; c_info=$'\e[36m'; c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'
say()  { printf '%s[*]%s %s\n' "$c_info" "$c_reset" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "$c_ok"   "$c_reset" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$c_warn" "$c_reset" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_err"  "$c_reset" "$*" >&2; exit 1; }

mkdir -p "$out_dir"

fetched=0
for host in "${SERVERS[@]}"; do
    short="${host%%.*}"
    for proto in "${PROTOCOLS[@]}"; do
        name="vpnbook-${short}-${proto}.ovpn"
        say "Fetching $name..."
        tmp="$(mktemp "$out_dir/.${name}.XXXXXX")"
        if ! curl -sf --max-time 15 -A "Mozilla/5.0" \
                "${API_URL}?hostname=${host}&protocol=${proto}" -o "$tmp"; then
            warn "Failed to fetch $name — skipping."
            rm -f "$tmp"
            continue
        fi
        # Sanity check: this should be an OpenVPN client config, not an error page.
        if ! grep -q '^client$' "$tmp" || ! grep -q 'BEGIN CERTIFICATE' "$tmp"; then
            warn "$name didn't look like a valid OpenVPN config — skipping."
            rm -f "$tmp"
            continue
        fi
        mv -f "$tmp" "$out_dir/$name"
        ok "Wrote $out_dir/$name"
        fetched=$((fetched + 1))
    done
done

[ "$fetched" -gt 0 ] || die "Could not fetch any config — VPNBook may have changed their API. Download manually: https://www.vpnbook.com/freevpn/openvpn"
ok "Fetched $fetched config(s)."
