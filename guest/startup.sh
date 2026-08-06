#!/bin/bash
## startup.sh -- GCE startup-script. Installs and drives the duty units.
##
## This file does NO provisioning itself. It materialises the guest assets from
## instance metadata, installs them, and hands off:
##
##   gce-env.service            metadata + Secret Manager -> VM env file
##   ssh-access.service         root authorized_keys, every boot
##   netbird-bootstrap.service  join the NetBird network, once
##   k3s-bootstrap.service      self-assemble k3s, once
##
## Runs on every boot. Materialising before starting is what keeps the units on
## the CURRENT module version rather than whatever last boot left on disk.
##
## Metadata inputs (instance/attributes):
##   env-script        contents of env.sh
##   ssh-script        contents of ssh.sh
##   bootstrap-script  contents of bootstrap.sh, shared by every installer duty
##   env-unit          contents of gce-env.service
##   ssh-unit          contents of ssh-access.service
##   netbird-unit      contents of netbird-bootstrap.service
##   k3s-unit          contents of k3s-bootstrap.service
##
## Output goes to journald:  journalctl -u google-startup-scripts
## Dependencies: curl, systemctl (Rocky 9 base).

set -euo pipefail

MD=http://metadata.google.internal/computeMetadata/v1/instance
INSTALL_DIR=/opt/k3s-gce
UNIT_DIR=/etc/systemd/system

mfetch() {
	local url="$1" out
	for _ in 1 2 3 4 5; do
		out=$(curl -fsS --retry 3 --retry-connrefused -H 'Metadata-Flavor: Google' "$url" 2>/dev/null) && { printf '%s' "$out"; return 0; }
		sleep 2
	done
	return 1
}

# Write atomically via a temp sibling, so a truncated metadata read can never
# leave a half-written script that systemd would then execute.
install_asset() {
	local key="$1" dest="$2" mode="$3" body
	body=$(mfetch "$MD/attributes/$key") || { echo "ERROR: metadata key '$key' unavailable" >&2; return 1; }
	[[ -n "$body" ]] || { echo "ERROR: metadata key '$key' is empty" >&2; return 1; }
	printf '%s\n' "$body" > "${dest}.tmp.$$"
	chmod "$mode" "${dest}.tmp.$$"
	mv "${dest}.tmp.$$" "$dest"
	echo "  installed $dest (mode $mode)"
}

echo "k3s-gce: installing guest assets"
mkdir -p "$INSTALL_DIR"

install_asset env-script       "$INSTALL_DIR/env.sh"                     0700
install_asset ssh-script       "$INSTALL_DIR/ssh.sh"                     0700
install_asset bootstrap-script "$INSTALL_DIR/bootstrap.sh"               0700
install_asset env-unit         "$UNIT_DIR/gce-env.service"               0644
install_asset ssh-unit         "$UNIT_DIR/ssh-access.service"            0644
install_asset netbird-unit     "$UNIT_DIR/netbird-bootstrap.service"     0644
install_asset k3s-unit         "$UNIT_DIR/k3s-bootstrap.service"         0644

systemctl daemon-reload

# env refreshes every boot, so restart rather than start -- the unit is
# RemainAfterExit=yes and `start` would be a no-op once it has run.
echo "k3s-gce: refreshing env"
systemctl restart gce-env.service

# Root key is declarative and cheap, so it refreshes every boot alongside env.
# Restart rather than start: RemainAfterExit makes `start` a no-op once run.
echo "k3s-gce: refreshing root ssh access"
systemctl restart ssh-access.service

# Each installer is guarded by ConditionPathExists in its unit; systemd reports
# a guarded unit as skipped, not failed, once its marker exists. Started in
# order, and Type=oneshot means each start blocks until that duty finishes.
# netbird first, so k3s comes up on a host already on the network.
#
# A failing duty must not take the others with it. Under `set -e` a non-zero
# `systemctl start` would abort this script and every later duty would simply
# never run -- which is how one netbird timeout once left k3s uninstalled and
# the VM otherwise healthy. Each duty is independent: its unit already declares
# After= without Requires=, and this loop honours that instead of undoing it.
failed=()
for duty in netbird-bootstrap k3s-bootstrap; do
	echo "k3s-gce: starting ${duty} (skipped by the unit if already done)"
	systemctl start "${duty}.service" || failed+=("${duty}")
done

if (( ${#failed[@]} )); then
	# Non-zero so the GCE agent records a failed startup-script, but only after
	# every duty has had its turn. journalctl -u <duty> has the detail.
	echo "k3s-gce: startup complete with failures: ${failed[*]}" >&2
	exit 1
fi

echo "k3s-gce: startup complete"
