# k3s-gce

## SYN

Self-assembling k3s VM on GCE.

Scope is the VM. Stands up:

- least-privilege Rocky VM with OS Login, no public IP - image follows `boot_disk_image`
- config and existing Secret Manager values read into an env file on boot
- (optional) NetBird network join on first boot
- (optional) k3s self-assembly on first boot

The VPC, subnet, firewall rules, Cloud NAT and project API enablement are **not** in scope.\
The module attaches to a subnetwork you already own.

Secret Manager containers are **not** in scope either.\
The module is a pure reader: it grants its VM read access to containers you already own, and never creates, writes or destroys one.\
No secret value passes through Terraform, so none can land in the plan file or in state.

It writes **no project-level IAM**, enables **no APIs**, and needs only a single `google` provider.\
Its service account is authorised per-secret and nothing else.

---

## Prerequisites

Assumes an authenticated `terraform` and `gcloud` against a GCP project, with `compute`, `iam` and `secretmanager` admin rights.

Confirm the tooling before starting:
```
gcloud auth list && terraform version
```

You provide the rest.\
The routing ones fail at **boot**, not at apply, so a green `terraform apply` is not proof they are right.

- **A subnetwork** in the region derived from `var.zone` - passed as `subnetwork`. The module takes no `region` input; a GCE zone always contains its region, so a mismatch is unrepresentable.
- **A route to `secretmanager.googleapis.com`.** The VM has no public IP and fetches every secret over that endpoint. Either Private Google Access on the subnet or Cloud NAT satisfies it. Without one, the apply succeeds and the env file comes up short.
- **General internet egress**, via Cloud NAT or equivalent, whenever `enable_k3s_bootstrap` is true. First boot fetches the bring-up entrypoint and downloads the k3s installer, neither of which is a Google API, so PGA cannot serve this. Without it the apply succeeds and no cluster appears.
- **An IAP-SSH firewall rule** allowing `35.235.240.0/20` to `tcp:22`, targeting the module's `network_tags` output. Without it the VM is unreachable.
- **Enabled APIs**: `compute`, `iam`, `cloudresourcemanager`, `iap`, `secretmanager`.

The metadata server needs nothing: it is link-local at `169.254.169.254`, and it is where the VM gets its config, its access token, and its OS Login data.\
SSH over IAP does not depend on PGA or NAT.

Enabling both PGA and NAT is the recommended shape, and what `examples/network` builds.\
PGA is redundant while NAT is present, but it keeps secret injection working if you later set `enable_k3s_bootstrap = false` and drop NAT.

---

## Install

Wire one `google` provider, look up the subnet you own, and pass it in.\
`examples/vm` is this as a runnable root, and [`examples/README.md`](examples/README.md) walks the full journey including the network and secret prerequisites.

