# backend.tf — Stage 2 consumes the backend Stage 1 built.
#
# Same bucket as bootstrap, DIFFERENT key. That is the whole point: one bucket
# holds many independent states, and the lock is scoped to the key, not the
# bucket — so an apply here cannot block an apply in bootstrap/.

terraform {
  backend "s3" {
    bucket       = "tf-state-964291633585-us-east-1"
    key          = "network/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
