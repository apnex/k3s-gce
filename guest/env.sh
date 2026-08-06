#!/bin/bash
## env.sh -- resolve app secrets into the VM runtime env file.
##
## ONE DUTY: metadata + Secret Manager -> ENV. It does not install anything.
##
## Runs on every boot via gce-env.service, and on demand via
##   systemctl restart gce-env
##
## Metadata inputs (instance/attributes):
##   env-project     GCP project id
##   env-secret-map  "ENV:container,ENV:container,..." -- Terraform owns the
##                   mapping; this script only resolves container names to
##                   values and writes them under the ENV name given
##   env-file    absolute path to write the env file
##
## Metadata carries NAMES, never values. Instance metadata is readable by any
## process on the VM and by anyone with compute.instances.get, so the values
## live in Secret Manager and are fetched with the VM's own identity.
##
## Two outputs, same values, different consumers:
##   $env-file        bash %q form, 0600. Sourced by /etc/profile.d for root
##                    login shells.
##   /run/gce-env/env systemd form, 0600 in a 0700 tmpfs dir. Consumed by units
##                    via EnvironmentFile=. This is how follow-on install units
##                    get their secrets without a human shell.
##
## A multi-line value cannot be expressed in EnvironmentFile= at all, so it is
## published there as KEY_B64 holding base64. The bash form always carries the
## literal value.
##
## Output goes to journald:  journalctl -u gce-env
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

PROJECT=$(md env-project)
SECRET_MAP=$(md env-secret-map)
ENV_FILE=$(md env-file)

# Metadata always supplies env-file; this fallback is a safety net only,
# and is deliberately app-neutral.
ENV_FILE="${ENV_FILE:-/root/app.env}"

if [[ -z "$PROJECT" || -z "$SECRET_MAP" ]]; then
	echo "secrets: skipped (env-project or env-secret-map absent)"
	exit 0
fi

echo "secrets: project=$PROJECT -> $ENV_FILE"

# A missing token skips injection with a warning rather than aborting: the node
# is still usable and the next boot retries.
TOKEN=$(mfetch "$MD/service-accounts/default/token" | sed -n 's/.*"access_token":[[:space:]]*"\([^"]*\)".*/\1/p' || true)
[[ -n "$TOKEN" ]] || echo "WARN: no access token from metadata server -- secret values will be unavailable" >&2

# Two outputs, same values, different consumers:
#
#   $ENV_FILE      bash %q form, sourced by /etc/profile.d for root shells
#   $SYSTEMD_ENV   systemd form, consumed by units via EnvironmentFile=
#
# They are not interchangeable. systemd's parser does not understand bash
# ANSI-C quoting, so a %q value like $'a\nb' is silently mangled rather than
# rejected -- and at least one secret here (an SSH private key) is multi-line.
SYSTEMD_DIR=/run/gce-env
SYSTEMD_ENV="$SYSTEMD_DIR/env"

# Create the target directories FIRST -- each temp file lives beside its target.
mkdir -p "$(dirname "$ENV_FILE")"
mkdir -p "$SYSTEMD_DIR"
chmod 700 "$SYSTEMD_DIR"

TMP="${ENV_FILE}.tmp.$$"
STMP="${SYSTEMD_ENV}.tmp.$$"
# Remove partial files on any abort: they are mode 0600 but may hold a subset
# of the secrets, and leaving them beside the real ones is confusing.
trap 'rm -f "$TMP" "$STMP"' EXIT

: > "$TMP"
chmod 600 "$TMP"
: > "$STMP"
chmod 600 "$STMP"

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

	# EnvironmentFile= is line-based and cannot express a newline at all, so a
	# multi-line value is published base64-encoded under KEY_B64. Consumers
	# decode it; nothing is silently truncated.
	if [[ "$VALUE" == *$'\n'* ]]; then
		printf '%s_B64="%s"\n' "$KEY" "$(printf '%s' "$VALUE" | base64 -w0)" >> "$STMP"
		echo "  + ${KEY}: written (multi-line, systemd form is ${KEY}_B64)"
	else
		esc=${VALUE//\\/\\\\}
		esc=${esc//\"/\\\"}
		printf '%s="%s"\n' "$KEY" "$esc" >> "$STMP"
		echo "  + ${KEY}: written"
	fi
	written=$((written + 1))
done

mv "$TMP" "$ENV_FILE"
mv "$STMP" "$SYSTEMD_ENV"
trap - EXIT
echo "env file: $written written, $missed missed -> $ENV_FILE"
echo "systemd env: $SYSTEMD_ENV (EnvironmentFile= form)"

# Auto-source for root login shells. /etc/profile.d/*.sh is world-readable;
# the values stay protected by the env file's 0600 mode, so a non-root user
# sees the logic and not the secrets.
cat > /etc/profile.d/gce-env.sh <<PROFILE
# Auto-source ${ENV_FILE} for root login shells.
# Written by gce-env -- do not edit; overwritten on next boot.
if [ "\${EUID:-\$(id -u)}" = "0" ] && [ -r "${ENV_FILE}" ]; then
    set -a
    . "${ENV_FILE}"
    set +a
fi
PROFILE
chmod 644 /etc/profile.d/gce-env.sh
echo "profile.d: /etc/profile.d/gce-env.sh written"
