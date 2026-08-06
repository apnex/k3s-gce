# The network prerequisites the k3s-gce module expects you to already have.
#
# The module deploys the VM only. This root is the reference for everything it
# assumes exists: enabled APIs, a VPC, a subnet with Private Google Access, and
# outbound egress via Cloud NAT.
#
# Apply this only on an empty project. If you already own a subnet, skip
# straight to ../vm and point it at yours.
#
# The IAP-SSH firewall rule is NOT here. It has to target the tags the module
# actually applied, which are an output of the VM root, so ../vm owns it. A rule
# written here would have to guess at a tag and could drift from the instance.

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

resource "google_project_service" "apis" {
  for_each = toset(var.apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  description             = "${var.name_prefix} VPC - k3s VM"

  depends_on = [google_project_service.apis["compute.googleapis.com"]]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.name_prefix}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id

  # Private Google Access gives the VM a route to secretmanager.googleapis.com
  # that does not depend on Cloud NAT. With NAT present it is redundant, but it
  # keeps secret injection working for a no-NAT deployment - which is viable
  # once enable_k3s_bootstrap is false and general egress is no longer needed.
  # It also keeps Google API traffic off the NAT: no port pressure, no egress
  # charges, shorter path.
  private_ip_google_access = true
}

# Outbound internet egress. The VM has no public IP, so this is its only route
# out, and it is REQUIRED when enable_k3s_bootstrap is true: first boot clones
# the bring-up repo and downloads the k3s installer, neither of which is a
# Google API. Inbound stays closed.
resource "google_compute_router" "router" {
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