Write `main.tf`:
```
locals {
	project_id	= "your-project-id"
	region		= "australia-southeast1"	# for the provider and the subnet lookup
	zone		= "australia-southeast1-a"	# the module derives its region from this
	name_prefix	= "demo"
	subnet_name	= "my-existing-subnet"
	env_metadata_map		= {				# plain config, rides in metadata
		K3S_STORAGE	= "on"
	}
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
	env_metadata_map		= local.env_metadata_map
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

Apply it:
```
terraform init
terraform plan
terraform apply
```

The apply returns once the instance exists.\
Bring-up continues on the VM for several minutes after that, bounded by `TimeoutStartSec` in `k3s-bootstrap.service`.

---

## Use

Set `root_ssh_key` and root is reachable by key over any route to port 22 - a VPN, a bastion, anything - with no gcloud in the path.\
It is **additive**: `sshd` consults `AuthorizedKeysFile` before `AuthorizedKeysCommand`, so OS Login keeps working over IAP as the break-glass route for when that network is down. The key is declarative, so clearing the variable removes it on the next boot.

`examples/vm` generates a keypair per deployment and ships `netbird-login.sh`, which reads the key path from an output and finds the peer by its per-deployment prefix:
```
./netbird-login.sh
```

Connect over the IAP tunnel instead, then `sudo -i` for root:
```
gcloud compute ssh <name_prefix>-vm --zone=<zone> --project=<project_id> --tunnel-through-iap
```

The `ssh_command` output prints exactly that line, filled in.

Refresh config and secrets without touching k3s:
```
sudo systemctl restart gce-env
```

Read the logs, which go to the journal and rotate there:
```
journalctl -u gce-env -u k3s-bootstrap
```

Force a duty to re-run by clearing the marker its unit condition reads:
```
sudo rm -f /root/k3s-gce/k3s.done
sudo systemctl start k3s-bootstrap
```

---

## Test

Validate the module with no values at all, straight from the repo:
```
terraform -chdir=examples/vm init -backend=false
terraform -chdir=examples/vm validate
```

Confirm the env chain reached the guest, and the bring-up ran:
```
sudo journalctl -u gce-env -u k3s-bootstrap --no-pager
```

Confirm self-assembly reached a healthy cluster:
```
sudo /usr/local/bin/kubectl get nodes,sc
```

Use the full path.\
`k3s/prepare` fixes root's `PATH` through `/etc/profile.d`, which applies to login shells only - `sudo kubectl` is not one.

Set `K3S_DRYRUN` in `env_metadata_map` to exercise the whole delivery chain without installing anything.\
The bring-up entrypoint reads it after computing its plan and exits before running a single module.

With `enable_netbird`, confirm the peer joined:
```
sudo journalctl -u netbird-bootstrap --no-pager
sudo /usr/local/bin/netbird status
```

---

## Remove

Destroy from the root that owns the VM:
```
terraform destroy
```

The module owns the instance, its static internal IP, and its service account.\
Everything else it touched - the subnet, the containers it read, the APIs - belongs to whoever created it and survives.

---

## Inputs

| Name | Default | Purpose |
|---|---|---|
| `project_id` | required | GCP project the VM deploys into |
| `subnetwork` | required | Self link or ID of an existing subnetwork |
| `zone` | `australia-southeast1-a` | The region is derived from this |
| `name_prefix` | `k3s` | Prefix for every resource name |
| `machine_type` | `e2-medium` | GCE machine type |
| `boot_disk_image` | Rocky 9 family | Image or family |
| `boot_disk_size_gb` | `20` | Boot disk size |
| `network_tags` | derived | Defaults to `["<name_prefix>-vm"]`; also an output |
| `env_metadata_map` | `{}` | Plain config, `NAME = "value"` |
| `env_secret_map` | `{}` | Secrets, `NAME = "existing-container"` |
| `env_file_path` | derived | Defaults to `/root/<name_prefix>.env` |
| `root_ssh_key` | `null` | Public key for root; additive to OS Login |
| `enable_k3s_bootstrap` | `true` | Run the k3s bring-up on first boot |
| `k3s_bootstrap_url` | `https://labops.sh/k3s/up` | Entrypoint fetched over HTTPS |
| `enable_netbird` | `false` | Join NetBird on first boot, before k3s |
| `netbird_bootstrap_url` | `https://labops.sh/netbird/up` | Entrypoint fetched over HTTPS |

---

## Outputs

| Name | Purpose |
|---|---|
| `vm_name` | Name of the VM |
| `vm_internal_ip` | Static internal IP |
| `vm_zone` | Zone the VM lives in |
| `vm_sa_email` | Runtime service account, for grants beyond secret reads |
| `network_tags` | Tags applied - target these from your IAP-SSH rule |
| `ssh_command` | Ready-made IAP tunnel command |

---

## Config and secrets

Two maps, same destination, different transport.

`env_metadata_map` is `NAME = "value"` and rides in instance metadata.\
Metadata is readable by any process on the VM and by anyone holding `compute.instances.get`, so this is for config with nothing to hide - feature switches, tuning knobs, endpoints.

`env_secret_map` is `NAME = "container-name"` and carries names only.\
Every container must already exist. The module binds its VM service account as a reader on each and passes the mapping to the guest. It creates nothing, writes nothing, and destroys nothing.

A name may appear in one map or the other, never both.\
The module rejects an overlap at plan time rather than letting one silently win on the VM.

The two halves of `env_secret_map` are decoupled deliberately.\
The **key** becomes the variable name in the env file, so it must be a valid shell identifier - the module validates this. The **value** is the container as Secret Manager actually names it, under whatever convention it already follows. Tying them together would make any pre-existing secret whose name is not a legal shell identifier unreadable.

Two keys may point at one container; the read grant is deduplicated.

Containers are created elsewhere - a separate Terraform root (see `examples/secrets`) or `gcloud secrets create`.\
Keeping the writer out of this module is what stops secret values reaching the plan file or state.

