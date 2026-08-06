#!/bin/bash
## netbird-login.sh -- root SSH over NetBird, using the key this root generated.
##
## No IAP tunnel, no gcloud, no OS Login. Requires only that this machine is on
## the same NetBird network as the VM.
##
## It FINDS the peer rather than predicting its name. NetBird owns the peer name
## and rewrites it at registration: a reusable setup key may register many
## machines, so it appends the address octets to keep names distinct, turning
## k3stest-17c6 into k3stest-17c6-68-183. That happens after apply, so Terraform
## cannot know the result -- and an earlier version of this script guessed,
## which failed with a misleading "Could not resolve hostname".
##
## The random suffix Terraform DOES control stays unique to one deployment, so
## it is a reliable search key inside whatever NetBird settled on. Matching on
## it works whether the key is single-use (no suffix) or reusable (suffixed),
## and does not depend on DNS resolving anything.
##
## Usage: ./netbird-login.sh                  (interactive shell)
##        ./netbird-login.sh <command...>     (one-off command)
set -euo pipefail
cd "$(dirname "$0")"

KEY="$(terraform output -raw root_key_file)"
PREFIX="$(terraform output -raw netbird_peer_prefix)"

[[ -f "$KEY" ]] || { echo "no key at $KEY -- has this root been applied?" >&2; exit 1; }
command -v netbird >/dev/null 2>&1 || {
	echo "netbird is not installed here -- this machine must be joined to the same network" >&2
	exit 1
}

# Match "<prefix>." or "<prefix>-" rather than a bare prefix, so a longer name
# that merely begins with the same characters cannot be mistaken for this peer.
find_peer_ip() {
	if command -v jq >/dev/null 2>&1; then
		netbird status --json | jq -r --arg p "$PREFIX" \
			'.peers.details[]? | select((.fqdn // "") | startswith($p + ".") or startswith($p + "-")) | .netbirdIp'
	elif command -v python3 >/dev/null 2>&1; then
		netbird status --json | python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(sys.stdin)
for x in (d.get("peers") or {}).get("details") or []:
    f = x.get("fqdn") or ""
    if f.startswith(p + ".") or f.startswith(p + "-"):
        print(x.get("netbirdIp") or "")
' "$PREFIX"
	else
		echo "need jq or python3 to read netbird status" >&2
		return 1
	fi
}

mapfile -t IPS < <(find_peer_ip | grep .)

case "${#IPS[@]}" in
	1) : ;;
	0)
		echo "no NetBird peer matching '${PREFIX}'." >&2
		echo "  the VM may still be joining, or the join may have failed." >&2
		echo "  check with: netbird status --detail" >&2
		exit 1
		;;
	*)
		echo "ambiguous: ${#IPS[@]} peers match '${PREFIX}': ${IPS[*]}" >&2
		echo "  a previous deployment may not have been reaped yet." >&2
		exit 1
		;;
esac

exec ssh -i "$KEY" \
	-o IdentitiesOnly=yes \
	-o StrictHostKeyChecking=accept-new \
	"root@${IPS[0]}" "$@"
