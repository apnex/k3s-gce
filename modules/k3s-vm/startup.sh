#!/bin/bash
## startup.sh — generic boot-time provisioner for a k3s-gce VM.
##
## Runs as root on every boot (GCE startup-script metadata key). Fully
## parameterised via VM metadata (set by the k3s-vm Terraform module) — this
## script is app-agnostic and needs no editing per deployment.
##
## Stages:
##   1. fetch app secrets from Secret Manager into the env file (0600)
##   2. auto-source that env file for root login shells (/etc/profile.d)
##   3. optionally self-assemble k3s by cloning the bring-up repo (first boot)
##
## Metadata inputs (instance/attributes):
##   k3s-project        GCP project id
##   k3s-secret-map     "KEY:container,KEY:container,…" — TF owns container
##                      naming (per-key scope); this script fetches by container
##   k3s-env-file       absolute path to write the sourced env file
##   k3s-bootstrap      on|off — self-assemble k3s on first boot
##   k3s-repo           git repo cloned for k3s bring-up
##   k3s-ref            git ref of k3s-repo
##   k3s-up-entrypoint  path within the repo to the bring-up entrypoint
##
## Dependencies: curl, sed, base64, printf %q (Rocky 9 base); git (installed
## on demand for bootstrap). No python, no jq, no gcloud.

set -eu

LOG=/var/log/k3s-gce-bootstrap.log
exec > >(tee -a "$LOG") 2>&1
echo
echo "=== k3s-gce bootstrap $(date -Is) ==="

MD=http://metadata.google.internal/computeMetadata/v1/instance

# curl with bounded retry — the metadata server can be briefly slow/5xx on a
# cold first boot. --retry covers transient 5xx/connection errors; the outer
# loop covers the rest. Never aborts the script (callers decide on empty).
mfetch() {
	local url="$1" out
	for _ in 1 2 3 4 5; do
		out=$(curl -fsS --retry 3 --retry-connrefused -H 'Metadata-Flavor: Google' "$url" 2>/dev/null) && { printf '%s' "$out"; return 0; }
		sleep 2
	done
	return 1
}
md() { mfetch "$MD/attributes/$1" || true; }

# ── inputs ──────────────────────────────────────────────────────────
PROJECT=$(md k3s-project)
SECRET_MAP=$(md k3s-secret-map)
ENV_FILE=$(md k3s-env-file)
BOOTSTRAP=$(md k3s-bootstrap)
REPO=$(md k3s-repo)
REF=$(md k3s-ref)
ENTRY=$(md k3s-up-entrypoint)

# Metadata always supplies k3s-env-file; this fallback is only a safety net and
# is deliberately app-neutral.
ENV_FILE="${ENV_FILE:-/root/app.env}"

# ── stage 1: secrets → env file ─────────────────────────────────────
# k3s-secret-map is "KEY:container,KEY:container,…" — TF composes the container
# names (it knows each key's scope), so this script just fetches by container.
if [[ -n "$PROJECT" && -n "$SECRET_MAP" ]]; then
	echo "--- secrets: project=$PROJECT -> $ENV_FILE"

	# Boot-safe: a missing token skips secret injection (logged) rather than
	# aborting the whole startup script — k3s self-assembly can still proceed.
	TOKEN=$(mfetch "$MD/service-accounts/default/token" | sed -n 's/.*"access_token":[[:space:]]*"\([^"]*\)".*/\1/p' || true)
	[[ -n "$TOKEN" ]] || echo "WARN: no access token from metadata server — skipping secret injection" >&2

	TMP="${ENV_FILE}.tmp.$$"
	: > "$TMP"
	chmod 600 "$TMP"

	written=0
	missed=0
	IFS=',' read -ra PAIRS <<< "$SECRET_MAP"
	for PAIR in "${PAIRS[@]}"; do
		[[ -n "$PAIR" ]] || continue
		KEY="${PAIR%%:*}"      # bare name written into the env file
		SECRET="${PAIR#*:}"    # SM container name to fetch from
		[[ -n "$KEY" && -n "$SECRET" ]] || continue
		URL="https://secretmanager.googleapis.com/v1/projects/${PROJECT}/secrets/${SECRET}/versions/latest:access"

		RESPONSE=$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "$URL" 2>/dev/null) || {
			echo "  - ${KEY}: not accessible (no version or no permission)"
			missed=$((missed + 1))
			continue
		}
		DATA_B64=$(printf '%s' "$RESPONSE" | sed -n 's/.*"data":[[:space:]]*"\([^"]*\)".*/\1/p')
		if [[ -z "$DATA_B64" ]]; then
			echo "  - ${KEY}: response missing payload.data"
			missed=$((missed + 1))
			continue
		fi
		VALUE=$(printf '%s' "$DATA_B64" | base64 -d 2>/dev/null) || {
			echo "  - ${KEY}: base64 decode failed"
			missed=$((missed + 1))
			continue
		}
		# %q produces bash-safe quoting; sources cleanly via set -a; . file; set +a
		printf '%s=%q\n' "$KEY" "$VALUE" >> "$TMP"
		echo "  + ${KEY}: written"
		written=$((written + 1))
	done

	mkdir -p "$(dirname "$ENV_FILE")"
	mv "$TMP" "$ENV_FILE"
	echo "env file: $written written, $missed missed -> $ENV_FILE"

	# ── stage 2: auto-source for root login shells ──────────────────
	# /etc/profile.d/*.sh is world-readable; secret values stay protected by
	# the env file's 0600 perms — non-root sees the logic, not the values.
	cat > /etc/profile.d/k3s-gce-env.sh <<PROFILE
