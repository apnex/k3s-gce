# ── identity ────────────────────────────────────────────────────────
variable "project_id" {
  description = "GCP project ID this VM deploys into"
  type        = string
}

# No region input. A GCE zone always contains its region, so the module derives
# it (see locals in main.tf). That makes a region/zone mismatch unrepresentable
# rather than a confusing apply-time failure.
variable "zone" {
  description = "GCP zone for the VM. The region is derived from it, and var.subnetwork must be in that region."
  type        = string
  default     = "australia-southeast1-a"

  validation {
    # Catches a region being passed where a zone belongs, which would otherwise
    # surface as an unhelpful error on the internal address.
    condition     = can(regex("^[a-z0-9-]+-[a-z]$", var.zone))
    error_message = "zone must be a GCE zone ending in a zone letter, e.g. australia-southeast1-a, not a region."
  }
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

# ── networking (caller-provided) ────────────────────────────────────
# The module does NOT create a VPC, subnet, firewall rule or Cloud NAT. It
# attaches to a subnetwork you already own. See README for what that
# subnetwork must provide.
variable "subnetwork" {
  description = "Self link or ID of an existing subnetwork to attach the VM to. Must be in the region derived from var.zone. The VM has no public IP, so the subnet must give it a route to secretmanager.googleapis.com -- either Private Google Access or Cloud NAT satisfies that. General internet egress (Cloud NAT or equivalent) is additionally required when enable_k3s_bootstrap is true, since the bring-up repo and k3s installer are not Google APIs."
  type        = string
}

variable "network_tags" {
  description = "Network tags applied to the VM. Your IAP-SSH firewall rule must target these. Defaults to [\"<name_prefix>-vm\"] when null; also exposed as the network_tags output so the firewall rule can reference what was actually applied."
  type        = list(string)
  default     = null
}

# ── secret / env injection (app-agnostic, READ-ONLY) ────────────────
# The module never creates or writes a Secret Manager container. It grants its
# VM read access to containers you already own, and tells the guest which
# container backs which environment variable.
#
# The two names are decoupled on purpose. The map key is the environment
# variable written into the env file, so it must be a valid shell identifier;
# the map value is the container as it is actually named in Secret Manager,
# whatever convention that follows. Tying them together would make any
# pre-existing secret whose name is not a legal shell identifier unreadable.
variable "env_secret_map" {
  description = "Environment variable name → existing Secret Manager container name, e.g. { LLM_API_KEY = \"shared-llm-api-key\" }. Every container must ALREADY EXIST; the module only binds its VM service account as a reader and never creates, writes or destroys one. The key becomes the variable name in the env file, so it must be a valid shell identifier. Two keys may reference the same container."
  type        = map(string)
  default     = {}

  validation {
    # A key that is not a legal shell identifier would be written into the env
    # file as `not-valid=...`, which fails to source. Catching it here beats a
    # silently broken env file discovered at boot.
    condition     = alltrue([for k in keys(var.env_secret_map) : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k))])
    error_message = "env_secret_map keys become shell variable names, so each must match ^[A-Za-z_][A-Za-z0-9_]*$. The Secret Manager container name is the VALUE and has no such restriction."
  }

  validation {
    condition     = alltrue([for v in values(var.env_secret_map) : length(trimspace(v)) > 0])
    error_message = "env_secret_map values must be non-empty Secret Manager container names."
  }
}

variable "env_file_path" {
  description = "Absolute path the startup script writes the sourced env file to. Auto-sourced for root login shells via /etc/profile.d. Defaults to /root/<name_prefix>.env when null."
  type        = string
  default     = null
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
