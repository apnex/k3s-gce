# k3s-gce examples

Reference deployments for the module at the repo root.

**Status:** working - validated on a single deployment.

`hermes-vm/` stands up one k3s VM.\
`shared/` owns Secret Manager containers used by more than one deployment, which per-VM deployments then reference read-only.

These are templates, not deployments.\
They hold `*.tfvars.example` files and module wiring, never real values or state.\
You copy one into `env/`, which is gitignored in full, and fill it in there.

Assumes an authenticated `terraform` and `gcloud` against a GCP project, with `compute`, `iam`, `secretmanager`, and `serviceusage` admin rights.

Confirm the tooling before starting:
```
gcloud auth list && terraform version
```

---

## Install

Copy a reference into `env/` and supply your values:
```
cp -r examples/hermes-vm env/hermes-vm
cd env/hermes-vm
cp terraform.tfvars.example terraform.tfvars
cp secrets.auto.tfvars.example secrets.auto.tfvars
terraform init
terraform apply
```

`terraform.tfvars` carries deployment config and `secrets.auto.tfvars` carries secret values.\
Both are gitignored, as is the state file that ends up holding those secret values in plaintext.

A clean first apply runs in two phases while `enable_ssh_target_login` is true, and the login identity needs a grant only an org admin can issue.\
Both are part of the module contract in [`../README.md`](../README.md).

### shared secrets

Deploy `shared/` before any VM that references a shared scope.\
The module reads those containers and never creates them, so a VM applied first will fail on a missing secret.

```
cp -r examples/shared env/shared
cd env/shared
cp terraform.tfvars.example terraform.tfvars
cp secrets.auto.tfvars.example secrets.auto.tfvars
terraform init
terraform apply
```

---

## Use

`login.sh` reads the `ssh_command` output from state and connects over the IAP tunnel.

Open an interactive shell:
```
cd env/hermes-vm
./login.sh
```

Run a single command instead:
```
./login.sh --command='sudo tail -n 40 /var/log/k3s-gce-bootstrap.log'
```

---

## Test

Validate a reference with no values at all, straight from the repo:
```
terraform -chdir=examples/hermes-vm init -backend=false
terraform -chdir=examples/hermes-vm validate
```

Plan a real deployment, which needs values and so runs from `env/`:
```
terraform -chdir=env/hermes-vm init
terraform -chdir=env/hermes-vm plan
```

Confirm self-assembly reached a healthy cluster after an apply:
```
./login.sh --command='sudo /usr/local/bin/kubectl get nodes,sc'
```

---

## Remove

Destroy a deployment from its own directory:
```
cd env/hermes-vm
terraform destroy
```

Recreating a deployment mints a new `ssh-target` `unique_id`, which orphans the org-level OS Login grant.\
Re-grant it as described in [`../README.md`](../README.md).

---

## Layout

`examples/<name>/` is committed and holds templates only.\
`env/<name>/` is gitignored and holds your real values and state.

```
examples/hermes-vm/    reference: single k3s VM
examples/shared/       reference: cross-deployment secret containers
env/<name>/            your real deployments, never committed
```

Copy a different `examples/<name>` into `env/<name>` to run another workload.\
The module is app-agnostic, so the secret key list, each key's scope, and the env-file path all live in the deployment config rather than in the module.
