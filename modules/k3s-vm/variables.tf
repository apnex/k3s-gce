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
# Container names are `<scope>-<KEY>`. Each key's scope is either the VM's own
# name (per-VM isolation) or a shared label (cross-VM sharing):
#   scope = "self" (default) → `<name_prefix>-<KEY>`, CREATED + read-granted here
#   scope = "<label>"        → `<label>-<KEY>`, assumed to ALREADY EXIST; the
#                              module only grants the VM read access (it does
#                              not create or write shared containers).
variable "secret_keys" {
  description = "Application secrets the VM fetches into the env file. Each entry is { key = \"NAME\", scope = \"self\"|\"<shared-label>\" } (scope defaults to \"self\"). self → module creates `<name_prefix>-<KEY>`; a label → module references an existing `<label>-<KEY>` (read-only). The ssh-target keys are added automatically (always self) when enable_ssh_target_login is true — do NOT list them here."
  type = list(object({
    key   = string
    scope = optional(string, "self")
  }))
  default = []
}

variable "secret_values" {
  description = "Optional KEY → value map written as Secret Manager versions of the SELF-scoped containers (typically via a gitignored *.auto.tfvars). Keys must be self-scoped entries in secret_keys — shared containers are populated out-of-band, not here. Values land in terraform.tfstate in plaintext — treat state as sensitive."
  type        = map(string)
  default     = {}
  sensitive   = true

  validation {
    # Values may only target SELF-scoped keys — shared containers are populated
    # out-of-band, not by this deployment. Validating against the self-scoped
    # subset turns a misplaced shared value into a clear message here instead of
    # an "Invalid index" crash in secrets.tf. nonsensitive() exposes only KEY
    # names (not values) to the error text.
    condition     = length(setsubtract(keys(nonsensitive(var.secret_values)), [for e in var.secret_keys : e.key if e.scope == "self"])) == 0
    error_message = "secret_values keys must be SELF-scoped entries in secret_keys. Shared-scoped keys are populated where their container is created (e.g. env/shared/), and SSH_TARGET_* are module-managed."
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
