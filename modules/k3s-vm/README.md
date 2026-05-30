# `k3s-vm`

Terraform module for an internal-only, self-assembling k3s VM on GCE.

Stands up a custom VPC with IAP-SSH ingress and Cloud NAT egress, a least-privilege Rocky 9 VM with OS Login, application secrets in Secret Manager fetched into an env file on boot, an optional pod→host SSH login identity, and optional self-assembly of k3s on first boot.

The module is app-agnostic: secret names, the env-file path, and the k3s bring-up repo are all inputs.

---

## Usage

```hcl
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google" {
  alias                       = "ssh_login"
  project                     = var.project_id
  region                      = var.region
  impersonate_service_account = "${var.name_prefix}-ssh-target@${var.project_id}.iam.gserviceaccount.com"
}

module "k3s_vm" {
  source = "github.com/apnex/k3s-gce//modules/k3s-vm"

  providers = {
    google           = google
    google.ssh_login = google.ssh_login
  }

  project_id  = "my-project"
  name_prefix = "demo"
  secret_keys = ["MY_API_KEY"]
}
```

The `google.ssh_login` aliased provider is required whenever `enable_ssh_target_login = true` (the default). It must impersonate the `${name_prefix}-ssh-target` service account so the OS Login key can be registered as that SA (`importSshPublicKey` is self-only). When `enable_ssh_target_login = false`, still pass the alias — Terraform requires declared aliases to be wired even if unused.

---

## Inputs

| Name | Default | Description |
|---|---|---|
| `project_id` | — | GCP project ID |
| `region` / `zone` | `australia-southeast1` / `-a` | location |
| `name_prefix` | `k3s` | prefix for all resource names |
| `machine_type` | `e2-medium` | VM size |
| `boot_disk_image` / `boot_disk_size_gb` | `rocky-linux-cloud/rocky-linux-9` / `20` | boot disk |
| `vpc_cidr` | `10.20.0.0/24` | subnet CIDR |
| `apis` | 7 core APIs | project services to enable |
| `vm_roles` | logging + monitoring writers | VM runtime SA roles |
| `secret_prefix` | `name_prefix` | SM container prefix (null → name_prefix) |
| `env_name` | `name_prefix` | env segment of SM names |
| `secret_keys` | `[]` | app secret KEYS (ssh-target keys added automatically) |
| `secret_values` | `{}` (sensitive) | optional KEY → value map → SM versions (validated ⊆ secret_keys) |
| `env_file_path` | `/root/<name_prefix>.env` | where startup writes the sourced env (null → derived) |
| `enable_ssh_target_login` | `true` | provision the pod→host OS Login identity |
| `enable_k3s_bootstrap` | `true` | self-assemble k3s on first boot |
| `k3s_repo_url` / `k3s_repo_ref` / `k3s_up_entrypoint` | apnex/labops / `master` / `k3s/up` | bring-up source |

Secret Manager containers are named `<secret_prefix>-<env_name>-<KEY>`.

---

## Outputs

| Name | Description |
|---|---|
| `vm_name` | Name of the k3s VM |
| `vm_internal_ip` | Static internal IP of the VM |
| `vm_zone` | Zone the VM lives in |
| `vm_sa_email` | Email of the VM runtime service account |
| `ssh_command` | IAP-tunnel `gcloud compute ssh` command |
| `ssh_target_sa_email` | Inbound SSH login SA (null when disabled); the org-level grants attach here |
| `ssh_target_user` | OS Login POSIX username the in-pod wrapper logs in as (null when disabled) |

---

## Org-level prerequisite (pod→host SSH)

The `ssh-target` SA is out-of-domain (`@gserviceaccount.com`), so OS Login treats it as external. Beyond what this module grants at the project (`compute.osAdminLogin`) and on the SA resource (`iam.serviceAccountUser`), an **org admin** must grant the SA, at the organization node:

```sh
gcloud organizations add-iam-policy-binding <ORG_ID> \
  --member="serviceAccount:$(terraform output -raw ssh_target_sa_email)" \
  --role="roles/compute.osLoginExternalUser"
```

`compute.osLoginExternalUser` **cannot** be bound at project level (the API returns HTTP 400). After granting, the guest agent caches OS Login authz — `systemctl restart google-guest-agent` (or reboot) before testing. Recreating the SA mints a new `unique_id` and orphans this grant, so re-grant after any destroy/recreate of the identity.

---

## Notes

`startup.sh` is a static, generic bash script parameterised entirely via VM metadata (`k3s-*` keys) — no Terraform templating. It is idempotent: secrets refresh every boot; k3s self-assembly runs once, guarded by `/var/lib/k3s-gce-bootstrapped`.
