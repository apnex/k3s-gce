# Provider requirements for the k3s-gce module.
#
# Single provider, no configuration_aliases. Callers wire one `google` provider
# and nothing else.
terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
