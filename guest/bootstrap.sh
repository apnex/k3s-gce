#!/bin/bash
## bootstrap.sh -- fetch an installer entrypoint over HTTPS and run it, once.
##
## ONE DUTY PER INVOCATION, named by $1. The duty selects its own metadata keys
## and its own marker, so one script serves every installer this module drives:
##
##   bootstrap.sh k3s      ->  k3s-*      ->  /root/k3s-gce/k3s.done
##   bootstrap.sh netbird  ->  netbird-*  ->  /root/k3s-gce/netbird.done
##
## Run-once and single-instance are enforced by the calling unit, not here:
##   ConditionPathExists=!/root/k3s-gce/<duty>.done   guards the re-run
##   systemd itself                                   guards concurrency
##   TimeoutStartSec=                                 guards a hung install
## The marker below is the persistent record the unit condition reads.
##
## Metadata inputs (instance/attributes), for duty <D>:
##   <D>-enable    on|off
##   <D>-url       URL of the entrypoint script
##   <D>-requires  space-separated commands the entrypoint needs, installed on
##                 demand when absent. Per duty, because the requirement belongs
##                 to the thing being installed and not to this script.
##
## The entrypoint is FETCHED, not cloned. It is one HTTPS GET against a base
## image that already has curl, where a clone needs git installed first -- a
## package absent from a stock Rocky image.
##
## There is no ref to pin. The URL names what runs, and whatever it serves at
## boot is what the node gets. An entrypoint that resolves further modules of
## its own does so over the same transport, on the same terms.
##
## Downloaded to disk before executing rather than piped into bash. A dropped
## connection mid-transfer leaves a truncated script, and bash executes what it
## already read -- so the download either completes or nothing runs.
##
## Output goes to journald under whichever unit invoked it.
## Dependencies: curl (Rocky 9 base). No git.

set -euo pipefail

DUTY="${1:-}"
if [[ -z "$DUTY" ]]; then
	echo "usage: bootstrap.sh <duty>" >&2
	exit 2
fi

# The duty name selects metadata keys and composes a filesystem path, so it is
# constrained rather than trusted. Anything else is a caller bug, not a config
# error, which is why it exits 2 rather than skipping quietly.
if [[ ! "$DUTY" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
	echo "ERROR: invalid duty name '$DUTY' -- expected ^[a-z0-9][a-z0-9-]*$" >&2
	exit 2
fi

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

ENABLE=$(md "${DUTY}-enable")
URL=$(md "${DUTY}-url")
REQUIRES=$(md "${DUTY}-requires")

STATE_DIR=/root/k3s-gce
MARKER="$STATE_DIR/${DUTY}.done"
mkdir -p "$STATE_DIR"

if [[ "${ENABLE:-off}" != "on" ]]; then
	echo "${DUTY}: disabled (${DUTY}-enable != on)"
	exit 0
fi

if [[ -z "$URL" ]]; then
	echo "${DUTY}: enabled but ${DUTY}-url missing -- skipping"
	exit 0
fi

echo "${DUTY}: self-assembling from ${URL}"

# Commands the entrypoint needs that a stock image may not carry. Declared per
# duty in Terraform rather than hardcoded here: k3s/prepare gates on jq and
# exits 1 without it, netbird unpacks a tarball. Installing rather than assuming
# is what keeps boot_disk_image a free choice.
if [[ -n "$REQUIRES" ]]; then
	missing=()
	for cmd in $REQUIRES; do
		command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
	done

	if (( ${#missing[@]} )); then
		echo "${DUTY}: installing ${missing[*]}"
		# The package mirror can be briefly unreachable on cold boot. A clear
		# error plus retry-next-boot beats a bare set -e abort.
		pkgok=
		for _ in 1 2 3; do
			dnf install -y -q "${missing[@]}" && { pkgok=1; break; }
			echo "WARN: dnf install ${missing[*]} failed -- retrying in 5s" >&2
			sleep 5
		done
		[[ -n "$pkgok" ]] || { echo "ERROR: could not install ${missing[*]} -- marker NOT written; will retry next boot" >&2; exit 1; }
	fi
fi

# A file per duty, not a directory per duty. An entrypoint that derives its own
# root from dirname($0)/.. -- as labops does for its module resolver -- then
# resolves to /opt/k3s-gce, which holds no module paths, so every module it
# wants falls through to its HTTPS transport. A directory named for the duty
# could shadow a module path of the same name.
WORK_DIR=/opt/k3s-gce/bootstrap
ENTRY="$WORK_DIR/${DUTY}.entrypoint"
mkdir -p "$WORK_DIR"

# Temp sibling then mv: the entrypoint on disk is either whole or absent, never
# a prefix of itself.
TMP="${ENTRY}.tmp.$$"
trap 'rm -f "$TMP"' EXIT

if ! curl -fsSL --retry 3 --retry-connrefused --max-time 120 "$URL" -o "$TMP"; then
	echo "ERROR: ${DUTY}: could not fetch entrypoint from $URL -- marker NOT written; will retry next boot" >&2
	exit 1
fi

# An empty body is a 200 that told us nothing. Running it would report success
# and leave nothing installed, which is the worst available outcome.
if [[ ! -s "$TMP" ]]; then
	echo "ERROR: ${DUTY}: entrypoint at $URL is empty -- marker NOT written; will retry next boot" >&2
	exit 1
fi

chmod 0700 "$TMP"
mv "$TMP" "$ENTRY"
trap - EXIT

if bash "$ENTRY"; then
	touch "$MARKER"
	echo "${DUTY}: complete (marker $MARKER written)"
else
	echo "ERROR: ${DUTY}: bootstrap failed -- marker NOT written; will retry next boot" >&2
	exit 1
fi
