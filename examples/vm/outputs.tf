output "vm_name" {
  description = "Name of the k3s VM"
  value       = module.k3s_gce.vm_name
}

output "vm_internal_ip" {
  description = "Static internal IP allocated from the existing subnet"
  value       = module.k3s_gce.vm_internal_ip
}

output "vm_zone" {
  description = "Zone the VM lives in"
  value       = module.k3s_gce.vm_zone
}

output "vm_sa_email" {
  description = "Runtime service account. Grant it anything beyond secret reads here, not in the module."
  value       = module.k3s_gce.vm_sa_email
}

output "network_tags" {
  description = "Tags applied to the VM, and what the IAP-SSH rule in this root targets"
  value       = module.k3s_gce.network_tags
}

output "subnetwork" {
  description = "Self link of the existing subnetwork the VM attached to, confirming it resolved in the region derived from var.zone"
  value       = data.google_compute_subnetwork.target.self_link
}

output "ssh_command" {
  description = "Connect via IAP tunnel (sudo -i for root once in)"
  value       = module.k3s_gce.ssh_command
}

# NetBird assigns the peer address at join time, long after apply, so Terraform
# never sees it. The FQDN is derivable though - NetBird names the peer after the
# hostname, which this module already sets - so login by name rather than IP.
# NOT the FQDN. NetBird owns the peer name and rewrites it at registration - a
# reusable setup key may register many machines, so it appends the address
# octets to keep names distinct. That happens after apply, so no output here can
# state the final name. What Terraform does control is this prefix, unique to
# one deployment, which netbird-login.sh uses to FIND the peer instead.
output "netbird_peer_prefix" {
  description = "Per-deployment prefix of the NetBird peer name. The full name may carry a NetBird-appended suffix; match on this rather than assuming an exact FQDN."
  value       = local.netbird_hostname
}

output "root_key_file" {
  description = "Path to the generated root private key, used by netbird-login.sh"
  value       = local_sensitive_file.root_key.filename
}
