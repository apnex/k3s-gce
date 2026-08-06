#!/bin/bash
## k3s.sh -- self-assemble k3s from a bring-up entrypoint, once.
##
## ONE DUTY: install k3s. It does not touch secrets or the env file.
##
## Run-once and single-instance are enforced by the unit, not by this script:
##   ConditionPathExists=!/root/k3s-gce/bootstrapped   guards the re-run
##   systemd itself                                    guards concurrency
##   TimeoutStartSec=                                  guards a hung bring-up
## The marker below is the persistent record the unit condition reads.
##
## Metadata inputs (instance/attributes):
##   k3s-bootstrap  on|off
##   k3s-url        URL of the bring-up entrypoint script
##
## The entrypoint is FETCHED, not cloned. It is one HTTPS GET against a base
## image that already has curl, where a clone needs git installed first -- a
## package that is absent from a stock Rocky image and cost roughly a third of
## the bring-up wall time to put there.
##
## There is no ref to pin. The URL names what runs, and whatever it serves at
## boot is what the node gets. An entrypoint that resolves further modules of
## its own does so over the same transport, on the same terms.
##
## Downloaded to disk before executing rather than piped into bash. A dropped
## connection mid-transfer leaves a truncated script, and bash executes what it
## already read -- so the download either completes or nothing runs.
##
## Output goes to journald:  journalctl -u k3s-bootstrap
## Dependencies: curl (Rocky 9 base). No git.

set -euo pipefail

MD=http://metadata.google.internal/computeMetadata/v1/instance

mfetch() {
	local url="$1" out
	for _ in 1 2 3 4 5; do
		out=$(curl -fsS --retry 3 --retry-connrefused -H 'Metadata-Flavor: Google' "$url" 2>/dev/null) && { printf '%s' "$out"; return 0; }
		sleep 2
	done
	return 1
}
md() { mfetch "$MD/attributes/$1" || true; }

BOOTSTRAP=$(md k3s-bootstrap)
URL=$(md k3s-url)

STATE_DIR=/root/k3s-gce
MARKER="$STATE_DIR/bootstrapped"
mkdir -p "$STATE_DIR"

if [[ "${BOOTSTRAP:-off}" != "on" ]]; then
	echo "k3s: bootstrap disabled (k3s-bootstrap != on)"
	exit 0
fi

if [[ -z "$URL" ]]; then
	echo "k3s: bootstrap on but k3s-url missing -- skipping"
	exit 0
fi

echo "k3s: self-assembling from ${URL}"

# jq is the one command the bring-up needs that a stock Rocky image may not
# carry: k3s/prepare checks for it and exits 1 if absent, failing the whole
# sequence. Nothing k3s/up runs actually calls jq -- metallb/install resolves
# its release tag with sed -- but the gate is real, so satisfy it here rather
# than discover it from a failed unit.
#
# Installing rather than assuming is what keeps boot_disk_image a free choice.
REQUIRED_CMDS=(jq)

missing=()
for cmd in "${REQUIRED_CMDS[@]}"; do
	command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if (( ${#missing[@]} )); then
	echo "installing: ${missing[*]}"
	# The package mirror can be briefly unreachable on cold boot. A clear error
	# plus retry-next-boot beats a bare set -e abort.
	pkgok=
	for _ in 1 2 3; do
		dnf install -y -q "${missing[@]}" && { pkgok=1; break; }
		echo "WARN: dnf install ${missing[*]} failed -- retrying in 5s" >&2
		sleep 5
	done
	[[ -n "$pkgok" ]] || { echo "ERROR: could not install ${missing[*]} -- marker NOT written; will retry next boot" >&2; exit 1; }
fi

# Its own directory, so an entrypoint that derives paths from $0 -- as labops
# does for its module resolver -- lands somewhere predictable rather than
# beside this script.
WORK_DIR=/opt/k3s-gce/bootstrap
ENTRY="$WORK_DIR/entrypoint"
mkdir -p "$WORK_DIR"

# Temp sibling then mv: the entrypoint on disk is either whole or absent, never
# a prefix of itself.
TMP="${ENTRY}.tmp.$$"
trap 'rm -f "$TMP"' EXIT

if ! curl -fsSL --retry 3 --retry-connrefused --max-time 120 "$URL" -o "$TMP"; then
	echo "ERROR: could not fetch entrypoint from $URL -- marker NOT written; will retry next boot" >&2
	exit 1
fi

# An empty body is a 200 that told us nothing. Running it would report success
# and leave no cluster, which is the worst available outcome.
if [[ ! -s "$TMP" ]]; then
	echo "ERROR: entrypoint at $URL is empty -- marker NOT written; will retry next boot" >&2
	exit 1
fi

chmod 0700 "$TMP"
mv "$TMP" "$ENTRY"
trap - EXIT

if bash "$ENTRY"; then
	touch "$MARKER"
	echo "k3s: bootstrap complete (marker $MARKER written)"
else
	echo "ERROR: k3s bootstrap failed -- marker NOT written; will retry next boot" >&2
	exit 1
fi
