variable "project_id" {
  description = "GCP project ID the containers live in"
  type        = string
}

variable "region" {
  description = "GCP region for the provider. Container replication is automatic and not region-bound."
  type        = string
  default     = "australia-southeast1"
}

variable "credentials_file" {
  description = "Path to a GCP service-account key JSON. Null uses Application Default Credentials (gcloud)."
  type        = string
  default     = null
}

variable "secrets" {
  description = "Secret Manager container name → value. The container name is written in full and is EXACTLY the string a VM puts on the right-hand side of its env_secret_map. Values are written with a write-only argument, so they reach the API but are never recorded as a resource attribute and so never land in state. A saved plan file (-out=) still records them under .variables, so do not save plans from this root."
  type        = map(string)
  default     = {}
  sensitive   = true
}

# Salt for the change-detection hash, not a cryptographic secret in its own
# right. It exists so the fingerprint that necessarily lands in state cannot be
# used to confirm a guessed value: doing that needs the salt, and the salt lives
# in the same gitignored tfvars as the values it protects.
#
# Keep it stable. Changing it rewrites every container, because every hash moves.
variable "secrets_salt" {
  description = "Salt for the per-key change-detection hash. Any stable string. Set it once in the gitignored secrets.auto.tfvars and leave it alone - changing it rewrites a new version of every container, since every hash changes with it. It is not a secret in its own right, but it lives beside the values and should not be committed."
  type        = string
  sensitive   = true

  validation {
    # An empty salt silently degrades to a plain hash of the value, which is the
    # confirmation oracle this exists to prevent. Fail rather than pretend.
    condition     = length(var.secrets_salt) >= 16
    error_message = "secrets_salt must be at least 16 characters. An empty or trivial salt leaves the state fingerprint testable against a guessed value, which is the whole reason it is here."
  }
}
