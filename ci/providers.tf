provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      owner        = "jack"
      project      = "tf-platform-lab"
      stage        = "3-ci"
      "managed-by" = "terraform"
    }
  }
}
