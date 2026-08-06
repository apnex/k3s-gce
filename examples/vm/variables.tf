variable "project_id" {
  description = "GCP project ID this VM deploys into"
  type        = string
}

variable "zone" {
  description = "GCP zone for the VM. The region is derived from it, and var.subnet_name must resolve in that region."
  type        = string
  default     = "australia-southeast1-a"
}

variable "name_prefix" {
  description = "Prefix for all resource names. Must not collide with workloads already on the target network."
  type        = string
  default     = "k3stest"
}

variable "credentials_file" {
  description = "Path to a GCP service-account key JSON. Null uses Application Default Credentials (gcloud)."
  type        = string
  default     = null
}

variable "subnet_name" {
  description = "Name of an EXISTING subnetwork to attach the VM to. Must be in the region derived from var.zone, and must provide a route to secretmanager.googleapis.com (Private Google Access or Cloud NAT) plus general internet egress when enable_k3s_bootstrap is true. Deliberately has no default -- naming someone else's subnet is not a thing to guess at."
  type        = string
}

variable "env_secret_map" {
  description = "Environment variable name -> EXISTING Secret Manager container name. Every container must already exist; the module only grants its VM read access and never creates or writes one. Create them in a separate root or with `gcloud secrets create`. Empty by default so a bare apply stands up the VM with no secret dependencies."
  type        = map(string)
  default     = {}
}

variable "env_file_path" {
  description = "Absolute path the guest writes the sourced env file to. Null defaults to /root/<name_prefix>.env."
  type        = string
  default     = null
}

variable "enable_k3s_bootstrap" {
  description = "On first boot, clone the bring-up repo and run its entrypoint. Leave true even for a dry run -- K3S_DRYRUN stops k3s/up before it changes the host, which tests the delivery chain without installing anything."
  type        = bool
  default     = true
}

variable "k3s_repo_url" {
  description = "Git repo cloned on first boot to bring up k3s."
  type        = string
  default     = "https://github.com/apnex/labops.git"
}

variable "k3s_repo_ref" {
  description = "Git ref (branch, tag, or commit SHA) of k3s_repo_url to clone."
  type        = string
  default     = "master"
}
