terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

locals {
  region = replace(var.zone, "/-[a-z]$/", "")
}

provider "google" {
  project     = var.project_id
  region      = local.region
  credentials = var.credentials_file != null ? file(var.credentials_file) : null
}

data "google_compute_subnetwork" "target" {
  name   = var.subnet_name
  region = local.region
}

module "k3s_gce" {
  source = "../.."

  project_id  = var.project_id
  zone        = var.zone
  name_prefix = var.name_prefix

  subnetwork     = data.google_compute_subnetwork.target.id
  env_secret_map = var.env_secret_map
  env_map        = var.env_map
  env_file_path  = var.env_file_path

  enable_k3s_bootstrap = var.enable_k3s_bootstrap
  k3s_bootstrap_url    = var.k3s_bootstrap_url

  enable_netbird        = var.enable_netbird
  netbird_bootstrap_url = var.netbird_bootstrap_url
}

resource "google_compute_firewall" "allow_iap_ssh" {
  name        = "${var.name_prefix}-allow-iap-ssh"
  network     = data.google_compute_subnetwork.target.network
  direction   = "INGRESS"
  description = "IAP-tunnel SSH to the ${var.name_prefix} k3s VM"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = module.k3s_gce.network_tags
}
