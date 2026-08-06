# k3s-gce - a reusable k3s VM on GCE.
#
# Scope is the VM: a least-privilege Rocky instance with OS Login, app secrets
# READ from Secret Manager into an env file on boot, and optional self-assembly
# of k3s.
#
# NOT in scope: the VPC, subnet, firewall rules, Cloud NAT, and project API
# enablement. Those belong to the project/network layer and are caller
# prerequisites (see README). The module attaches to an existing subnetwork.
#
# NOT in scope either: creating or writing Secret Manager containers. The module
# is a pure READER - it grants its VM read access to containers you already own
# and never creates, writes or destroys one. No secret value passes through
# Terraform, so none can land in state.
#
# App-agnostic: the secret mapping, env-file path, and k3s repo are all inputs.

locals {
  # A GCE zone is always "<region>-<letter>", so the region is derivable and
  # need not be an input. Deriving it also guarantees the static internal IP
  # lands in the same region as the instance.
  region = replace(var.zone, "/-[a-z]$/", "")

  # App-neutral default - derived from name_prefix, no embedded app identity.
  env_file_path = coalesce(var.env_file_path, "/root/${var.name_prefix}.env")

  # Tags the caller's IAP-SSH firewall rule must target. Defaulted from
  # name_prefix (a variable cannot be interpolated into a variable default) and
  # exported as an output so the caller wires its rule to what was applied.
  network_tags = coalesce(var.network_tags, ["${var.name_prefix}-vm"])

  # "ENV:container,ENV:container,..." for the guest. env.sh fetches by container
  # name and writes the bare ENV=value, so Terraform owns the mapping and bash
  # owns none of it. Sorted for a stable metadata value across plans.
  env_secret_map_csv = join(",", sort([for env, container in var.env_secret_map : "${env}:${container}"]))

  # Distinct containers to grant read on. Two env names may point at the same
  # container; without the dedupe that would be two IAM bindings on one secret,
  # which is a duplicate-resource error rather than a merge.
  secret_containers = toset(values(var.env_secret_map))

  # One metadata key per plain variable, not a packed list. A packed form needs
  # a delimiter and a plain value may contain any byte -- commas, quotes,
  # newlines. env-secret-map can stay packed only because container names
  # cannot contain a comma or a colon. env.sh discovers these by filtering the
  # metadata attribute index for the prefix.
  env_var_metadata = { for name, value in var.env_map : "env-var-${name}" => value }
}
