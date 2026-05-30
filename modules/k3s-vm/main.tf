# k3s-vm — a reusable, internal-only k3s VM on GCE.
#
# Stands up: custom VPC + IAP-SSH + Cloud NAT, a least-privilege Rocky VM with
# OS Login, app secrets in Secret Manager fetched into an env file on boot, an
# optional pod→host SSH login identity, and optional self-assembly of k3s.
#
# App-agnostic: the secret names, env-file path, and k3s repo are all inputs.

resource "google_project_service" "apis" {
  for_each = toset(var.apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

locals {
  # App-neutral default — derived from name_prefix, no embedded app identity.
  env_file_path = coalesce(var.env_file_path, "/root/${var.name_prefix}.env")

  # The module owns the ssh-target keys when login is enabled — operators must
  # NOT list them in var.secret_keys. Always self-scoped: a host key is
  # intrinsically per-VM and never shared. USER + KEY get values (secrets.tf);
  # HOST is a container with no version on purpose (the in-pod wrapper falls
  # back to the node IP via the Downward API when SSH_TARGET_HOST is unset).
  ssh_target_keys = var.enable_ssh_target_login ? [
    { key = "SSH_TARGET_USER", scope = "self" },
    { key = "SSH_TARGET_HOST", scope = "self" },
    { key = "SSH_TARGET_KEY", scope = "self" },
  ] : []

  # Normalise every requested key into its container name. scope "self" → the
  # VM's own prefix (name_prefix); any other label → a shared container.
  # Container name is `<scope-or-name_prefix>-<KEY>`.
  keyed = {
    for e in concat(var.secret_keys, local.ssh_target_keys) : e.key => {
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
