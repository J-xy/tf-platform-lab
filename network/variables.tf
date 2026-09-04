# variables.tf — inputs for the network stack.

variable "name_prefix" {
  description = "Prefix for Name tags, so resources are not all called \"main\"."
  type        = string
  default     = "tf-lab"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. A /16 leaves room to carve subnets."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    # Catches the common paste-error of a host address (10.0.0.1/16) or a
    # block too small to subnet. cidrhost() throws on a malformed CIDR.
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid CIDR block of /20 or larger (e.g. 10.0.0.0/16)."
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
