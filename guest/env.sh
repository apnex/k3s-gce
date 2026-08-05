#!/bin/bash
## env.sh -- resolve app secrets into the VM runtime env file.
##
## ONE DUTY: metadata + Secret Manager -> ENV. It does not install anything.
##
## Runs on every boot via k3s-gce-env.service, and on demand via
##   systemctl restart k3s-gce-env
##
## Metadata inputs (instance/attributes):
##   k3s-project     GCP project id
##   k3s-secret-map  "KEY:container,KEY:container,..." -- Terraform owns the
##                   container naming (it knows each key's scope); this script
##                   only resolves names to values
##   k3s-env-file    absolute path to write the env file
##
## Metadata carries NAMES, never values. Instance metadata is readable by any
## process on the VM and by anyone with compute.instances.get, so the values
## live in Secret Manager and are fetched with the VM's own identity.
##
## Output goes to journald:  journalctl -u k3s-gce-env
## Dependencies: curl, sed, base64 (Rocky 9 base). No jq, no gcloud.

set -euo pipefail

MD=http://metadata.google.internal/computeMetadata/v1/instance

# Bounded retry -- the metadata server can be briefly slow or 5xx on a cold
# first boot. Never aborts; callers decide what an empty result means.
mfetch() {
	local url="$1" out
	for _ in 1 2 3 4 5; do
		out=$(curl -fsS --retry 3 --retry-connrefused -H 'Metadata-Flavor: Google' "$url" 2>/dev/null) && { printf '%s' "$out"; return 0; }
		sleep 2
	done
	return 1
}
md() { mfetch "$MD/attributes/$1" || true; }

PROJECT=$(md k3s-project)
SECRET_MAP=$(md k3s-secret-map)
ENV_FILE=$(md k3s-env-file)

# Metadata always supplies k3s-env-file; this fallback is a safety net only,
# and is deliberately app-neutral.
ENV_FILE="${ENV_FILE:-/root/app.env}"

if [[ -z "$PROJECT" || -z "$SECRET_MAP" ]]; then
	echo "secrets: skipped (k3s-project or k3s-secret-map absent)"
	exit 0
fi

echo "secrets: project=$PROJECT -> $ENV_FILE"

# A missing token skips injection with a warning rather than aborting: the node
# is still usable and the next boot retries.
TOKEN=$(mfetch "$MD/service-accounts/default/token" | sed -n 's/.*"access_token":[[:space:]]*"\([^"]*\)".*/\1/p' || true)
[[ -n "$TOKEN" ]] || echo "WARN: no access token from metadata server -- secret values will be unavailable" >&2

# Create the target directory FIRST -- the temp file lives beside the env file.
mkdir -p "$(dirname "$ENV_FILE")"

TMP="${ENV_FILE}.tmp.$$"
# Remove the partial file on any abort: it is mode 0600 but may hold a subset
# of the secrets, and leaving it beside the real env file is confusing.
trap 'rm -f "$TMP"' EXIT

: > "$TMP"
chmod 600 "$TMP"

written=0
missed=0
IFS=',' read -ra PAIRS <<< "$SECRET_MAP"
for PAIR in "${PAIRS[@]}"; do
	[[ -n "$PAIR" ]] || continue
	KEY="${PAIR%%:*}"      # bare name written into the env file
	SECRET="${PAIR#*:}"    # Secret Manager container to fetch from
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

mv "$TMP" "$ENV_FILE"
trap - EXIT
echo "env file: $written written, $missed missed -> $ENV_FILE"

# Auto-source for root login shells. /etc/profile.d/*.sh is world-readable;
# the values stay protected by the env file's 0600 mode, so a non-root user
# sees the logic and not the secrets.
cat > /etc/profile.d/k3s-gce-env.sh <<PROFILE
# Auto-source ${ENV_FILE} for root login shells.
# Written by k3s-gce env.sh -- do not edit; overwritten on next boot.
if [ "\${EUID:-\$(id -u)}" = "0" ] && [ -r "${ENV_FILE}" ]; then
    set -a
    . "${ENV_FILE}"
    set +a
fi
PROFILE
chmod 644 /etc/profile.d/k3s-gce-env.sh
echo "profile.d: /etc/profile.d/k3s-gce-env.sh written"
