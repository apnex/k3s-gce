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
  description = "Self link or ID of an existing subnetwork to attach the VM to. Must be in the region derived from var.zone. The VM has no public IP, so the subnet must give it a route to secretmanager.googleapis.com -- either Private Google Access or Cloud NAT satisfies that. General internet egress (Cloud NAT or equivalent) is additionally required when enable_k3s_bootstrap is true, since the bring-up entrypoint and the k3s installer are not Google APIs."
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

# Plain, non-secret environment for the guest. Rides in instance metadata as
# one key per variable, and lands in the same env files as the secrets.
#
# Instance metadata is readable by any process on the VM and by anyone holding
# compute.instances.get, so this is for config with nothing to hide -- feature
# switches, tuning knobs, endpoints. Anything worth protecting belongs in
# env_secret_map, which carries names and leaves the values in Secret Manager.
#
# Without this the only channel to the guest was a Secret Manager container,
# which meant inventing a container to pass a boolean.
variable "env_map" {
  description = "Environment variable name → literal value, delivered via instance metadata. For NON-SECRET config only: metadata is readable by any process on the VM and by anyone with compute.instances.get. Use env_secret_map for anything sensitive. Values may contain any bytes, including newlines - each variable gets its own metadata key, so there is no delimiter to collide with."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.env_map) : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k))])
    error_message = "env_map keys become shell variable names, so each must match ^[A-Za-z_][A-Za-z0-9_]*$."
  }

  validation {
    # Both maps write the same env files. An overlap is always a mistake, and
    # catching it here beats a value silently winning on the VM.
    condition     = length(setintersection(keys(var.env_map), keys(var.env_secret_map))) == 0
    error_message = "A name cannot appear in both env_map and env_secret_map. Move it to one or the other."
  }
}

variable "env_file_path" {
  description = "Absolute path the startup script writes the sourced env file to. Auto-sourced for root login shells via /etc/profile.d. Defaults to /root/<name_prefix>.env when null."
  type        = string
  default     = null
}

# ── k3s self-assembly ───────────────────────────────────────────────
variable "enable_k3s_bootstrap" {
  description = "On first boot, fetch k3s_bootstrap_url and run it to self-assemble the cluster. When false, the VM stands up bare and k3s is installed manually."
  type        = bool
  default     = true
}

# One URL, fetched over HTTPS. No git, and nothing to pin.
#
# A clone needed git installed first -- absent from a stock Rocky image, and
# roughly a third of the bring-up wall time to put there. curl is already in the
# base image, so the entrypoint is one GET.
#
# There is no ref. Whatever the URL serves at boot is what the node gets, which
# is the same contract every other boot-time fetch here already has.
variable "k3s_bootstrap_url" {
  description = "URL of the bring-up entrypoint script, fetched over HTTPS on first boot and executed (used when enable_k3s_bootstrap = true). Downloaded to disk before running, so a truncated transfer cannot half-execute. There is no ref to pin: the URL names what runs. An entrypoint that resolves further modules of its own does so over the same transport."
  type        = string
  default     = "https://labops.sh/k3s/up"

  validation {
    condition     = can(regex("^https://", var.k3s_bootstrap_url))
    error_message = "k3s_bootstrap_url must be https:// -- the entrypoint is executed as root on first boot."
  }
}

# ── netbird ─────────────────────────────────────────────────────────
# A second installer duty, driven by the same bootstrap.sh as k3s and ordered
# ahead of it, so the cluster comes up on a host already on the network.
#
# The setup key is not an input here. It arrives the way every other secret
# does - as an env_secret_map entry naming a Secret Manager container - which
# keeps the module a pure reader and keeps the key out of state and out of the
# plan file. The guest reads NETBIRD_SETUP_KEY from /run/gce-env/env.
variable "enable_netbird" {
  description = "On first boot, fetch netbird_bootstrap_url and run it to join the NetBird network. Requires NETBIRD_SETUP_KEY in env_secret_map. Runs before the k3s bring-up."
  type        = bool
  default     = false

  validation {
    # The installer cannot join without a key, and finding that out from a
    # failed unit on the VM is worse than finding it out at plan time.
    condition     = !var.enable_netbird || contains(keys(var.env_secret_map), "NETBIRD_SETUP_KEY")
    error_message = "enable_netbird requires NETBIRD_SETUP_KEY in env_secret_map, e.g. { NETBIRD_SETUP_KEY = \"netbird-setup-key\" }."
  }
}

variable "netbird_bootstrap_url" {
  description = "URL of the NetBird bring-up entrypoint, fetched over HTTPS on first boot and executed (used when enable_netbird = true). Same contract as k3s_bootstrap_url: downloaded to disk before running, and no ref to pin."
  type        = string
  default     = "https://labops.sh/netbird/up"

  validation {
    condition     = can(regex("^https://", var.netbird_bootstrap_url))
    error_message = "netbird_bootstrap_url must be https:// -- the entrypoint is executed as root on first boot."
  }
}
