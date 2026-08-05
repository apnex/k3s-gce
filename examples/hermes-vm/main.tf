# Example: a hermes kate substrate deployment.
#
# Instantiates the k3s-gce module with kate-flavored secret naming. All
# deployment-specific, non-secret config lives in terraform.tfvars; secret
# VALUES go in a gitignored secrets.auto.tfvars (see the .example).

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

module "k3s_gce" {
  source = "../.."

  project_id = var.project_id
  # No region input - the module derives it from zone.
  zone        = var.zone
  name_prefix = var.name_prefix

  # The module no longer creates networking - it attaches to this subnet.
  subnetwork = google_compute_subnetwork.subnet.id

  secret_keys   = var.secret_keys
  secret_values = var.secret_values
  env_file_path = var.env_file_path

  enable_k3s_bootstrap = var.enable_k3s_bootstrap
  k3s_repo_url         = var.k3s_repo_url
  k3s_repo_ref         = var.k3s_repo_ref
}
