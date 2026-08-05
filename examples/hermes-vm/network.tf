# Project and network prerequisites for the k3s-gce module.
#
# The module deploys the VM only. Everything here is the caller's
# responsibility, and this file is the reference for what that means:
# enabled APIs, a VPC, a subnet with Private Google Access, an IAP-SSH
# firewall rule, and outbound egress via Cloud NAT.

resource "google_project_service" "apis" {
  for_each = toset(var.apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  description             = "${var.name_prefix} VPC - internal-only k3s VM"

  depends_on = [google_project_service.apis["compute.googleapis.com"]]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.name_prefix}-subnet"
  ip_cidr_range = var.vpc_cidr
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

# IAP-tunnel SSH to VM:22. 35.235.240.0/20 is Google's canonical IAP range.
# Targets the tags the module actually applied, so the two cannot drift.
resource "google_compute_firewall" "allow_iap_ssh" {
  name      = "${var.name_prefix}-allow-iap-ssh"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = module.k3s_gce.network_tags
}

# Outbound internet egress for the internal-only VM. REQUIRED when
# enable_k3s_bootstrap is true: first boot clones the bring-up repo and
# downloads the k3s installer. Inbound stays closed - no public IP.
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
