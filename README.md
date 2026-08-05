## SYN

Self-assembling, internal-only k3s VM on GCE.

Scope is the VM. Stands up:

- least-privilege Rocky 9 VM with OS Login, no public IP
- application secrets in Secret Manager, fetched into an env file on boot
- pod->host SSH login identity (optional)
- k3s self-assembly on first boot (optional)

The VPC, subnet, firewall rules, Cloud NAT and project API enablement are **not** in scope.
The module attaches to a subnetwork you already own.

It writes **no project-level IAM** and enables **no APIs**.
Its service account is authorised per-secret, and its OS Login grant is bound to the instance rather than the project.

Assumes an authenticated `terraform` and `gcloud` against a GCP project, with `compute`, `iam` and `secretmanager` admin rights.

Confirm the tooling before starting:
```
gcloud auth list && terraform version
```

### prerequisites

You provide these. The routing ones fail at **boot**, not at apply, so a green `terraform apply` is not proof they are right.

- **A subnetwork in `var.region`** - passed as `subnetwork`.
- **A route to `secretmanager.googleapis.com`.** The VM has no public IP and fetches every secret over that endpoint. Either Private Google Access on the subnet or Cloud NAT satisfies it. Without one, the apply succeeds and the env file comes up empty.
- **General internet egress**, via Cloud NAT or equivalent, whenever `enable_k3s_bootstrap` is true. First boot clones the bring-up repo and downloads the k3s installer, neither of which is a Google API, so PGA cannot serve this. Without it the apply succeeds and no cluster appears.
- **An IAP-SSH firewall rule** allowing `35.235.240.0/20` to `tcp:22`, targeting the module's `network_tags` output. Without it the VM is unreachable.
- **Enabled APIs**: `compute`, `iam`, `cloudresourcemanager`, `iap`, `secretmanager`.

The metadata server needs nothing: it is link-local at `169.254.169.254`, and it is where the VM gets its config, its access token, and its OS Login data. SSH over IAP does not depend on PGA or NAT.

Enabling both PGA and NAT is the recommended shape, and what `examples/hermes-vm/network.tf` does. PGA is redundant while NAT is present, but it keeps secret injection working if you later set `enable_k3s_bootstrap = false` and drop NAT.

### main.tf
```
locals {
	project_id	= "your-project-id"
	region		= "australia-southeast1"
	name_prefix	= "demo"
	subnet_name	= "my-existing-subnet"
	secret_keys	= [
		{ key = "APP_TOKEN" },				# self   -> demo-APP_TOKEN
		{ key = "LLM_API_KEY", scope = "shared" }	# shared -> shared-LLM_API_KEY
	]
}

provider "google" {
	project	= local.project_id
	region	= local.region
}

# the module attaches to a subnet you already own -- see prerequisites
data "google_compute_subnetwork" "target" {
	name	= local.subnet_name
	region	= local.region
}

# registers the module's OS Login key AS ssh-target -- importSshPublicKey is self-only
provider "google" {
	alias				= "ssh_login"
	project				= local.project_id
	region				= local.region
	impersonate_service_account	= "${local.name_prefix}-ssh-target@${local.project_id}.iam.gserviceaccount.com"
}

module "k3s-gce" {
	source		= "github.com/apnex/k3s-gce"
	providers = {
		google			= google
		google.ssh_login	= google.ssh_login
	}

	project_id	= local.project_id
	region		= local.region
	name_prefix	= local.name_prefix
	secret_keys	= local.secret_keys

	subnetwork	= data.google_compute_subnetwork.target.id
}

# target the tags the module actually applied, so the two cannot drift
resource "google_compute_firewall" "allow_iap_ssh" {
	name		= "${local.name_prefix}-allow-iap-ssh"
	network		= data.google_compute_subnetwork.target.network
	direction	= "INGRESS"

	allow {
		protocol	= "tcp"
		ports		= ["22"]
	}

	source_ranges	= ["35.235.240.0/20"]
	target_tags	= module.k3s-gce.network_tags
}

output "ssh_command" {
	value = module.k3s-gce.ssh_command
}
output "ssh_target_sa_email" {
	value = module.k3s-gce.ssh_target_sa_email
}
```

### apply
```
terraform init
terraform plan
terraform apply -auto-approve
```

### secrets

Containers are named `<scope>-<KEY>`.\
A `self` scope - the default - is created by the module under `name_prefix`.\
A shared label references an already-existing container read-only, and the module grants the VM SA read access without creating or writing it.

`secret_values` writes Secret Manager versions for self-scoped keys only.\
Those values land in `terraform.tfstate` in plaintext, so treat state as sensitive.

### first apply

