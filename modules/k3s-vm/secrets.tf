# Secret Manager containers for the VM's env injection. Containers are named
# `<secret_prefix>-<env_name>-<KEY>`. Values are supplied out-of-band (gcloud
# or var.secret_values); the VM startup script fetches them into the env file.

resource "google_secret_manager_secret" "this" {
  for_each  = local.all_secret_keys
  secret_id = "${local.secret_prefix}-${local.env_name}-${each.value}"

  replication {
    auto {}
  }

  labels = {
    env       = local.env_name
    managed   = "k3s-gce"
    component = local.secret_prefix
  }

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

# Optional value population from var.secret_values (typically a gitignored
# *.auto.tfvars). One SM version per map entry. Strict — indexing
# google_secret_manager_secret.this[each.key] fails at plan time if the key
# isn't in the container set (catches typos loudly).
resource "google_secret_manager_secret_version" "values" {
  for_each    = toset(nonsensitive(keys(var.secret_values)))
  secret      = google_secret_manager_secret.this[each.key].id
  secret_data = var.secret_values[each.key]
}

# Grant the VM SA read access to each container (startup.sh fetches via the
# VM SA on boot). Tightly scoped — secretAccessor on these secrets only.
resource "google_secret_manager_secret_iam_member" "vm_sa_accessor" {
  for_each  = google_secret_manager_secret.this
  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

# ── ssh-target keypair + OS Login registration (optional) ───────────
# Generated declaratively at apply — never on the operator's laptop. Key
# material lives in terraform.tfstate (treat state as sensitive).
resource "tls_private_key" "ssh_target" {
  count     = var.enable_ssh_target_login ? 1 : 0
  algorithm = "ED25519"
}

# Register the pubkey to the ssh-target SA's OS Login profile, via the
# impersonating provider (importSshPublicKey is self-only).
resource "google_os_login_ssh_public_key" "ssh_target" {
  count = var.enable_ssh_target_login ? 1 : 0

  provider   = google.ssh_login
  user       = google_service_account.ssh_target[0].email
  project    = var.project_id
  key        = tls_private_key.ssh_target[0].public_key_openssh
  depends_on = [google_service_account_iam_member.tf_impersonate_ssh_target]
}

# Private key → SSH_TARGET_KEY version.
resource "google_secret_manager_secret_version" "ssh_target_key" {
  count       = var.enable_ssh_target_login ? 1 : 0
  secret      = google_secret_manager_secret.this["SSH_TARGET_KEY"].id
  secret_data = tls_private_key.ssh_target[0].private_key_openssh
}

# SSH_TARGET_USER = the SA's OS Login POSIX username (deterministically
# sa_<numeric-unique-id>). The in-pod wrapper normalises this non-root login
# to sudo.
resource "google_secret_manager_secret_version" "ssh_target_user" {
  count       = var.enable_ssh_target_login ? 1 : 0
  secret      = google_secret_manager_secret.this["SSH_TARGET_USER"].id
  secret_data = "sa_${google_service_account.ssh_target[0].unique_id}"
}
