variable "github_repo" {
  description = "GitHub repository allowed to assume the CI role, as owner/name."
  type        = string
  default     = "J-xy/tf-platform-lab"

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repo))
    error_message = "github_repo must be in owner/name form."
  }
}

variable "state_bucket" {
  description = "State bucket the CI role needs to read, and lock against."
  type        = string
  default     = "tf-state-964291633585-us-east-1"
}
