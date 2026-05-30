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

variable "secret_prefix" {
  description = "Secret Manager container prefix"
  type        = string
  default     = "kate"
}

variable "secret_keys" {
  description = "App secret KEYS to provision + fetch (ssh-target keys are added by the module)"
  type        = list(string)
  default = [
    "LITELLM_BASE_URL",
    "LITELLM_MODEL",
    "LITELLM_API_KEY",
    "HERMES_PEER_NAME",
    "DISCORD_BOT_TOKEN",
    "DISCORD_ALLOWED_USERS",
    "GH_TOKEN",
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
  default     = "/root/kate.env"
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