# Auto-source ${ENV_FILE} for root login shells.
# Written by k3s-gce startup.sh — do not edit; overwritten on next boot.
if [ "\${EUID:-\$(id -u)}" = "0" ] && [ -r "${ENV_FILE}" ]; then
    set -a
    . "${ENV_FILE}"
    set +a
fi
PROFILE
	chmod 644 /etc/profile.d/k3s-gce-env.sh
	echo "/etc/profile.d/k3s-gce-env.sh: written (auto-sources ${ENV_FILE} for root login shells)"
else
	echo "--- secrets: skipped (env/project/prefix/keys metadata absent)"
fi

# ── stage 3: self-assemble k3s (first boot only) ────────────────────
MARKER=/var/lib/k3s-gce-bootstrapped
if [[ "${BOOTSTRAP:-off}" == "on" ]]; then
	if [[ -f "$MARKER" ]]; then
		echo "--- k3s: already bootstrapped (marker $MARKER) — skipping"
	elif [[ -z "$REPO" || -z "$ENTRY" ]]; then
		echo "--- k3s: bootstrap on but repo/entrypoint metadata missing — skipping"
	else
		echo "--- k3s: self-assembling from ${REPO}@${REF:-default} ($ENTRY)"
		if ! command -v git >/dev/null 2>&1; then
			echo "installing git..."
			# Retry — the package mirror can be briefly unreachable on cold boot.
			# A clear error + retry-next-boot beats a bare set -e abort.
			gitok=
			for _ in 1 2 3; do
				dnf install -y -q git && { gitok=1; break; }
				echo "WARN: dnf install git failed — retrying in 5s" >&2
				sleep 5
			done
			[[ -n "$gitok" ]] || { echo "ERROR: could not install git — marker NOT written; will retry next boot" >&2; exit 1; }
		fi
		CLONE_DIR="/opt/$(basename "${REPO%.git}")"

		# A complete clone has .git AND the entrypoint. Anything else (missing,
		# partial, or interrupted) is wiped and re-cloned — idempotent.
		if [[ ! -d "$CLONE_DIR/.git" || ! -f "$CLONE_DIR/$ENTRY" ]]; then
			rm -rf "$CLONE_DIR"
			git clone "$REPO" "$CLONE_DIR" || { echo "ERROR: git clone failed" >&2; exit 1; }
		fi

		# Pin to the requested ref. fetch+checkout handles branch, tag, OR commit
		# SHA uniformly (unlike clone --branch, which rejects a SHA). A fetch
		# failure on an existing clone is a warning — proceed with what's on disk.
		if [[ -n "$REF" ]]; then
			if git -C "$CLONE_DIR" fetch --depth 1 origin "$REF"; then
				git -C "$CLONE_DIR" checkout -q FETCH_HEAD || { echo "ERROR: checkout $REF failed" >&2; exit 1; }
			else
				echo "WARN: fetch '$REF' failed — proceeding with existing checkout" >&2
			fi
		fi

		if bash "${CLONE_DIR}/${ENTRY}"; then
			touch "$MARKER"
			echo "--- k3s: bootstrap complete (marker $MARKER written)"
		else
			echo "ERROR: k3s bootstrap failed — marker NOT written; will retry next boot" >&2
			exit 1
		fi
	fi
else
	echo "--- k3s: bootstrap disabled (k3s-bootstrap != on)"
fi

echo "=== k3s-gce bootstrap done $(date -Is) ==="
