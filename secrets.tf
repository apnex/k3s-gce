# Secret Manager containers for the VM's env injection. Containers are named
# `<scope>-<KEY>` (see locals in main.tf). SELF-scoped containers are created
# here; SHARED-scoped ones are assumed to already exist and are only granted
# read access. Values are supplied out-of-band (gcloud or var.secret_values);
# the VM startup script fetches them into the env file.

# SELF-scoped containers — created and owned by this deployment.
resource "google_secret_manager_secret" "this" {
  for_each  = local.self_keys
  secret_id = each.value

  replication {
    auto {}
  }

  labels = {
    managed = "k3s-gce"
    owner   = var.name_prefix
  }
}

# Optional value population from var.secret_values (typically a gitignored
# *.auto.tfvars). One SM version per map entry, into the SELF-scoped container.
# Strict — indexing google_secret_manager_secret.this[each.key] fails at plan
# time if the key is shared or undeclared (catches misplaced values loudly).
resource "google_secret_manager_secret_version" "values" {
  for_each    = toset(nonsensitive(keys(var.secret_values)))
  secret      = google_secret_manager_secret.this[each.key].id
  secret_data = var.secret_values[each.key]
}

# Grant the VM SA read access to SELF-scoped containers (created above).
resource "google_secret_manager_secret_iam_member" "self_accessor" {
  for_each  = google_secret_manager_secret.this
  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

# Grant the VM SA read access to SHARED containers. These are NOT created here —
# they must already exist (created out-of-band or by a separate deployment). The
# apply errors if a referenced shared container is missing, which is the
# intended loud failure: a VM cannot read a shared secret that doesn't exist.
resource "google_secret_manager_secret_iam_member" "shared_accessor" {
  for_each  = local.shared_keys
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}
