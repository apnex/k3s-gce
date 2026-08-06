# The exact strings to use on the right-hand side of a VM's env_secret_map.
output "containers" {
  description = "Container names created here"
  value       = sort([for s in google_secret_manager_secret.this : s.secret_id])
}
