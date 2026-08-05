# Dedicated least-privilege VM runtime service account.

resource "google_service_account" "vm" {
  account_id   = "${var.name_prefix}-vm-sa"
  display_name = "k3s VM runtime (${var.name_prefix})"
  description  = "Runtime SA for the k3s VM"
}

# No project-level IAM is granted to this SA. The VM reads its secrets through
# per-secret accessor bindings (secrets.tf), which is the only authorisation it
# needs. Callers wanting to grant it more can use the vm_sa_email output.
