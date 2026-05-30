variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "australia-southeast1"
}

variable "credentials_file" {
  description = "Path to a GCP service-account key JSON. Null uses ADC (gcloud)."
  type        = string
  default     = null
}

variable "scope" {
  description = "Shared-scope label — the container prefix. VMs reference these by listing { key, scope = this } in their secret_keys."
  type        = string
  default     = "kate"
}

variable "secret_values" {
  description = "KEY → value map for the shared containers (supply via gitignored secrets.auto.tfvars). Values land in terraform.tfstate in plaintext — treat state as sensitive."
  type        = map(string)
  default     = {}
  sensitive   = true
}