`enable_netbird` consumes its setup key this way rather than through an input of its own:
```
env_secret_map = { NETBIRD_SETUP_KEY = "netbird-setup-key" }
enable_netbird = true
```

The module validates that pairing at plan time, so a missing key is an error before the VM exists rather than a failed unit after it.

---

## Guest assets

Everything that runs inside the VM lives in `guest/`, delivered through instance metadata.\
The scripts are static and generic, parameterised entirely by metadata keys, with no Terraform templating.

Keys are named `<duty>-<thing>`, and the two duties are named for what they are:

- **`env-*`** and `gce-env.service` are generic. Resolving metadata and Secret Manager values into an env file has nothing to do with k3s, and this half transplants to another GCE module unchanged.
- **`k3s-*`** and `k3s-bootstrap.service` are this module's installer, and say so.

The reusable piece is the pattern - `guest/` assets delivered by metadata, one systemd unit per duty, and the env contract below - not the k3s script itself.\
A module installing something else keeps the first half and swaps the second.

Provisioning is split into units, one duty each:

- **`gce-env.service`** resolves config and secrets into the env file. Runs every boot, idempotent.
- **`ssh-access.service`** installs the root `authorized_keys` and a sshd drop-in. Runs every boot, idempotent.
- **`netbird-bootstrap.service`** joins the NetBird network. Runs once, guarded by `ConditionPathExists=!/root/k3s-gce/netbird.done`.
- **`k3s-bootstrap.service`** self-assembles k3s. Runs once, guarded by `ConditionPathExists=!/root/k3s-gce/k3s.done`.

The two installers run the **same** `bootstrap.sh`, differing only in the duty name passed to it.\
A duty is `<name>-enable`, `<name>-url` and `<name>-requires` in metadata, plus a marker at `/root/k3s-gce/<name>.done`. Adding a third installs nothing new on the guest.

`netbird` is ordered ahead of `k3s`, so the cluster comes up on a host already on the network.\
A failing duty does not take the others with it - `startup.sh` runs each in turn and reports at the end, so one broken installer cannot leave the rest unrun.

A duty unit is named `<duty>-bootstrap.service`, never `<duty>.service`.\
An installer that registers a system service of its own would otherwise be shadowed by the very unit invoking it: `netbird service install` writes `/etc/systemd/system/netbird.service`, so a duty unit at that path makes the installer find itself, skip the real install, and deadlock starting the unit it is running inside.

`guest/startup.sh` is the GCE startup-script and provisions nothing itself.\
It materialises the three scripts and four units from metadata, then drives them.

Materialising before starting is what keeps a rebooted VM on the current module version rather than on whatever the last boot left behind.

They share no runtime state, so a config refresh cannot disturb k3s.

The bring-up entrypoint is fetched over HTTPS, not cloned.\
A clone needs `git` installed first, which a stock Rocky image lacks, and `curl` is already there. There is no ref to pin: `k3s_bootstrap_url` names what runs, and whatever it serves at boot is what the node gets.

It is downloaded to disk before executing rather than piped into a shell.\
A dropped connection mid-transfer leaves a truncated script and a shell runs what it already read, so the file is written to a temp sibling and moved into place only once whole.

---

## Env contract

`gce-env` writes the same values twice, for two different kinds of consumer.

| Path | Form | Consumer |
|---|---|---|
| `<env_file_path>` | bash `%q`, 0600 | root login shells, via `/etc/profile.d` |
| `/run/gce-env/env` | `EnvironmentFile=`, 0600 in a 0700 tmpfs dir | systemd units |

They are not interchangeable.\
systemd's parser does not understand bash ANSI-C quoting, so a `%q` value like `$'a\nb'` is silently mangled rather than rejected.

A multi-line value cannot be expressed in `EnvironmentFile=` at all, so it is published there as `NAME_B64` holding base64 - which is how a PEM key survives intact.

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
Add an entry to `env_metadata_map` or `env_secret_map` and it appears there on the next boot.

`k3s-bootstrap` already consumes it this way, which is what puts config in front of the bring-up entrypoint.

Concurrency, run-once and timeouts are the unit manager's job rather than hand-rolled: systemd will not run a unit twice at once, `ConditionPathExists` gates the re-run, and `TimeoutStartSec` bounds a hung bring-up so it cannot wedge the node.
