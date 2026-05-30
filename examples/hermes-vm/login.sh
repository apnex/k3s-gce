#!/bin/bash
## login.sh — IAP SSH into the VM via the ssh_command output from TF state.
## Usage: ./login.sh                  (interactive shell)
##        ./login.sh --command="..."  (one-off command — passed to gcloud)
set -euo pipefail
cd "$(dirname "$0")"
exec $(terraform output -raw ssh_command) "$@"
