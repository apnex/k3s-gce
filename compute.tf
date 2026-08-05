# Internal-only Rocky VM. Static internal IP, no public IP — reachable only via
# IAP-SSH. The static, generic startup.sh is parameterised entirely via metadata
# (no Terraform templating), so it stays a plain testable bash script.

resource "google_compute_address" "vm_internal" {
  name         = "${var.name_prefix}-vm-ip"
  address_type = "INTERNAL"
  subnetwork   = var.subnetwork
  region       = var.region
}

resource "google_compute_instance" "vm" {
  name         = "${var.name_prefix}-vm"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = local.network_tags

  boot_disk {
    initialize_params {
      image = var.boot_disk_image
      size  = var.boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  # Internal-only - no access_config block, so no ephemeral public IP.
  network_interface {
    subnetwork = var.subnetwork
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
    enable-oslogin = "TRUE"

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

    # Guest assets. startup-script installs the other four and drives the two
    # units; it performs no provisioning itself. One duty per unit:
    # k3s-gce-env resolves secrets into the env file, k3s-gce-bootstrap
    # self-assembles k3s once.
    startup-script       = file("${path.module}/guest/startup.sh")
    k3s-env-script       = file("${path.module}/guest/env.sh")
    k3s-bootstrap-script = file("${path.module}/guest/k3s.sh")
    k3s-env-unit         = file("${path.module}/guest/k3s-gce-env.service")
    k3s-bootstrap-unit   = file("${path.module}/guest/k3s-gce-bootstrap.service")
  }

  labels = {
    managed = "k3s-gce"
    role    = "${var.name_prefix}-k3s"
  }

  allow_stopping_for_update = true
}
