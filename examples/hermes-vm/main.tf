# Example: the hermes kate substrate on labops-389703.
#
# Instantiates the k3s-vm module with kate-flavored secret naming. All
# deployment-specific, non-secret config lives in terraform.tfvars; secret
# VALUES go in a gitignored secrets.auto.tfvars (see the .example).

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
  }
}

provider "google" {
  project     = var.project_id
  region      = var.region
  credentials = var.credentials_file != null ? file(var.credentials_file) : null
}

# Impersonates the ssh-target SA so the module can register its OS Login key AS
# that SA (importSshPublicKey is self-only). The SA email is constructed from
# the same naming the module uses, so the provider config stays static. The
# tokenCreator grant that authorises impersonation is created inside the module.
provider "google" {
  alias                       = "ssh_login"
  project                     = var.project_id
  region                      = var.region
  credentials                 = var.credentials_file != null ? file(var.credentials_file) : null
  impersonate_service_account = "${var.name_prefix}-ssh-target@${var.project_id}.iam.gserviceaccount.com"
}

module "k3s_vm" {
  source = "../../modules/k3s-vm"

  providers = {
    google           = google
    google.ssh_login = google.ssh_login
  }

  project_id  = var.project_id
  region      = var.region
  zone        = var.zone
  name_prefix = var.name_prefix

  secret_keys   = var.secret_keys
  secret_values = var.secret_values
  env_file_path = var.env_file_path

  enable_ssh_target_login = var.enable_ssh_target_login
  enable_k3s_bootstrap    = var.enable_k3s_bootstrap
  k3s_repo_url            = var.k3s_repo_url
  k3s_repo_ref            = var.k3s_repo_ref
}
