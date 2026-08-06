## SYN

Self-assembling k3s VM on GCE.

Scope is the VM. Stands up:

- least-privilege Rocky VM with OS Login, no public IP - image follows `boot_disk_image`
- existing Secret Manager values read into an env file on boot
- (optional) k3s self-assembly on first boot

The VPC, subnet, firewall rules, Cloud NAT and project API enablement are **not** in scope.\
The module attaches to a subnetwork you already own.

Secret Manager containers are **not** in scope either.\
The module is a pure reader: it grants its VM read access to containers you already own, and never creates, writes or destroys one. No secret value passes through Terraform, so none can land in the plan file or in state.

It writes **no project-level IAM**, enables **no APIs**, and needs only a single `google` provider.\
Its service account is authorised per-secret and nothing else.

Assumes an authenticated `terraform` and `gcloud` against a GCP project, with `compute`, `iam` and `secretmanager` admin rights.

Confirm the tooling before starting:
```
gcloud auth list && terraform version
```

### prerequisites

You provide these.\
The routing ones fail at **boot**, not at apply, so a green `terraform apply` is not proof they are right.

- **A subnetwork** in the region derived from `var.zone` - passed as `subnetwork`. The module takes no `region` input; a GCE zone always contains its region, so a mismatch is unrepresentable.
- **A route to `secretmanager.googleapis.com`.** The VM has no public IP and fetches every secret over that endpoint. Either Private Google Access on the subnet or Cloud NAT satisfies it. Without one, the apply succeeds and the env file comes up empty.
- **General internet egress**, via Cloud NAT or equivalent, whenever `enable_k3s_bootstrap` is true. First boot fetches the bring-up entrypoint and downloads the k3s installer, neither of which is a Google API, so PGA cannot serve this. Without it the apply succeeds and no cluster appears.
- **An IAP-SSH firewall rule** allowing `35.235.240.0/20` to `tcp:22`, targeting the module's `network_tags` output. Without it the VM is unreachable.
- **Enabled APIs**: `compute`, `iam`, `cloudresourcemanager`, `iap`, `secretmanager`.

The metadata server needs nothing: it is link-local at `169.254.169.254`, and it is where the VM gets its config, its access token, and its OS Login data.\
SSH over IAP does not depend on PGA or NAT.

Enabling both PGA and NAT is the recommended shape, and what `examples/network` builds.\
PGA is redundant while NAT is present, but it keeps secret injection working if you later set `enable_k3s_bootstrap = false` and drop NAT.

### main.tf
```
locals {
	project_id	= "your-project-id"
	region		= "australia-southeast1"	# for the provider and the subnet lookup
	zone		= "australia-southeast1-a"	# the module derives its region from this
	name_prefix	= "demo"
	subnet_name	= "my-existing-subnet"
	env_secret_map	= {				# ENV var -> container that ALREADY exists
		APP_TOKEN	= "demo-app-token"
		LLM_API_KEY	= "shared-llm-api-key"
	}
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

module "k3s-gce" {
	source		= "github.com/apnex/k3s-gce"

	project_id	= local.project_id
	zone		= local.zone
	name_prefix	= local.name_prefix
	env_secret_map	= local.env_secret_map

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
```

### apply
```
terraform init
terraform plan
terraform apply -auto-approve
```

### secrets

`env_secret_map` is `ENV_VAR = "container-name"`, and every container must already exist.\
The module binds its VM service account as a reader on each and passes the mapping to the guest. It creates nothing, writes nothing, and destroys nothing.

The two names are decoupled deliberately.\
The map **key** becomes the variable name in the env file, so it must be a valid shell identifier - the module validates this. The map **value** is the container as Secret Manager actually names it, under whatever convention it already follows. Tying them together would make any pre-existing secret whose name is not a legal shell identifier unreadable.

Two keys may point at one container; the read grant is deduplicated.

Containers are created elsewhere - a separate Terraform root (see `examples/secrets`) or `gcloud secrets create`. Keeping the writer out of this module is what stops secret values reaching the plan file or state.

### notes

Everything that runs inside the VM lives in `guest/`, delivered through instance metadata.\
The scripts are static and generic, parameterised entirely by metadata keys, with no Terraform templating.

Keys are named `<duty>-<thing>`, and the two duties are named for what they are:

- **`env-*`** and `gce-env.service` are generic. Resolving Secret Manager values into an env file has nothing to do with k3s, and this half transplants to another GCE module unchanged.
- **`k3s-*`** and `k3s-bootstrap.service` are this module's installer, and say so.

The reusable piece is the pattern - `guest/` assets delivered by metadata, one systemd unit per duty, and the env contract below - not the k3s script itself.\
A module installing something else keeps the first half and swaps the second.

Provisioning is split into two units, one duty each:

- **`gce-env.service`** resolves Secret Manager values into the env file. Runs every boot, idempotent.
- **`k3s-bootstrap.service`** self-assembles k3s. Runs once, guarded by `ConditionPathExists=!/root/k3s-gce/bootstrapped`.

`guest/startup.sh` is the GCE startup-script and provisions nothing itself.\
It materialises the two scripts and two units from metadata, then drives them.

Materialising before starting is what keeps a rebooted VM on the current module version rather than on whatever the last boot left behind.

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

They are not interchangeable.\
systemd's parser does not understand bash ANSI-C quoting, so a `%q` value like `$'a\nb'` is silently mangled rather than rejected.

A multi-line value cannot be expressed in `EnvironmentFile=` at all, so it is published there as `KEY_B64` holding base64 - which is how a PEM key survives intact.

A follow-on install unit consumes the env by declaring two lines.

Suppose netbird:
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

Its script then reads `NETBIRD_SETUP_KEY` straight from its own environment, with no shell and no human in the path.\
Add an entry to `env_secret_map` and it appears there on the next boot.

`k3s-bootstrap` already consumes it this way, which is what puts the secrets in front of the bring-up entrypoint.

Concurrency, run-once and timeouts are the unit manager's job rather than hand-rolled: systemd will not run a unit twice at once, `ConditionPathExists` gates the re-run, and `TimeoutStartSec` bounds a hung bring-up so it cannot wedge the node.
