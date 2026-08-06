terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

locals {
  region = replace(var.zone, "/-[a-z]$/", "")

  # NetBird names a peer after the hostname it is given, and keeps the old peer
  # for a while after a VM dies. Redeploy inside that window and the new peer
  # collides with the corpse of the last one - NetBird disambiguates by
  # suffixing, so the FQDN this root predicts would resolve to a peer that no
  # longer exists. A per-deployment suffix means the two can never be confused.
  netbird_hostname = "${var.name_prefix}-${random_id.peer.hex}"

  # NETBIRD_HOSTNAME is plain config, so it rides the same env_metadata_map the module
  # already delivers - no module input needed, since netbird/prepare reads it
  # from the environment. Merged as the BASE so an explicit value in
  # var.env_metadata_map still wins.
  env_metadata_map = var.enable_netbird ? merge({ NETBIRD_HOSTNAME = local.netbird_hostname }, var.env_metadata_map) : var.env_metadata_map
}

# Four hex characters, regenerated only when this deployment is destroyed and
# rebuilt. Stable across applies, so a re-apply does not rename the peer and
# force it to re-register.
resource "random_id" "peer" {
  byte_length = 2
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

  subnetwork       = data.google_compute_subnetwork.target.id
  env_secret_map   = var.env_secret_map
  env_metadata_map = local.env_metadata_map
  env_file_path    = var.env_file_path

  enable_k3s_bootstrap = var.enable_k3s_bootstrap
  k3s_bootstrap_url    = var.k3s_bootstrap_url

  enable_netbird        = var.enable_netbird
  netbird_bootstrap_url = var.netbird_bootstrap_url

  root_ssh_key = tls_private_key.root.public_key_openssh
}

# A fresh root key per deployment. The VM is disposable and so is its key: a
# destroy/apply cycle rotates it, and nothing outlives the instance.
#
# The private half is written beside netbird-login.sh AND recorded in this
# root's terraform.tfstate. State is already gitignored and local-only, the
# same protection ~/.ssh has, so this is a second copy rather than a new
# exposure - but it does mean a root credential travels with the state file if
# this root ever moves to a remote backend.
resource "tls_private_key" "root" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "root_key" {
  filename        = "${path.module}/netbird-id"
  content         = tls_private_key.root.private_key_openssh
  file_permission = "0600"
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
