## SYN

Self-assembling, internal-only k3s VM on GCE.

Scope is the VM. Stands up:

- least-privilege Rocky 9 VM with OS Login, no public IP
- application secrets in Secret Manager, fetched into an env file on boot
- pod->host SSH login identity (optional)
- k3s self-assembly on first boot (optional)

The VPC, subnet, firewall rules, Cloud NAT and project API enablement are **not** in scope.
The module attaches to a subnetwork you already own.

Assumes an authenticated `terraform` and `gcloud` against a GCP project, with `compute`, `iam`, `secretmanager`, and `serviceusage` admin rights.

Confirm the tooling before starting:
```
gcloud auth list && terraform version
```

### prerequisites

You provide these. Two of them fail at **boot**, not at apply, so a green `terraform apply` is not proof they are right.

- **A subnetwork in `var.region`** - passed as `subnetwork`.
- **Private Google Access enabled on it.** The VM has no public IP, so this is what lets it reach Secret Manager, Cloud Logging and OS Login metadata. Without it the apply succeeds and the VM cannot fetch its secrets.
- **Outbound egress**, via Cloud NAT or equivalent, whenever `enable_k3s_bootstrap` is true. First boot clones the bring-up repo and downloads the k3s installer. Without it the apply succeeds and no cluster appears.
- **An IAP-SSH firewall rule** allowing `35.235.240.0/20` to `tcp:22`, targeting the module's `network_tags` output. Without it the VM is unreachable.
- **Enabled APIs**: `compute`, `iam`, `cloudresourcemanager`, `iap`, `logging`, `monitoring`, `secretmanager`.

`examples/hermes-vm/network.tf` is a working reference for all five.

### main.tf
```
locals {
	project_id	= "your-project-id"
	region		= "australia-southeast1"
	name_prefix	= "demo"
	secret_keys	= [
		{ key = "APP_TOKEN" },				# self   -> demo-APP_TOKEN
		{ key = "LLM_API_KEY", scope = "shared" }	# shared -> shared-LLM_API_KEY
	]
}

provider "google" {
	project	= local.project_id
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

	# an existing subnet you own -- see prerequisites
	subnetwork	= google_compute_subnetwork.subnet.id
}

# target the tags the module actually applied, so the two cannot drift
resource "google_compute_firewall" "allow_iap_ssh" {
	name		= "${local.name_prefix}-allow-iap-ssh"
	network		= google_compute_network.vpc.id
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

The `ssh-target` SA is out-of-domain, so OS Login treats it as external.\
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

Setting `enable_ssh_target_login` to false skips the login identity and both prerequisites above.\
Still pass the `google.ssh_login` alias - Terraform requires declared aliases to be wired even when unused.

```
enable_ssh_target_login = false
```

### notes

`startup.sh` is static and generic, parameterised entirely via VM metadata under `k3s-*` keys, with no Terraform templating.\
It is idempotent: secrets refresh every boot, and k3s self-assembly runs once, guarded by `/var/lib/k3s-gce-bootstrapped`.
