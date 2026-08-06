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

variable "secrets_version" {
  description = "Bump to write a new version of every container. Write-only values cannot be diffed - Terraform keeps no copy to compare against - so revisions are explicit rather than inferred from the value changing."
  type        = number
  default     = 1
}
