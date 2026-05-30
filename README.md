# `k3s-gce`

Reusable Terraform for a self-assembling, internal-only k3s VM on GCE — deploy it many times, identically.

**Status:** working — validated on a single deployment. Targets GCP; Rocky 9 guest, single-node k3s.

Prerequisites: a GCP project and authenticated `terraform` + `gcloud` (or a service-account key). The deploying identity needs project owner, or the equivalent compute / iam / secretmanager / serviceusage admin roles. Terraform version floor is pinned in `versions.tf`.

Confirm your tooling is ready before starting:
```sh
gcloud auth list && terraform version
```

---

## Install

Copy a reference example into `env/`, fill in your values, and apply:
```sh
cp -r examples/hermes-vm env/hermes-vm
cd env/hermes-vm
cp terraform.tfvars.example terraform.tfvars            # deployment config
cp secrets.auto.tfvars.example secrets.auto.tfvars      # secret values
terraform init
terraform apply
```

All `*.tfvars` and state are gitignored under `env/` — config, secret values, and state never leave your machine, since the repo is cloned by many people.
With `enable_k3s_bootstrap = true` (the default), the VM clones the bring-up repo and stands up k3s on first boot — no manual steps.

### First apply with `enable_ssh_target_login`

When the pod→host SSH identity is enabled (the default), the `google.ssh_login` provider impersonates the `ssh-target` service account that the same apply creates — and a provider cannot `depend_on` a resource, so a clean from-scratch apply can fail on the OS Login key registration until the SA and its `tokenCreator` grant exist and propagate.
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

SSH in over the IAP tunnel (run from your deployment dir under `env/`):
```sh
cd env/hermes-vm
./login.sh
```

Inspect the boot log and the cluster:
```sh
./login.sh --command='sudo tail -n 40 /var/log/k3s-gce-bootstrap.log'
./login.sh --command='sudo /usr/local/bin/kubectl get nodes'
```

For pod→host SSH, an org admin grants the org-level role to the login SA once:
```sh
gcloud organizations add-iam-policy-binding <ORG_ID> \
  --member="serviceAccount:$(terraform output -raw ssh_target_sa_email)" \
  --role="roles/compute.osLoginExternalUser"
```

---

## Test

Validate the reference example without applying (no values needed):
```sh
terraform -chdir=examples/hermes-vm init -backend=false
terraform -chdir=examples/hermes-vm validate
```

Plan your real deployment (needs values, so run from `env/`):
```sh
terraform -chdir=env/hermes-vm init
terraform -chdir=env/hermes-vm plan
```

After apply, confirm self-assembly reached a healthy cluster:
```sh
./login.sh --command='sudo /usr/local/bin/kubectl get nodes,sc; sudo /usr/local/bin/kubectl -n metallb-system get pods'
```

---

## Remove

```sh
cd env/hermes-vm
terraform destroy
```

Recreating the deployment mints a new `ssh-target` SA `unique_id`, which orphans the org-level OS Login grant — re-grant `compute.osLoginExternalUser` after a destroy/recreate (see `modules/k3s-vm/README.md`).

---

## Repo layout

```text
modules/k3s-vm/      reusable module (the substrate)
examples/<name>/     committed REFERENCE — templates + wiring, placeholder values only
env/<name>/          your real deployments — gitignored, local-only (never committed)
```

`examples/<name>/` is the reference you copy *from*; it holds only `*.example` templates and the module wiring, never real values or state.
`env/<name>/` is where a real deployment lives — real `terraform.tfvars`, real state — and the entire `env/` tree is gitignored.

A second reference, `examples/shared/`, owns secrets shared across deployments (e.g. an LLM proxy's credentials); per-VM deployments reference those read-only.

---

## Notes

- **State and all tfvars are sensitive + local-only.** `terraform.tfstate` holds plaintext secret values; `*.tfvars` hold per-deployment config and secrets. All live under the gitignored `env/` tree; only `*.tfvars.example` templates are committed. There is no remote backend by default.
- **App-agnostic module.** Deployment specifics — the secret key list, each key's scope, and the env-file path — live in the deployment config, not the module. Copy a different `examples/<name>` into `env/<name>` to deploy another workload.
- **Secret scoping.** Each secret key is scoped `self` (a per-VM container the module creates) or to a shared label (a container the module references read-only, owned by `examples/shared`). See `modules/k3s-vm/README.md` for the full input/output contract.
