# Secret Manager containers for k3s-gce deployments to READ.
#
# The module creates nothing in Secret Manager - it only grants its VM read
# access to containers that already exist. This root is where they come from:
# one writer, many readers.
#
# Container names are written out in full, exactly as they will exist. The name
# you put here is the name a VM puts in its env_secret_map, with no derivation
# in between:
#
#     secrets        = { "shared-llm-api-key" = "sk-..." }   # here
#     env_secret_map = { LLM_API_KEY = "shared-llm-api-key" } # in ../vm
#
# Values are written with secret_data_wo, a write-only argument. Terraform sends
# it to the API and never records it as a resource attribute, so it stays out of
# STATE. That is the point: state is the long-lived artifact, and this keeps it
# ordinary rather than a credential store. It is why required_version is 1.11
# rather than 1.5.
#
# It does NOT cover a saved plan file. `terraform plan -out=` records the input
# VARIABLE values so that apply can reuse them, so var.secrets appears there in
# cleartext under .variables even though the resource attribute is null. Do not
# save plans from this root, or treat the file as a secret if you do.

terraform {
  required_version = ">= 1.11"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project     = var.project_id
  region      = var.region
  credentials = var.credentials_file != null ? file(var.credentials_file) : null
}

locals {
  # for_each keys cannot derive from a sensitive value, and only the values here
  # are sensitive - the container names are not.
  names = toset(nonsensitive(keys(var.secrets)))
}

resource "google_secret_manager_secret" "this" {
  for_each  = local.names
  secret_id = each.value

  replication {
    auto {}
  }

  labels = {
    managed = "k3s-gce"
  }
}

# Edit a value and Terraform notices.
#
# A write-only argument cannot be diffed - Terraform keeps no copy of the old
# value to compare against - so changing var.secrets alone produces "No changes"
# and the edit is silently ignored. secret_data_wo_version is the provider's
# hook for exactly this: change the number, get a new version. It does not care
# whether the number is hand-bumped or computed, so it is computed here, per
# key. Only the container whose value actually changed is rewritten.
#
# The number is a truncated hash of the value. 15 hex digits is 60 bits, which
# keeps a changed value colliding with its own old hash out of the realm of
# things worth worrying about, and stays inside Terraform's numeric range where
# 16 digits would risk overflowing int64.
#
# It is SALTED, and that is not decoration. Terraform's only memory between runs
# is state, so any change detection at all must persist a fingerprint there -
# that is what an etag is. An unsalted hash of a secret makes state a
# confirmation oracle: anyone holding the file can test a guessed value against
# it. Salting removes that, because confirming a guess then needs the salt, and
# the salt lives in the same gitignored tfvars as the secret it protects.
#
# What this does NOT detect is a value changed in GCP behind Terraform's back.
# The hash is computed from your config, never from the remote. The check block
# below covers that case.
resource "google_secret_manager_secret_version" "this" {
  for_each = local.names
  secret   = google_secret_manager_secret.this[each.key].id

  secret_data_wo         = var.secrets[each.key]
  secret_data_wo_version = parseint(substr(sha256("${var.secrets_salt}:${var.secrets[each.key]}"), 0, 15), 16)

  # A version change is a replacement, not an update, and deletion_policy
  # defaults to DELETE. Destroying first would leave the container with no
  # accessible version, so a VM booting in that window reads nothing. Secret
  # Manager holds many versions happily, so create the new one first.
  lifecycle {
    create_before_destroy = true
  }
}

# Metadata only - fetch_secret_data is false, so no value is read and none can
# land in state. All this asks for is which version `latest` points at.
#
# depends_on is load-bearing. Without it the read happens at PLAN time, and on
# the very first run there is no version yet, so the whole plan fails with a 404
# before it can create one. Declaring the dependency defers the read to apply,
# after the version exists, which is what makes this safe to bootstrap.
data "google_secret_manager_secret_version" "latest" {
  for_each          = local.names
  secret            = each.value
  fetch_secret_data = false

  depends_on = [google_secret_manager_secret_version.this]
}

# The half the hash cannot cover: someone ran `gcloud secrets versions add`.
#
# Config and remote agree on the version number until a writer other than this
# root adds one. A check block reports that as a warning rather than an error,
# which is the right severity - the drift is real, but Terraform cannot fix it
# without being told what the value should now be.
#
# Expect "assertion known after apply" on a rotation. The new version number is
# unknown until it exists, so the assertion cannot be evaluated at plan time.
# That warning is accurate rather than a fault.
check "no_out_of_band_versions" {
  assert {
    condition = alltrue([
      for k in local.names :
      data.google_secret_manager_secret_version.latest[k].version == google_secret_manager_secret_version.this[k].version
    ])
    error_message = "A secret version was created outside Terraform. Something other than this root is writing these containers - see the one-writer-per-key rule in ../README.md."
  }
}
