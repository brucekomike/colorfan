#!/usr/bin/env bash
# install colorfan as root: proxy.sh apt-get install <pkgs>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root (sudo ./install.sh)"; exit 1; }

# 1. dependencies: acpi_call gives /proc/acpi/call, acpica-tools gives iasl for the DSDT check
dpkg -l acpi-call-dkms 2>/dev/null | grep -q '^ii' || apt-get install -y acpi-call-dkms dkms
dpkg -l acpica-tools   2>/dev/null | grep -q '^ii' || apt-get install -y acpica-tools
dpkg -l lm-sensors     2>/dev/null | grep -q '^ii' || apt-get install -y lm-sensors jq

# 2. load the module now and at every boot
modprobe acpi_call
echo acpi_call > /etc/modules-load.d/colorfan.conf
[ -w /proc/acpi/call ] || { echo "acpi_call loaded but /proc/acpi/call missing - check: dkms status"; exit 1; }

# 3. install files
install -m 0755 "$HERE/colorfan" /usr/local/bin/colorfan
[ -f /etc/colorfan.conf ] || install -m 0644 "$HERE/colorfan.conf" /etc/colorfan.conf
install -m 0644 "$HERE/colorfan.service" /etc/systemd/system/colorfan.service
systemctl daemon-reload

echo
echo "next: verify the EC answers, then start the daemon"
echo "  colorfan probe      # must print an ACPI buffer, not an error"
echo "  colorfan status     # RPM + current duty readback"
echo "  sudo systemctl enable --now colorfan"
