variable "project_id" {
  description = "GCP project ID to build the network in"
  type        = string
}

# A region, not a zone. This root builds no instance, so there is nothing to
# derive a region from -- unlike ../vm, which derives it from var.zone. The two
# must agree: ../vm's zone has to sit inside this region.
variable "region" {
  description = "GCP region for the subnet, router and NAT. The VM root's zone must be inside it."
  type        = string
  default     = "australia-southeast1"
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "k3s"
}

variable "credentials_file" {
  description = "Path to a GCP service-account key JSON. Null uses Application Default Credentials (gcloud)."
  type        = string
  default     = null
}

variable "subnet_cidr" {
  description = "Primary IPv4 CIDR for the subnet"
  type        = string
  default     = "10.20.0.0/24"
}

variable "apis" {
  description = "Project services to enable. The minimum for an OS-Login + Secret-Manager VM reachable over IAP."
  type        = list(string)
  default = [
    "compute.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iap.googleapis.com",
    "secretmanager.googleapis.com",
  ]
}
