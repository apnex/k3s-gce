output "vm_name" {
  value = module.k3s_vm.vm_name
}

output "vm_internal_ip" {
  value = module.k3s_vm.vm_internal_ip
}

output "vm_zone" {
  value = module.k3s_vm.vm_zone
}

output "ssh_command" {
  value = module.k3s_vm.ssh_command
}

output "ssh_target_sa_email" {
  description = "Inbound SSH login SA — grant org-level osLoginExternalUser + serviceAccountUser to this identity"
  value       = module.k3s_vm.ssh_target_sa_email
}

output "ssh_target_user" {
  value = module.k3s_vm.ssh_target_user
}
