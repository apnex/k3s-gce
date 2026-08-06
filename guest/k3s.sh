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
##   k3s-bootstrap      on|off
##   k3s-repo           git repo cloned for bring-up
##   k3s-ref            git ref of k3s-repo (branch, tag, or commit SHA)
##   k3s-up-entrypoint  path within the repo to the bring-up entrypoint
##
## Output goes to journald:  journalctl -u k3s-bootstrap
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

BOOTSTRAP=$(md k3s-bootstrap)
REPO=$(md k3s-repo)
REF=$(md k3s-ref)
ENTRY=$(md k3s-up-entrypoint)

STATE_DIR=/root/k3s-gce
MARKER="$STATE_DIR/bootstrapped"
mkdir -p "$STATE_DIR"

if [[ "${BOOTSTRAP:-off}" != "on" ]]; then
	echo "k3s: bootstrap disabled (k3s-bootstrap != on)"
	exit 0
fi

if [[ -z "$REPO" || -z "$ENTRY" ]]; then
	echo "k3s: bootstrap on but k3s-repo or k3s-up-entrypoint missing -- skipping"
	exit 0
fi

echo "k3s: self-assembling from ${REPO}@${REF:-default} ($ENTRY)"

# Commands the bring-up needs that a minimal Rocky image may not carry:
#
#   git  clones the bring-up repo, below.
#   jq   k3s/prepare checks for it and exits 1 if absent, which fails the whole
#        bring-up. Nothing k3s/up runs actually calls jq -- metallb/install
#        resolves its release tag with sed -- but the gate is real, so satisfy
#        it here rather than discover it from a failed unit.
#
# Installing them here rather than assuming the image carries them is what keeps
# boot_disk_image a free choice.
REQUIRED_CMDS=(git jq)

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

CLONE_DIR="/opt/$(basename "${REPO%.git}")"

# Guard the rm -rf below: CLONE_DIR is derived from operator-supplied metadata,
# and a degenerate k3s-repo (e.g. "/") would otherwise resolve to /opt itself.
case "$CLONE_DIR" in
	/opt/?*) : ;;
	*) echo "ERROR: refusing to use clone dir '$CLONE_DIR' derived from k3s-repo '$REPO'" >&2; exit 1 ;;
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
