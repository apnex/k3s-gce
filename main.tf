# k3s-gce - a reusable k3s VM on GCE.
#
# Scope is the VM: a least-privilege Rocky instance with OS Login, app secrets
# in Secret Manager fetched into an env file on boot, an optional pod->host SSH
# login identity, and optional self-assembly of k3s.
#
# NOT in scope: the VPC, subnet, firewall rules, Cloud NAT, and project API
# enablement. Those belong to the project/network layer and are caller
# prerequisites (see README). The module attaches to an existing subnetwork.
#
# App-agnostic: the secret names, env-file path, and k3s repo are all inputs.

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

  # Normalise every requested key into its container name. scope "self" → the
  # VM's own prefix (name_prefix); any other label → a shared container.
  # Container name is `<scope-or-name_prefix>-<KEY>`.
  keyed = {
    for e in var.secret_keys : e.key => {
      shared    = e.scope != "self"
      container = "${e.scope == "self" ? var.name_prefix : e.scope}-${e.key}"
    }
  }

  # self → module CREATES the container; shared → module only REFERENCES it
  # (read grant) and assumes it already exists. Maps are KEY => container.
  self_keys   = { for k, v in local.keyed : k => v.container if !v.shared }
  shared_keys = { for k, v in local.keyed : k => v.container if v.shared }

  # KEY:container pairs for startup.sh — it fetches by container name and
  # writes the bare KEY=value into the env file (TF owns naming, not bash).
  secret_map = join(",", sort([for k, v in local.keyed : "${k}:${v.container}"]))
}
