output "vm_name" {
  description = "Name of the k3s VM"
  value       = google_compute_instance.vm.name
}

output "vm_internal_ip" {
  description = "Static internal IP of the VM"
  value       = google_compute_address.vm_internal.address
}

output "vm_zone" {
  description = "Zone the VM lives in"
  value       = google_compute_instance.vm.zone
}

output "network_tags" {
  description = "Network tags applied to the VM. Target these from your IAP-SSH firewall rule."
  value       = local.network_tags
}

output "vm_sa_email" {
  description = "Email of the VM runtime service account"
  value       = google_service_account.vm.email
}

output "ssh_command" {
  description = "Connect via IAP tunnel (sudo -i for root once in)"
  value       = "gcloud compute ssh ${google_compute_instance.vm.name} --zone=${var.zone} --project=${var.project_id} --tunnel-through-iap"
}

