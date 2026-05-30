# ── identity ────────────────────────────────────────────────────────
variable "project_id" {
  description = "GCP project ID this VM deploys into"
  type        = string
}

variable "region" {
  description = "GCP region for all regional resources"
  type        = string
  default     = "australia-southeast1"
}

variable "zone" {
  description = "GCP zone for the VM"
  type        = string
  default     = "australia-southeast1-a"
}

variable "name_prefix" {
  description = "Prefix for all resource names (multi-instance collision-safety)"
  type        = string
  default     = "k3s"
}

# ── VM shape ────────────────────────────────────────────────────────
variable "machine_type" {
  description = "GCE machine type for the VM"
  type        = string
  default     = "e2-medium"
}

variable "boot_disk_image" {
  description = "Boot disk image or family"
  type        = string
  default     = "rocky-linux-cloud/rocky-linux-9"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB"
  type        = number
  default     = 20
}

variable "vpc_cidr" {
  description = "Primary IPv4 CIDR for the subnet"
  type        = string
  default     = "10.20.0.0/24"
}

# ── project services + VM SA roles ──────────────────────────────────
variable "apis" {
  description = "Project services to enable. The defaults are the minimum for an internal-only, OS-Login + Secret-Manager VM."
  type        = list(string)
  default = [
    "compute.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
  ]
}

variable "vm_roles" {
  description = "Project IAM roles granted to the VM runtime service account."
  type        = list(string)
  default = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]
}

# ── secret / env injection (app-agnostic) ───────────────────────────
variable "secret_prefix" {
  description = "Secret Manager container name prefix. Containers are named `<secret_prefix>-<env_name>-<KEY>`. Defaults to name_prefix when null."
  type        = string
  default     = null
}

variable "env_name" {
  description = "Environment name segment in the Secret Manager container names. Defaults to name_prefix when null."
  type        = string
  default     = null
}

variable "secret_keys" {
  description = "Application secret KEYS the VM should fetch into the env file (e.g. LITELLM_API_KEY, GH_TOKEN). The ssh-target keys are added automatically when enable_ssh_target_login is true — do NOT list them here."
  type        = list(string)
  default     = []
}

variable "secret_values" {
  description = "Optional KEY → value map written as Secret Manager versions (typically via a gitignored *.auto.tfvars). Keys must be a subset of secret_keys. Values land in terraform.tfstate in plaintext — treat state as sensitive."
  type        = map(string)
  default     = {}
  sensitive   = true

  validation {
    # Keys must be declared in secret_keys. nonsensitive() is safe here — it
    # exposes only the KEY names (not values) to the error message. This also
    # blocks accidentally setting the module-owned SSH_TARGET_* keys.
    condition     = length(setsubtract(keys(nonsensitive(var.secret_values)), var.secret_keys)) == 0
    error_message = "secret_values keys must be a subset of secret_keys (do not set the module-managed SSH_TARGET_* keys here)."
  }
}

variable "env_file_path" {
  description = "Absolute path the startup script writes the sourced env file to. Auto-sourced for root login shells via /etc/profile.d. Defaults to /root/<name_prefix>.env when null."
  type        = string
  default     = null
}

# ── pod→host SSH login identity (OS Login) ──────────────────────────
variable "enable_ssh_target_login" {
  description = "Provision a dedicated 'ssh-target' login SA + generate a keypair + register it in OS Login, and auto-add SSH_TARGET_USER/SSH_TARGET_KEY to the secret set. Requires the google.ssh_login aliased provider AND org-level grants (compute.osLoginExternalUser + iam.serviceAccountUser) on the SA — see module README."
  type        = bool
  default     = true
}

# ── k3s self-assembly ───────────────────────────────────────────────
variable "enable_k3s_bootstrap" {
  description = "On first boot, clone the k3s bring-up repo and run its entrypoint to self-assemble the cluster. When false, the VM stands up bare and k3s is installed manually."
  type        = bool
  default     = true
}

variable "k3s_repo_url" {
  description = "Git repo cloned on first boot to bring up k3s (used when enable_k3s_bootstrap = true)."
  type        = string
  default     = "https://github.com/apnex/labops.git"
}

variable "k3s_repo_ref" {
  description = "Git ref (branch/tag) of k3s_repo_url to clone."
  type        = string
  default     = "master"
}

variable "k3s_up_entrypoint" {
  description = "Path within the cloned repo to the k3s bring-up entrypoint script."
  type        = string
  default     = "k3s/up"
}
