# Shared secrets — containers referenced by MULTIPLE k3s-gce deployments.
#
# One writer, many readers: this root OWNS the shared containers + their values;
# per-VM envs (env/<name>/) only REFERENCE them (the k3s-vm module grants their
# VM SA read access via a secret_keys entry with scope = this label).
#
# Container naming matches the module: `<scope-label>-<KEY>`. The label here is
# var.scope (default "kate"); a VM shares a secret by listing
# { key = "<KEY>", scope = "kate" } in its secret_keys.

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project     = var.project_id
  region      = var.region
  credentials = var.credentials_file != null ? file(var.credentials_file) : null
}

locals {
  # KEY → container name (`<scope>-<KEY>`), for the keys that have values.
  # nonsensitive() on the KEY names — only the values are sensitive, and Terraform
  # forbids deriving for_each/instance keys from a sensitive value.
  containers = { for k in nonsensitive(keys(var.secret_values)) : k => "${var.scope}-${k}" }
}

# Shared containers — created and owned here.
resource "google_secret_manager_secret" "shared" {
  for_each  = local.containers
  secret_id = each.value

  replication {
    auto {}
  }

  labels = {
    managed = "k3s-gce"
    scope   = var.scope
  }
}

# One version per supplied value.
resource "google_secret_manager_secret_version" "shared" {
  for_each    = toset(nonsensitive(keys(var.secret_values)))
  secret      = google_secret_manager_secret.shared[each.key].id
  secret_data = var.secret_values[each.key]
}
