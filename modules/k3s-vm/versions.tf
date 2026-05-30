# Provider requirements for the k3s-vm module.
#
# google.ssh_login is an OPTIONAL aliased provider the caller passes in when
# enable_ssh_target_login = true. It must impersonate the ssh-target SA so the
# OS Login key can be registered AS that SA (importSshPublicKey is self-only).
# Declared here as a configuration_alias so callers wire it via `providers = {}`.
terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source                = "hashicorp/google"
      version               = "~> 6.0"
      configuration_aliases = [google.ssh_login]
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
