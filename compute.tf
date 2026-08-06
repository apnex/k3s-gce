# Internal-only Rocky VM. Static internal IP, no public IP — reachable only via
# IAP-SSH. The static, generic startup.sh is parameterised entirely via metadata
# (no Terraform templating), so it stays a plain testable bash script.

resource "google_compute_address" "vm_internal" {
  name         = "${var.name_prefix}-vm-ip"
  address_type = "INTERNAL"
  subnetwork   = var.subnetwork
  region       = local.region
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
  # env-var-* keys are merged in rather than listed: one key per plain variable,
  # so a value containing a comma or a newline has no delimiter to break.
  metadata = merge(local.env_var_metadata, {
    enable-oslogin = "TRUE"

    # env injection — TF owns the mapping; env.sh fetches by container name and
    # writes the bare ENV=value. env-secret-map is "ENV:container,…". Names
    # only: metadata is readable by any process on the VM and by anyone with
    # compute.instances.get, so SECRET values stay in Secret Manager. Plain
    # values ride in env-var-* above, which is why they must not be sensitive.
    env-project    = var.project_id
    env-secret-map = local.env_secret_map_csv
    env-file       = local.env_file_path

    # k3s self-assembly
    k3s-bootstrap     = var.enable_k3s_bootstrap ? "on" : "off"
    k3s-repo          = var.k3s_repo_url
    k3s-ref           = var.k3s_repo_ref
    k3s-up-entrypoint = var.k3s_up_entrypoint

    # Guest assets. startup-script installs the other four and drives the two
    # units; it performs no provisioning itself. One duty per unit:
    # gce-env resolves config and secrets into the env file, k3s-bootstrap
    # self-assembles k3s once.
    startup-script = file("${path.module}/guest/startup.sh")
    env-script     = file("${path.module}/guest/env.sh")
    k3s-script     = file("${path.module}/guest/k3s.sh")
    env-unit       = file("${path.module}/guest/gce-env.service")
    k3s-unit       = file("${path.module}/guest/k3s-bootstrap.service")
  })

  labels = {
    managed = "k3s-gce"
    role    = "${var.name_prefix}-k3s"
  }

  allow_stopping_for_update = true
}
