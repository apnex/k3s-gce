output "network_name" {
  description = "Name of the VPC"
  value       = google_compute_network.vpc.name
}

# What ../vm wants: it looks the subnet up by name, so this is the value to copy
# into its subnet_name.
output "subnet_name" {
  description = "Name of the subnet. Pass this as subnet_name to the vm root."
  value       = google_compute_subnetwork.subnet.name
}

output "subnet_self_link" {
  description = "Self link of the subnet"
  value       = google_compute_subnetwork.subnet.self_link
}

output "region" {
  description = "Region the subnet lives in. The vm root's zone must be inside it."
  value       = google_compute_subnetwork.subnet.region
}
