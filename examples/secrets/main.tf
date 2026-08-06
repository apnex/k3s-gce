# Secret Manager containers for k3s-gce deployments to READ.
#
# The module creates nothing in Secret Manager - it only grants its VM read
# access to containers that already exist. This root is where they come from:
# one writer, many readers.
#
# Container names are written out in full, exactly as they will exist. The name
# you put here is the name a VM puts in its env_secret_map, with no derivation
# in between:
#
#     secrets        = { "shared-llm-api-key" = "sk-..." }   # here
#     env_secret_map = { LLM_API_KEY = "shared-llm-api-key" } # in ../vm
#
# Values are written with secret_data_wo, a write-only argument. Terraform sends
# it to the API and never records it as a resource attribute, so it stays out of
# STATE. That is the point: state is the long-lived artifact, and this keeps it
# ordinary rather than a credential store. It is why required_version is 1.11
# rather than 1.5.
#
# It does NOT cover a saved plan file. `terraform plan -out=` records the input
# VARIABLE values so that apply can reuse them, so var.secrets appears there in
# cleartext under .variables even though the resource attribute is null. Do not
# save plans from this root, or treat the file as a secret if you do.
#
# Write-only values cannot be diffed, because Terraform does not keep the old
# one to compare against. Revisions are therefore explicit: bump
# var.secrets_version to write a new version of every container.

terraform {
  required_version = ">= 1.11"

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
  # for_each keys cannot derive from a sensitive value, and only the values here
  # are sensitive - the container names are not.
  names = toset(nonsensitive(keys(var.secrets)))
}

resource "google_secret_manager_secret" "this" {
  for_each  = local.names
  secret_id = each.value

  replication {
    auto {}
  }

  labels = {
    managed = "k3s-gce"
  }
}

resource "google_secret_manager_secret_version" "this" {
  for_each = local.names
  secret   = google_secret_manager_secret.this[each.key].id

  secret_data_wo         = var.secrets[each.key]
  secret_data_wo_version = var.secrets_version
}
