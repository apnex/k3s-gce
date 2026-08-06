# k3s-gce examples

Three roots, one duty each:
```
examples/network/   VPC, subnet with Private Google Access, Cloud NAT, enabled APIs
examples/secrets/   Secret Manager containers and their values
examples/vm/        the k3s-gce module on a subnet you already own
env/<name>/         your real deployments, never committed
```

They compose.

Apply only the ones you need:
```
empty project        network -> secrets -> vm
existing network                secrets -> vm
no secrets                                 vm
```

**Status:** working - each root applied and destroyed repeatedly against a live project.

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

Copy it into `env/` and apply:
```
cp -r examples/network env/network
cd env/network
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

The `subnet_name` output is what `vm/` wants. The subnet has Private Google Access and a Cloud NAT, which are what let a VM with no public IP reach Secret Manager and the k3s installer respectively.

### 2. secrets - only if the VM needs any

Copy it into `env/` and supply your values:
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

Values use `secret_data_wo`, a write-only argument. Terraform sends it to the API and never records it as a resource attribute, so it stays out of **state** - the long-lived artifact.

It does not cover a saved plan. `terraform plan -out=` records input variable values so apply can reuse them, so `secrets` appears there in cleartext under `.variables` even though the resource attribute is null. Don't save plans from this root.

### change detection

A write-only value cannot be diffed - Terraform keeps no copy of the old one - so editing `secrets` would otherwise produce `No changes` and be silently ignored.

Two mechanisms cover that, and neither puts a value in state.

| Detects | How | Reports as |
|---|---|---|
| you edited a value | salted hash drives `secret_data_wo_version` | a diff, per key |
| something else wrote the container | `check` on the remote version number | a warning |

Edit a value and only that container is rewritten. Nothing to bump.

The hash is salted by `secrets_salt`, and that is not decoration.\
Terraform's only memory between runs is state, so any change detection at all must persist a fingerprint there - that is what an etag is. An unsalted hash makes state a confirmation oracle: anyone holding the file can test a guessed value against it. Confirming a guess against a salted one needs the salt, which lives in the same gitignored tfvars as the value it protects.

Set `secrets_salt` once and leave it. Changing it rewrites every container, since every hash moves with it.

The `check` block covers what the hash cannot. The hash is computed from your config, never from the remote, so a `gcloud secrets versions add` behind Terraform's back is invisible to it. A metadata-only data source reads which version `latest` points at - no value is fetched, so none can land in state - and the check warns when that disagrees with the version Terraform created.

Rotating a value logs `assertion known after apply`. The new version number does not exist until it does, so the assertion cannot be evaluated at plan time. That is accurate, not a fault.

`gcloud secrets create` works just as well. What matters is that the container exists and that its writer is somewhere other than the VM deployment.

### 3. vm

Copy it into `env/` and supply your values:
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

Two ways in. `login.sh` reads the `ssh_command` output and connects over the IAP tunnel, authenticating through OS Login.\
`netbird-login.sh` connects as root over NetBird using the keypair this root generated, with no gcloud and no IAP - it needs only that your machine is on the same NetBird network.

The private key is written to `netbird-id` beside the script, at `0600`, and is also recorded in this root's state. Both are gitignored; treat the directory accordingly.

### netbird peers are disposable, so make the key ephemeral

A `terraform destroy` deletes the VM without the guest ever getting to deregister, so every cycle leaves a dead peer behind in your NetBird account.

Create the setup key with the **ephemeral peers** option enabled, and set its **auto-assigned groups** so registered peers land in the group your policies target.\
NetBird then removes a peer automatically after it has been offline for more than ten minutes, which matches this VM's lifecycle exactly and costs no code.

Auto-assigned groups matter for the same reason. Every apply registers a brand-new peer, so a peer added to a group by hand would need adding again on every cycle - and until it is, it is connected but every access rule targeting that group ignores it. Both properties belong to the key, so neither needs anything client-side.

Deregistering on shutdown is the obvious alternative and it is a trap.\
`ExecStop` and GCE shutdown scripts both fire on reboot as well as deletion, and systemd cannot tell the two apart. A reboot would deregister the peer while `netbird.done` still exists, so the duty skips on the next boot and the VM returns disconnected. Making that work means clearing the marker too, at which point every reboot mints a new peer with a new address - worse than the problem being solved.

An ephemeral key has no such issue: a reboot is well inside the ten-minute window, so the peer survives it.

### the peer name carries a per-deployment suffix

`vm/` names the peer `<name_prefix>-<4 hex>`, from a `random_id` regenerated only on destroy.

Ephemeral cleanup is not instant. Redeploy inside the ten-minute window and the new peer meets the corpse of the old one, and NetBird disambiguates by suffixing its own name - at which point the FQDN this root predicts resolves to a peer that no longer exists. The suffix means the two names can never collide in the first place.

It is stable across applies, so re-applying does not rename the peer and force it to re-register.

### the peer name is a search key, not an address

NetBird owns the final name and rewrites it at registration.\
A reusable setup key may register many machines, so it appends the address octets to keep names distinct - `k3stest-17c6` becomes `k3stest-17c6-68-183`. That happens after apply, so no Terraform output can state the final name.

`netbird-login.sh` therefore FINDS the peer instead of predicting it: it reads `netbird_peer_prefix` and matches it against the local peer list, then connects to the address it finds.

That works either way. A single-use key produces `k3stest-17c6` with no suffix and matches just the same, so switching key types changes nothing. It does not depend on DNS resolving anything either, and a failed join reports `no NetBird peer matching 'k3stest-17c6'` rather than a hostname error pointing nowhere near the cause.

Reusable is the better fit regardless: a single-use key needs regenerating and re-storing in Secret Manager on every deploy, which is the manual step the rest of this design removes.

Open an interactive shell:
```
cd env/vm
./login.sh
```

Run a single command instead:
```
./login.sh --command='sudo journalctl -u gce-env -u k3s-bootstrap -n 40'
./netbird-login.sh journalctl -u gce-env -u netbird-bootstrap -n 40
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

Set `K3S_DRYRUN` to any non-empty value. It is plain config, not a secret, so it goes in `env_map` and needs nothing in Secret Manager:
```
env_map = { K3S_DRYRUN = "1" }
```

`k3s/up` reads it after computing its plan and exits before running a single module, so nothing is installed - but the value had to cross the entire delivery chain to be read at all:
```
Secret Manager -> env.sh -> /run/gce-env/env -> EnvironmentFile= -> k3s-bootstrap.service -> bootstrap.sh -> k3s/up
```

Confirm the chain end to end:
```
./login.sh --command='sudo journalctl -u gce-env -u k3s-bootstrap --no-pager'
```

Look for `+ K3S_DRYRUN: written` from `gce-env`, then `[ K3S/UP ] dry-run - exiting before execution` from `k3s-bootstrap`.

A dry run exits 0, so the run-once marker is written and later boots skip the unit.\
Clear it when you want the real install:
```
./login.sh --command='sudo rm -f /root/k3s-gce/k3s.done && sudo systemctl start k3s-bootstrap'
```

`K3S_DRYRUN` is a test lever, not a brake.\
`k3s-bootstrap.service` is ordered `After=gce-env.service` but does not `Require=` it, and its `EnvironmentFile=` carries the leading `-` that tolerates a missing file - so if env injection fails, the variable is simply absent and the real install proceeds.

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
