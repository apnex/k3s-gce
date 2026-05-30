# `k3s-gce`

Reusable Terraform for a self-assembling, internal-only **k3s VM on GCE** — deploy it many times, identically.

One module (`modules/k3s-vm`) provisions the network, a least-privilege Rocky 9 VM with OS Login, app secrets in Secret Manager, an optional pod→host SSH identity, and optional first-boot self-assembly of k3s.
Per-deployment configuration lives under `examples/`.

```text
modules/k3s-vm/      reusable module (the substrate)
examples/hermes-vm/  one deployment (the kate substrate)
```

---

## Install

Prerequisites: a GCP project, Terraform >= 1.5, and `gcloud` authenticated (or a service-account key JSON). The deploying identity needs project `owner` (or equivalent: compute / iam / secretmanager / serviceusage admin).

Copy both templates, fill in your values, and apply:
```sh
cd examples/hermes-vm
cp terraform.tfvars.example terraform.tfvars            # deployment config
cp secrets.auto.tfvars.example secrets.auto.tfvars      # secret values
terraform init
terraform apply
```

All `*.tfvars` are gitignored and local-only — both deployment config (`terraform.tfvars`) and secret values (`secrets.auto.tfvars`) are treated as sensitive, since the repo is cloned by many people.
Only the `*.tfvars.example` templates are committed.
With `enable_k3s_bootstrap = true` (default), the VM clones the bring-up repo and stands up k3s on first boot — no manual steps.

### First apply with `enable_ssh_target_login`

When the pod→host SSH identity is enabled (the default), the `google.ssh_login` provider impersonates the `ssh-target` service account that the same apply creates — a provider cannot `depend_on` a resource, so a clean from-scratch apply can fail on the OS Login key registration until the SA and its `tokenCreator` grant exist and propagate.
Do a two-phase first apply:
```sh
terraform apply \
  -target=module.k3s_vm.google_service_account.ssh_target \
  -target=module.k3s_vm.google_service_account_iam_member.tf_impersonate_ssh_target
terraform apply
```
Subsequent applies need only `terraform apply`.
Alternatively, set `enable_ssh_target_login = false` to skip the pod→host identity entirely.

---

## Use

SSH in over the IAP tunnel:
```sh
cd examples/hermes-vm
./login.sh
```

Inspect the boot log and the cluster:
```sh
./login.sh --command='sudo tail -n 40 /var/log/k3s-gce-bootstrap.log'
./login.sh --command='sudo /usr/local/bin/kubectl get nodes'
```

For pod→host SSH, grant the org-level role to the login SA (one-time, by an org admin):
```sh
gcloud organizations add-iam-policy-binding <ORG_ID> \
  --member="serviceAccount:$(terraform output -raw ssh_target_sa_email)" \
  --role="roles/compute.osLoginExternalUser"
```

---

## Test

Validate the configuration without applying:
```sh
terraform -chdir=examples/hermes-vm init -backend=false
terraform -chdir=examples/hermes-vm validate
terraform -chdir=examples/hermes-vm plan
```

After apply, confirm self-assembly reached a healthy cluster:
```sh
./login.sh --command='sudo /usr/local/bin/kubectl get nodes,sc; sudo /usr/local/bin/kubectl -n metallb-system get pods'
```

---

## Remove

```sh
cd examples/hermes-vm
terraform destroy
```

Recreating the deployment mints a new `ssh-target` SA `unique_id`, which orphans the org-level OS Login grant — re-grant `compute.osLoginExternalUser` after a destroy/recreate (see `modules/k3s-vm/README.md`).

---

## Notes

- **State and all tfvars are sensitive + local-only.** `terraform.tfstate` holds plaintext secret values; `*.tfvars` hold per-deployment config and secrets. All are gitignored; only `*.tfvars.example` templates are committed. There is no remote backend by default.
- **App-agnostic module.** The kate specifics (`secret_prefix = "kate"`, the LiteLLM/Discord key list, `/root/kate.env`) live in `examples/hermes-vm`, not the module. Add a new `examples/<name>` to deploy a different workload.
- See `modules/k3s-vm/README.md` for the full input/output contract.
