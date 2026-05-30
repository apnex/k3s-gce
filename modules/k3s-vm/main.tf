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
  # Generic defaults derived from name_prefix when the caller leaves them null,
  # so the module carries no app-specific identity (kate, hermes, …).
  env_name      = coalesce(var.env_name, var.name_prefix)
  secret_prefix = coalesce(var.secret_prefix, var.name_prefix)
  env_file_path = coalesce(var.env_file_path, "/root/${var.name_prefix}.env")

  # The module owns the ssh-target keys when login is enabled — operators must
  # NOT list them in var.secret_keys. USER + KEY get values (below); HOST is a
  # container with no version on purpose (the in-pod wrapper falls back to the
  # node IP via the Downward API when SSH_TARGET_HOST is unset).
  ssh_target_keys = var.enable_ssh_target_login ? ["SSH_TARGET_USER", "SSH_TARGET_HOST", "SSH_TARGET_KEY"] : []

  # Full set of SM containers to create.
  all_secret_keys = toset(concat(var.secret_keys, local.ssh_target_keys))
}
