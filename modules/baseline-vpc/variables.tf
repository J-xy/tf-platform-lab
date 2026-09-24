# variables.tf — inputs for the network stack.

variable "name_prefix" {
  description = "Prefix for Name tags, so resources are not all called \"main\"."
  type        = string
  default     = "tf-lab"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.name_prefix))
    error_message = "name_prefix must be 3-32 characters: lowercase letters, numbers, and hyphens only."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be /16."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) == 16
    error_message = "vpc_cidr must be a /16 CIDR block (e.g. 10.0.0.0/16)."
  }
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional tags merged onto every resource."
  default     = {}
}

# TODO: not yet wired into main.tf. NAT gateway creation is a later stage.
variable "enable_nat" {
  description = "Whether to provision a NAT gateway for private subnet egress. Defaults to false — NAT costs ~$0.045/hr plus per-GB processing, so it must be an explicit opt-in."
  type        = bool
  default     = false
}
