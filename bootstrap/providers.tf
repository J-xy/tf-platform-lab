# providers.tf — AWS client configuration.
#
# default_tags applies these to every taggable resource the provider creates,
# so individual resource blocks carry no tags argument. Note the DynamoDB table
# and the S3 bucket both pick these up; the bucket sub-resources (versioning,
# encryption, public access block) are not taggable objects in their own right.

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      owner        = "jack"
      project      = "tf-platform-lab"
      "managed-by" = "terraform"
    }
  }
}
