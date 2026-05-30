# Dedicated least-privilege VM runtime service account + optional inbound SSH
# login identity (used by an in-pod wrapper to reach the host via OS Login).

resource "google_service_account" "vm" {
  account_id   = "${var.name_prefix}-vm-sa"
  display_name = "k3s VM runtime (${var.name_prefix})"
  description  = "Runtime SA for the internal-only k3s VM"
}

resource "google_project_iam_member" "vm_roles" {
  for_each = toset(var.vm_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# ── Inbound SSH login identity (OS Login) ───────────────────────────
# Optional. Distinct from the VM runtime SA: this identity only logs IN, it
# never runs the VM or reads secrets. The keypair is in secrets.tf; its pubkey
# is registered to this SA's OS Login profile and the pod lands as sa_<id>.
resource "google_service_account" "ssh_target" {
  count = var.enable_ssh_target_login ? 1 : 0

  account_id   = "${var.name_prefix}-ssh-target"
  display_name = "Inbound SSH login identity for the in-pod ssh-target wrapper"
  description  = "OS Login identity the bot lands as on the host; not the VM runtime SA"
}

# osAdminLogin = login + passwordless sudo (google-sudoers). The in-pod wrapper
# normalises the non-root sa_<id> login to sudo for privilege.
resource "google_project_iam_member" "ssh_target_oslogin" {
  count = var.enable_ssh_target_login ? 1 : 0

  project = var.project_id
  role    = "roles/compute.osAdminLogin"
  member  = "serviceAccount:${google_service_account.ssh_target[0].email}"
}

# ORG-LEVEL PREREQUISITES (NOT manageable here — only an org admin can grant).
# The ssh-target SA is out-of-domain (@gserviceaccount.com), so OS Login also
# requires, AT THE ORG NODE:
#   - roles/compute.osLoginExternalUser   (permits the external identity;
#       cannot be bound at project level — the API returns HTTP 400)
#   - roles/iam.serviceAccountUser        (actAs — to log in AS the SA)
# The serviceAccountUser grant below is the tighter, TF-owned self-binding;
# whether it fully substitutes for an org-level grant depends on the org. See
# the module README. With those + osAdminLogin + the registered key, the pod
# logs in as sa_<unique_id> with sudo.

# Identity of the active provider credentials, so we can let it impersonate the
# ssh-target SA to register the OS Login key AS that SA.
data "google_client_openid_userinfo" "provider" {
  count = var.enable_ssh_target_login ? 1 : 0
}

resource "google_service_account_iam_member" "tf_impersonate_ssh_target" {
  count = var.enable_ssh_target_login ? 1 : 0

  service_account_id = google_service_account.ssh_target[0].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${data.google_client_openid_userinfo.provider[0].email}"
}

# actAs on ITSELF: logging in as the SA via OS Login is an actAs op. Granted on
# the SA resource (tightest scope) rather than the org.
resource "google_service_account_iam_member" "ssh_target_self_user" {
  count = var.enable_ssh_target_login ? 1 : 0

  service_account_id = google_service_account.ssh_target[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.ssh_target[0].email}"
}
