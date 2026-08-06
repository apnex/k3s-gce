# Read access to the Secret Manager containers the VM needs.
#
# This module CREATES NOTHING here. Every container in var.env_secret_map must
# already exist; the module only binds its VM service account as a reader on
# each one. Containers and their values are owned elsewhere - by a separate
# Terraform root (see examples/secrets) or out-of-band via gcloud.
#
# That is deliberate. A module that writes secret values makes those values pass
# through Terraform, which puts them in the plan file and in state as plaintext.
# Reading only means there is nothing to leak.
#
# The apply fails if a referenced container is missing. That is the intended
# loud failure: a VM cannot read a secret that does not exist, and finding out
# at apply time beats finding out from an empty env file at boot.
resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each  = local.secret_containers
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}
