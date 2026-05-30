# Internal-only Rocky VM. Static internal IP, no public IP — reachable only via
# IAP-SSH. The static, generic startup.sh is parameterised entirely via metadata
# (no Terraform templating), so it stays a plain testable bash script.

resource "google_compute_address" "vm_internal" {
  name         = "${var.name_prefix}-vm-ip"
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.subnet.id
  region       = var.region
}

resource "google_compute_instance" "vm" {
  name         = "${var.name_prefix}-vm"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["${var.name_prefix}-vm"]

  boot_disk {
    initialize_params {
      image = var.boot_disk_image
      size  = var.boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  # Internal-only — no access_config block, so no ephemeral public IP.
  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    network_ip = google_compute_address.vm_internal.address
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  # All startup.sh behaviour is driven by these metadata keys — no .tftpl.
  # Set via the metadata map (not metadata_startup_script, which is forceNew
  # and would recreate the VM on every script edit).
  metadata = {
    enable-oslogin            = "TRUE"
    google-logging-enabled    = "true"
    google-monitoring-enabled = "true"

    # env injection — TF owns container naming; startup.sh fetches by container
    # name and writes the bare KEY=value. k3s-secret-map is "KEY:container,…".
    k3s-project    = var.project_id
    k3s-secret-map = local.secret_map
    k3s-env-file   = local.env_file_path

    # k3s self-assembly
    k3s-bootstrap     = var.enable_k3s_bootstrap ? "on" : "off"
    k3s-repo          = var.k3s_repo_url
    k3s-ref           = var.k3s_repo_ref
    k3s-up-entrypoint = var.k3s_up_entrypoint

    startup-script = file("${path.module}/startup.sh")
  }

  labels = {
    managed = "k3s-gce"
    role    = "${var.name_prefix}-k3s"
  }

  depends_on = [
    google_project_service.apis["compute.googleapis.com"],
    google_compute_firewall.allow_iap_ssh,
  ]

  allow_stopping_for_update = true
}
