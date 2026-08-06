# k3s-gce examples

Three roots, one duty each.

```
examples/network/   VPC, subnet with Private Google Access, Cloud NAT, enabled APIs
examples/secrets/   Secret Manager containers and their values
examples/vm/        the k3s-gce module on a subnet you already own
env/<name>/         your real deployments, never committed
```

They compose. Apply only the ones you need:

```
empty project        network -> secrets -> vm
existing network                secrets -> vm
no secrets                                 vm
```

**Status:** working - validated on a single deployment.

The module's scope is the VM alone.\
It builds no network and creates no Secret Manager container, so `network/` and `secrets/` supply what it expects to already exist. The routing pieces fail at **boot** rather than at apply, so read [`../README.md`](../README.md) before pointing `vm/` at a subnet of your own.

These are templates, not deployments.\
They hold `*.tfvars.example` files and module wiring, never real values or state. You copy one into `env/`, which is gitignored in full, and fill it in there.

Assumes an authenticated `terraform` and `gcloud` against a GCP project, with `compute`, `iam`, `secretmanager`, and `serviceusage` admin rights.

Confirm the tooling before starting:
```
gcloud auth list && terraform version
```

`secrets/` needs Terraform 1.11 or later for write-only arguments. The other two need 1.5.

---

## Install

Order matters. Each root consumes what the one before it produced.

### 1. network - only on an empty project

Skip this entirely if you already own a subnet.
```
cp -r examples/network env/network
cd env/network
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

The `subnet_name` output is what `vm/` wants. The subnet has Private Google Access and a Cloud NAT, which are what let a VM with no public IP reach Secret Manager and the k3s installer respectively.

### 2. secrets - only if the VM needs any

```
cp -r examples/secrets env/secrets
cd env/secrets
cp terraform.tfvars.example terraform.tfvars
cp secrets.auto.tfvars.example secrets.auto.tfvars
terraform init
terraform apply
```

Container names are written in full, exactly as they will exist:
```
secrets = { "shared-llm-api-key" = "sk-..." }
```

That string is what a VM puts on the right-hand side of its `env_secret_map`. Nothing is derived, so nothing has to be reconstructed.

Values use `secret_data_wo`, a write-only argument. Terraform sends it to the API and never records it as a resource attribute, so it stays out of **state** - the long-lived artifact. Write-only values cannot be diffed, so bump `secrets_version` to write a new version of every container.

It does not cover a saved plan. `terraform plan -out=` records input variable values so apply can reuse them, so `secrets` appears there in cleartext under `.variables` even though the resource attribute is null. Don't save plans from this root.

`gcloud secrets create` works just as well. What matters is that the container exists and that its writer is somewhere other than the VM deployment.

### 3. vm

```
cp -r examples/vm env/vm
cd env/vm
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

`terraform.tfvars` carries the deployment config, including `subnet_name` and `env_secret_map`. There is no `secrets.auto.tfvars` here - no secret value passes through this root, so its state holds nothing sensitive.

This root owns the IAP-SSH firewall rule, because that rule targets the module's `network_tags` output and cannot be written without it.

A VM applied against a container that does not exist fails at apply with a clear error, which is the intended loud failure.

---

## Use

`login.sh` reads the `ssh_command` output from state and connects over the IAP tunnel.

Open an interactive shell:
```
cd env/vm
./login.sh
```

Run a single command instead:
```
./login.sh --command='sudo journalctl -u gce-env -u k3s-bootstrap -n 40'
```

---

## Test

Validate a reference with no values at all, straight from the repo:
```
terraform -chdir=examples/vm init -backend=false
terraform -chdir=examples/vm validate
```

Plan a real deployment, which needs values and so runs from `env/`:
```
terraform -chdir=env/vm init
terraform -chdir=env/vm plan
```

Confirm self-assembly reached a healthy cluster after an apply:
```
./login.sh --command='sudo /usr/local/bin/kubectl get nodes,sc'
```

### smoke test without installing k3s

Create a `K3S_DRYRUN` container holding any non-empty value, and map it:
```
printf 1 | gcloud secrets create k3s-dryrun --data-file=-
```
```
env_secret_map = { K3S_DRYRUN = "k3s-dryrun" }
```

`k3s/up` reads it after computing its plan and exits before running a single module, so nothing is installed - but the value had to cross the entire delivery chain to be read at all:

```
Secret Manager -> env.sh -> /run/gce-env/env -> EnvironmentFile= -> k3s-bootstrap.service -> k3s.sh -> k3s/up
```

Confirm the chain end to end:
```
./login.sh --command='sudo journalctl -u gce-env -u k3s-bootstrap --no-pager'
```

Look for `+ K3S_DRYRUN: written` from `gce-env`, then `[ K3S/UP ] dry-run - exiting before execution` from `k3s-bootstrap`.

A dry run exits 0, so the run-once marker is written and later boots skip the unit.\
Clear it when you want the real install:
```
./login.sh --command='sudo rm -f /root/k3s-gce/bootstrapped && sudo systemctl start k3s-bootstrap'
```

`K3S_DRYRUN` is a test lever, not a brake.\
`k3s-bootstrap.service` is ordered `After=gce-env.service` but does not `Require=` it, and its `EnvironmentFile=` carries the leading `-` that tolerates a missing file - so if secret injection fails, the variable is simply absent and the real install proceeds.

---

## Remove

Destroy in reverse order, since each root depends on the one before it:
```
cd env/vm      && terraform destroy
cd env/secrets && terraform destroy
cd env/network && terraform destroy
```

---

## Layout

`examples/<name>/` is committed and holds templates only.\
`env/<name>/` is gitignored and holds your real values and state.

The module is app-agnostic, so the secret mapping, the env-file path, and the k3s repo all live in the deployment config rather than in the module. Copy `examples/vm` again under a different `name_prefix` to run a second workload against the same network and secrets.
