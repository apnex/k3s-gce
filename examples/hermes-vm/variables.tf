variable "project_id" {
  description = "GCP project ID this VM deploys into"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "australia-southeast1"
}

variable "zone" {
  description = "GCP zone for the VM"
  type        = string
  default     = "australia-southeast1-a"
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "hermes"
}

variable "credentials_file" {
  description = "Path to a GCP service-account key JSON. Null uses Application Default Credentials (gcloud)."
  type        = string
  default     = null
}

# Each key is { key, scope }. scope "self" (default) → a per-VM container
# `<name_prefix>-<KEY>` the module creates. A shared label → `<label>-<KEY>`,
# assumed to already exist (module only grants read). Here the LiteLLM proxy
# creds are shared across deployments under the "kate" label; the rest are
# per-VM. ssh-target keys are added automatically (always self).
variable "secret_keys" {
  description = "App secrets to provision/fetch as { key, scope } objects (scope defaults to self)"
  type = list(object({
    key   = string
    scope = optional(string, "self")
  }))
  default = [
    { key = "LITELLM_BASE_URL", scope = "kate" },
    { key = "LITELLM_MODEL", scope = "kate" },
    { key = "LITELLM_API_KEY", scope = "kate" },
    { key = "HERMES_PEER_NAME" },
    { key = "DISCORD_BOT_TOKEN" },
    { key = "DISCORD_ALLOWED_USERS" },
    { key = "GH_TOKEN" },
  ]
}

variable "secret_values" {
  description = "Optional KEY → value map (supply via gitignored secrets.auto.tfvars)"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "env_file_path" {
  description = "Where the startup script writes the sourced env file"
  type        = string
  default     = "/root/k3s.env"
}

variable "enable_ssh_target_login" {
  description = "Provision the pod→host OS Login identity"
  type        = bool
  default     = true
}

variable "enable_k3s_bootstrap" {
  description = "Self-assemble k3s on first boot"
  type        = bool
  default     = true
}

variable "k3s_repo_url" {
  description = "k3s bring-up repo"
  type        = string
  default     = "https://github.com/apnex/labops.git"
}

variable "k3s_repo_ref" {
  description = "k3s bring-up repo ref"
  type        = string
  default     = "master"
}
