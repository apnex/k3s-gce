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
