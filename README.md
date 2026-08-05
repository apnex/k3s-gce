## SYN

Self-assembling, internal-only k3s VM on GCE.
Stands up a custom VPC with IAP-SSH ingress and Cloud NAT egress, a least-privilege Rocky 9 VM with OS Login, application secrets in Secret Manager fetched into an env file on boot, an optional pod→host SSH login identity, and optional self-assembly of k3s on first boot.

Assumes an authenticated `terraform` and `gcloud` against a GCP project, with `compute`, `iam`, `secretmanager`, and `serviceusage` admin rights.

Confirm the tooling before starting:
```
gcloud auth list && terraform version
```

### main.tf
```
locals {
	project_id	= "your-project-id"
	region		= "australia-southeast1"
	name_prefix	= "hermes"
	secret_keys	= [
		{ key = "HERMES_TOKEN" },			# self   -> hermes-HERMES_TOKEN
		{ key = "OPENAI_API_KEY", scope = "kate" }	# shared -> kate-OPENAI_API_KEY
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

Containers are named `<scope>-<KEY>`.
A `self` scope — the default — is created by the module under `name_prefix`.
A shared label references an already-existing container read-only, and the module grants the VM SA read access without creating or writing it.

`secret_values` writes Secret Manager versions for self-scoped keys only.
Those values land in `terraform.tfstate` in plaintext, so treat state as sensitive.

### first apply

The `google.ssh_login` alias is required whenever `enable_ssh_target_login` is true, which is the default.
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

The `ssh-target` SA is out-of-domain, so OS Login treats it as external.
An org admin must grant it `compute.osLoginExternalUser` at the organization node — the role returns HTTP 400 if bound at project level.

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

### without pod→host SSH

Setting `enable_ssh_target_login` to false skips the login identity and both prerequisites above.
Still pass the `google.ssh_login` alias — Terraform requires declared aliases to be wired even when unused.

```
enable_ssh_target_login = false
```

### notes

`startup.sh` is static and generic, parameterised entirely via VM metadata under `k3s-*` keys, with no Terraform templating.
It is idempotent: secrets refresh every boot, and k3s self-assembly runs once, guarded by `/var/lib/k3s-gce-bootstrapped`.
