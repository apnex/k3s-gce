#!/bin/bash
## startup.sh -- GCE startup-script. Installs and drives the two duty units.
##
## This file does NO provisioning itself. It materialises the guest assets from
## instance metadata, installs them, and hands off:
##
##   k3s-gce-env.service        metadata + Secret Manager -> VM env file
##   k3s-gce-bootstrap.service  self-assemble k3s, once
##
## Runs on every boot. Materialising before starting is what keeps the units on
## the CURRENT module version rather than whatever last boot left on disk.
##
## Metadata inputs (instance/attributes):
##   k3s-env-script        contents of env.sh
##   k3s-bootstrap-script  contents of k3s.sh
##   k3s-env-unit          contents of k3s-gce-env.service
##   k3s-bootstrap-unit    contents of k3s-gce-bootstrap.service
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

install_asset k3s-env-script       "$INSTALL_DIR/env.sh"                    0700
install_asset k3s-bootstrap-script "$INSTALL_DIR/k3s.sh"                    0700
install_asset k3s-env-unit         "$UNIT_DIR/k3s-gce-env.service"          0644
install_asset k3s-bootstrap-unit   "$UNIT_DIR/k3s-gce-bootstrap.service"    0644

systemctl daemon-reload

# env refreshes every boot, so restart rather than start -- the unit is
# RemainAfterExit=yes and `start` would be a no-op once it has run.
echo "k3s-gce: refreshing env"
systemctl restart k3s-gce-env.service

# bootstrap is guarded by ConditionPathExists in the unit; systemd reports it
# as skipped, not failed, once the marker exists.
echo "k3s-gce: starting bootstrap (skipped by the unit if already done)"
systemctl start k3s-gce-bootstrap.service

echo "k3s-gce: startup complete"
