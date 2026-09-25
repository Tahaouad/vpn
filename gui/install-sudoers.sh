#!/usr/bin/env bash
#
# install-sudoers.sh — let the GUI (and vpn-fr.sh in general) start/stop the
# VPN without a password prompt.
#
# Why this is needed: vpn-fr.sh calls `sudo openvpn`, `sudo kill`, etc.
# internally so the tunnel can run as root. That's fine in a terminal (sudo
# can prompt you), but the tray app has no terminal, and its whole point is
# to reconnect automatically in the background — a password prompt would just
# hang forever. This installs a narrowly-scoped NOPASSWD sudoers rule that
# only covers the exact commands vpn-fr.sh runs, restricted to this repo's
# files where possible. It does NOT grant blanket root access.
#
# Review the generated file before confirming — it's printed first.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USERNAME="$(id -un)"
OPENVPN_BIN="$(command -v openvpn || echo /usr/sbin/openvpn)"
KILL_BIN="$(type -P kill || echo /usr/bin/kill)"  # kill is also a shell builtin; command -v would return "kill" with no path
PKILL_BIN="$(command -v pkill || echo /usr/bin/pkill)"
RM_BIN="$(command -v rm || echo /usr/bin/rm)"
CHMOD_BIN="$(command -v chmod || echo /usr/bin/chmod)"
GREP_BIN="$(command -v grep || echo /usr/bin/grep)"

SUDOERS_FILE="/etc/sudoers.d/vpn-fr-${USERNAME}"

cat > /tmp/vpn-fr.sudoers <<EOF
# Managed by ${SCRIPT_DIR}/gui/install-sudoers.sh — safe to delete to revoke.
# Lets ${USERNAME} run vpn-fr.sh (and its GUI) without a sudo password.
# Scoped to the exact commands the script issues, not blanket root access.

${USERNAME} ALL=(root) NOPASSWD: ${OPENVPN_BIN} --config ${SCRIPT_DIR}/*.ovpn --auth-user-pass ${SCRIPT_DIR}/vpnbook.auth --auth-nocache --daemon vpn-fr --writepid ${SCRIPT_DIR}/.run/openvpn.pid --log ${SCRIPT_DIR}/.run/openvpn.log --connect-timeout 20 --connect-retry-max 3 --ping 10 --ping-restart 30 --verb 3
${USERNAME} ALL=(root) NOPASSWD: ${KILL_BIN} -TERM *, ${KILL_BIN} -KILL *, ${KILL_BIN} -0 *
${USERNAME} ALL=(root) NOPASSWD: ${PKILL_BIN} -f openvpn*
${USERNAME} ALL=(root) NOPASSWD: ${RM_BIN} -f ${SCRIPT_DIR}/.run/*
${USERNAME} ALL=(root) NOPASSWD: ${CHMOD_BIN} 0644 ${SCRIPT_DIR}/.run/openvpn.log
${USERNAME} ALL=(root) NOPASSWD: ${GREP_BIN} -q * ${SCRIPT_DIR}/.run/openvpn.log, ${GREP_BIN} -iE * ${SCRIPT_DIR}/.run/openvpn.log
EOF

echo "About to install: $SUDOERS_FILE"
echo "---"
cat /tmp/vpn-fr.sudoers
echo "---"
read -r -p "Proceed? [y/N] " reply
[ "$reply" = "y" ] || [ "$reply" = "Y" ] || { echo "Aborted."; rm -f /tmp/vpn-fr.sudoers; exit 1; }

sudo visudo -c -f /tmp/vpn-fr.sudoers || { echo "Generated file is invalid, aborting."; rm -f /tmp/vpn-fr.sudoers; exit 1; }
sudo install -m 0440 -o root -g root /tmp/vpn-fr.sudoers "$SUDOERS_FILE"
rm -f /tmp/vpn-fr.sudoers

echo "Installed $SUDOERS_FILE"
echo "To revoke later: sudo rm $SUDOERS_FILE"
