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

output "vm_sa_email" {
  description = "Email of the VM runtime service account"
  value       = google_service_account.vm.email
}

output "ssh_command" {
  description = "Connect via IAP tunnel (sudo -i for root once in)"
  value       = "gcloud compute ssh ${google_compute_instance.vm.name} --zone=${var.zone} --project=${var.project_id} --tunnel-through-iap"
}

output "ssh_target_sa_email" {
  description = "Email of the inbound SSH login SA (null when disabled). The org-level osLoginExternalUser + serviceAccountUser grants attach to this identity."
  value       = var.enable_ssh_target_login ? google_service_account.ssh_target[0].email : null
}

output "ssh_target_user" {
  description = "OS Login POSIX username the in-pod wrapper logs in as (null when disabled)"
  value       = var.enable_ssh_target_login ? "sa_${google_service_account.ssh_target[0].unique_id}" : null
}