The `google.ssh_login` alias is required whenever `enable_ssh_target_login` is true, which is the default.\
A provider cannot `depend_on` a resource, so on a clean apply that provider tries to impersonate a service account the same apply is still creating.

Split the first apply into two phases:
```
terraform apply \
	-target=module.k3s-gce.google_service_account.ssh_target \
	-target=module.k3s-gce.google_service_account_iam_member.tf_impersonate_ssh_target
terraform apply
```

Subsequent applies need only `terraform apply`.

### org grant

The module grants `compute.osAdminLogin` on the VM instance itself, not on the project, so the identity can only reach the VM this module created.

The `ssh-target` SA is out-of-domain, so OS Login also treats it as external.\
An org admin must grant it `compute.osLoginExternalUser` at the organization node - the role returns HTTP 400 if bound at project level.

Grant it once per deployment:
```
gcloud organizations add-iam-policy-binding <ORG_ID> \
	--member="serviceAccount:$(terraform output -raw ssh_target_sa_email)" \
	--role="roles/compute.osLoginExternalUser"
```

The guest agent caches OS Login authz.

Restart it before testing:
```
sudo systemctl restart google-guest-agent
```

Recreating the SA mints a new `unique_id` and orphans the grant, so re-grant after any destroy/recreate of the identity.

### without pod->host SSH

Setting `enable_ssh_target_login` to false skips the login identity, and with it the two-phase first apply and the org grant.\
Still pass the `google.ssh_login` alias - Terraform requires declared aliases to be wired even when unused.

```
enable_ssh_target_login = false
```

### notes

Everything that runs inside the VM lives in `guest/`, delivered through instance metadata. The scripts are static and generic, parameterised entirely by metadata keys, with no Terraform templating.

Keys are named `<duty>-<thing>`, and the two duties are named for what they are:

- **`env-*`** and `gce-env.service` are generic. Resolving Secret Manager values into an env file has nothing to do with k3s, and this half transplants to another GCE module unchanged.
- **`k3s-*`** and `k3s-bootstrap.service` are this module's installer, and say so.

The reusable piece is the pattern - `guest/` assets delivered by metadata, one systemd unit per duty, and the env contract below - not the k3s script itself. A module installing something else keeps the first half and swaps the second.

Provisioning is split into two units, one duty each:

- **`gce-env.service`** resolves Secret Manager values into the env file. Runs every boot, idempotent.
- **`k3s-bootstrap.service`** self-assembles k3s. Runs once, guarded by `ConditionPathExists=!/root/k3s-gce/bootstrapped`.

`guest/startup.sh` is the GCE startup-script and provisions nothing itself. It materialises the two scripts and two units from metadata, then drives them. Materialising before starting is what keeps a rebooted VM on the current module version rather than on whatever the last boot left behind.

They share no runtime state, so a secret refresh cannot disturb k3s.

Refresh secrets without touching k3s:
```
sudo systemctl restart gce-env
```

Read the logs, which go to the journal and rotate there:
```
journalctl -u gce-env -u k3s-bootstrap
```

Force a re-bootstrap by clearing the marker the unit condition reads:
```
sudo rm -f /root/k3s-gce/bootstrapped
sudo systemctl start k3s-bootstrap
```

### env contract

`gce-env` writes the same values twice, for two different kinds of consumer.

| Path | Form | Consumer |
|---|---|---|
| `<env_file_path>` | bash `%q`, 0600 | root login shells, via `/etc/profile.d` |
| `/run/gce-env/env` | `EnvironmentFile=`, 0600 in a 0700 tmpfs dir | systemd units |

They are not interchangeable. systemd's parser does not understand bash ANSI-C quoting, so a `%q` value like `$'a\nb'` is silently mangled rather than rejected. A multi-line value cannot be expressed in `EnvironmentFile=` at all, so it is published there as `KEY_B64` holding base64 - `SSH_TARGET_KEY` is exactly this case.

A follow-on install unit consumes the env by declaring two lines. Suppose netbird:
```
[Unit]
After=gce-env.service
Requires=gce-env.service

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/run/gce-env/env
ExecStart=/opt/k3s-gce/netbird.sh
```

Its script then reads `NETBIRD_SETUP_KEY` straight from its own environment, with no shell and no human in the path. Add the key to `secret_keys` and it appears there on the next boot.

`k3s-bootstrap` already consumes it this way, which is what puts the secrets in front of the bring-up entrypoint.

Concurrency, run-once and timeouts are the unit manager's job rather than hand-rolled: systemd will not run a unit twice at once, `ConditionPathExists` gates the re-run, and `TimeoutStartSec` bounds a hung bring-up so it cannot wedge the node.
