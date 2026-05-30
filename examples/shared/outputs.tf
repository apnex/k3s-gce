output "scope" {
  description = "The shared-scope label VMs use to reference these secrets"
  value       = var.scope
}

output "containers" {
  description = "Created shared container names"
  value       = [for k, v in local.containers : v]
}
