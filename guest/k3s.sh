#!/bin/bash
## k3s.sh -- self-assemble k3s from the bring-up repo, once.
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
##   bootstrap-enabled      on|off
##   bootstrap-repo           git repo cloned for bring-up
##   bootstrap-ref            git ref of bootstrap-repo (branch, tag, or commit SHA)
##   bootstrap-entrypoint  path within the repo to the bring-up entrypoint
##
## Output goes to journald:  journalctl -u gce-bootstrap
## Dependencies: curl (Rocky 9 base); git, installed on demand.

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

BOOTSTRAP=$(md bootstrap-enabled)
REPO=$(md bootstrap-repo)
REF=$(md bootstrap-ref)
ENTRY=$(md bootstrap-entrypoint)

STATE_DIR=/root/k3s-gce
MARKER="$STATE_DIR/bootstrapped"
mkdir -p "$STATE_DIR"

if [[ "${BOOTSTRAP:-off}" != "on" ]]; then
	echo "k3s: bootstrap disabled (bootstrap-enabled != on)"
	exit 0
fi

if [[ -z "$REPO" || -z "$ENTRY" ]]; then
	echo "k3s: bootstrap on but bootstrap-repo or bootstrap-entrypoint missing -- skipping"
	exit 0
fi

echo "k3s: self-assembling from ${REPO}@${REF:-default} ($ENTRY)"

if ! command -v git >/dev/null 2>&1; then
	echo "installing git..."
	# The package mirror can be briefly unreachable on cold boot. A clear error
	# plus retry-next-boot beats a bare set -e abort.
	gitok=
	for _ in 1 2 3; do
		dnf install -y -q git && { gitok=1; break; }
		echo "WARN: dnf install git failed -- retrying in 5s" >&2
		sleep 5
	done
	[[ -n "$gitok" ]] || { echo "ERROR: could not install git -- marker NOT written; will retry next boot" >&2; exit 1; }
fi

CLONE_DIR="/opt/$(basename "${REPO%.git}")"

# Guard the rm -rf below: CLONE_DIR is derived from operator-supplied metadata,
# and a degenerate bootstrap-repo (e.g. "/") would otherwise resolve to /opt itself.
case "$CLONE_DIR" in
	/opt/?*) : ;;
	*) echo "ERROR: refusing to use clone dir '$CLONE_DIR' derived from bootstrap-repo '$REPO'" >&2; exit 1 ;;
esac

# A complete clone has .git AND the entrypoint. Anything else (missing, partial,
# or interrupted) is wiped and re-cloned -- idempotent.
if [[ ! -d "$CLONE_DIR/.git" || ! -f "$CLONE_DIR/$ENTRY" ]]; then
	rm -rf "$CLONE_DIR"
	git clone "$REPO" "$CLONE_DIR" || { echo "ERROR: git clone failed" >&2; exit 1; }
fi

# Pin to the requested ref. fetch+checkout handles branch, tag OR commit SHA
# uniformly, unlike clone --branch which rejects a SHA. A fetch failure on an
# existing clone is a warning -- proceed with what is on disk.
if [[ -n "$REF" ]]; then
	if git -C "$CLONE_DIR" fetch --depth 1 origin "$REF"; then
		git -C "$CLONE_DIR" checkout -q FETCH_HEAD || { echo "ERROR: checkout $REF failed" >&2; exit 1; }
	else
		echo "WARN: fetch '$REF' failed -- proceeding with existing checkout" >&2
	fi
fi

if bash "${CLONE_DIR}/${ENTRY}"; then
	touch "$MARKER"
	echo "k3s: bootstrap complete (marker $MARKER written)"
else
	echo "ERROR: k3s bootstrap failed -- marker NOT written; will retry next boot" >&2
	exit 1
fi
