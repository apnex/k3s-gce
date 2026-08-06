#!/bin/bash
## netbird-login.sh -- root SSH over NetBird, using the key this root generated.
##
## No IAP tunnel, no gcloud, no OS Login. Requires only that this machine is
## connected to the same NetBird network as the VM, which is what resolves the
## peer FQDN.
##
## Usage: ./netbird-login.sh                  (interactive shell)
##        ./netbird-login.sh <command...>     (one-off command)
set -euo pipefail
cd "$(dirname "$0")"

KEY="$(terraform output -raw root_key_file)"
HOST="$(terraform output -raw netbird_fqdn)"

[[ -f "$KEY" ]] || { echo "no key at $KEY -- has this root been applied?" >&2; exit 1; }

exec ssh -i "$KEY" \
	-o IdentitiesOnly=yes \
	-o StrictHostKeyChecking=accept-new \
	"root@${HOST}" "$@"
