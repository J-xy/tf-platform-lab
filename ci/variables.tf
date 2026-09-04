# GitHub now issues IMMUTABLE subject claims. The sub is not
#   repo:OWNER/NAME:pull_request
# as most documentation still shows, but
#   repo:OWNER@<owner_id>/NAME@<repo_id>:pull_request
# with the numeric account and repository IDs embedded. The IDs are what make
# the claim immutable: renaming or transferring the repo does not change them,
# so a trust policy pinned to them cannot be inherited by whoever claims the
# old name afterwards.
#
# Read them from the token itself, or:
#   gh api repos/OWNER/NAME --jq '{repo: .id, owner: .owner.id}'

variable "github_owner" {
  description = "GitHub account that owns the repository."
  type        = string
  default     = "J-xy"
}

variable "github_owner_id" {
  description = "Numeric ID of the GitHub account. Immutable across renames."
  type        = string
  default     = "68347443"
}

variable "github_repo_name" {
  description = "Repository name."
  type        = string
  default     = "tf-platform-lab"
}

variable "github_repo_id" {
  description = "Numeric ID of the repository. Immutable across renames."
  type        = string
  default     = "1355558109"
}

variable "state_bucket" {
  description = "State bucket the CI role needs to read, and lock against."
  type        = string
  default     = "tf-state-964291633585-us-east-1"
}
