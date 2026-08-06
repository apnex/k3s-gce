#!/bin/bash
## ssh.sh -- install a root authorized_keys and permit key-only root login.
##
## ONE DUTY: root SSH access. It installs nothing and joins nothing.
##
## Runs on every boot via ssh-access.service, and on demand via
##   systemctl restart ssh-access
##
## Metadata inputs (instance/attributes):
##   ssh-root-key  public key to install for root. Empty removes the key and
##                 the sshd drop-in, restoring the image default.
##
## A public key is not secret, so it rides in metadata rather than Secret
## Manager. Metadata is readable by anyone with compute.instances.get, which is
## exactly the exposure a public key is designed to tolerate.
##
## This is ADDITIVE to OS Login, not a replacement. sshd consults
## AuthorizedKeysFile before AuthorizedKeysCommand, so root-by-key and OS Login
## coexist: the key reaches root over any route to port 22, and OS Login keeps
## serving Google identities over IAP as the break-glass path.
##
## Declarative both ways. An empty key removes what a previous boot installed,
## so clearing var.root_ssh_key actually revokes access rather than leaving it.
##
## Output goes to journald:  journalctl -u ssh-access
## Dependencies: sshd, systemctl (Rocky 9 base).

set -euo pipefail

MD=http://metadata.google.internal/computeMetadata/v1/instance
DROPIN=/etc/ssh/sshd_config.d/60-k3s-gce-root.conf
AUTHKEYS=/root/.ssh/authorized_keys

mfetch() {
	local url="$1" out
	for _ in 1 2 3 4 5; do
		out=$(curl -fsS --retry 3 --retry-connrefused -H 'Metadata-Flavor: Google' "$url" 2>/dev/null) && { printf '%s' "$out"; return 0; }
		sleep 2
	done
	return 1
}
md() { mfetch "$MD/attributes/$1" || true; }

KEY=$(md ssh-root-key)

# Reload only when sshd still parses. A rejected config leaves the running
# daemon on its previous one, which is what keeps a bad edit from locking
# everyone out of a host reachable only by SSH.
reload_sshd() {
	if sshd -t 2>/dev/null; then
		systemctl reload sshd 2>/dev/null || systemctl restart sshd
		echo "  sshd reloaded"
	else
		echo "ERROR: sshd config test failed -- leaving the running daemon alone" >&2
		sshd -t 2>&1 | sed 's/^/    /' >&2
		return 1
	fi
}

if [[ -z "$KEY" ]]; then
	# Nothing configured. Undo anything a previous boot left, so removing the
	# key from Terraform actually removes the access.
	changed=
	[[ -f "$DROPIN" ]] && { rm -f "$DROPIN"; changed=1; echo "ssh: removed $DROPIN"; }
	[[ -f "$AUTHKEYS" ]] && { rm -f "$AUTHKEYS"; changed=1; echo "ssh: removed $AUTHKEYS"; }
	[[ -n "$changed" ]] && reload_sshd
	echo "ssh: no root key configured"
	exit 0
fi

echo "ssh: installing root authorized_keys"

mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Temp sibling then mv: authorized_keys is never a partially written file, and
# sshd never reads one mid-write.
TMP="${AUTHKEYS}.tmp.$$"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$KEY" > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$AUTHKEYS"
trap - EXIT

# sshd takes the FIRST value it finds for a keyword. The stock config has
# `Include /etc/ssh/sshd_config.d/*.conf` above its own `PermitRootLogin no`,
# so a drop-in wins without editing the file the image shipped.
#
# prohibit-password, never yes: root by key only, and no password path is
# opened by permitting root at all.
printf 'PermitRootLogin prohibit-password\n' > "$DROPIN"
chmod 644 "$DROPIN"
echo "  wrote $DROPIN (PermitRootLogin prohibit-password)"

reload_sshd
echo "ssh: root key installed"
