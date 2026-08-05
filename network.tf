# Custom VPC + subnet + IAP-SSH firewall + Cloud NAT for outbound egress.
# The VM has no public IP — reachable only via IAP-tunnel SSH; outbound via NAT.

resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  description             = "${var.name_prefix} VPC — internal-only k3s VM"

  depends_on = [google_project_service.apis["compute.googleapis.com"]]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.name_prefix}-subnet"
  ip_cidr_range = var.vpc_cidr
  region        = var.region
  network       = google_compute_network.vpc.id

  # VM has no public IP — Private Google Access lets it reach Google APIs
  # (Cloud Logging, OS Login metadata, Secret Manager) without Cloud NAT.
  private_ip_google_access = true
}

# IAP-tunnel SSH → VM:22. 35.235.240.0/20 is Google's canonical IAP range.
resource "google_compute_firewall" "allow_iap_ssh" {
  name      = "${var.name_prefix}-allow-iap-ssh"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name_prefix}-vm"]
}

# Cloud NAT — outbound internet egress for the internal-only VM.
# Inbound stays closed (no public IP); reachable only via IAP-SSH.
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
