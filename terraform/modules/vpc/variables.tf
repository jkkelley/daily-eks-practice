# No defaults - all values are threaded from the stack (ultimately scripts/config.toml).

variable "name_prefix" { type = string }
variable "cluster_name" {
  description = "Cluster name - used for Kubernetes subnet discovery tags."
  type        = string
}
variable "vpc_cidr" { type = string }
variable "az_count" { type = number }
variable "public_subnet_cidrs" { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "enable_nat_gateway" { type = bool }
variable "single_nat_gateway" { type = bool }
variable "enable_vpc_endpoints" { type = bool }
variable "tags" { type = map(string) }
