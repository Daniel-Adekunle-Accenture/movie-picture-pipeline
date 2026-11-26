provider "aws" {
  region = "us-east-1"

  # Lets leftover checks find everything this project created.
  default_tags {
    tags = {
      Project = "movie-picture-pipeline"
    }
  }
}

# The lab role is denied iam:TagUser, so the IAM user and its policy use this
# provider, which has no default tags.
provider "aws" {
  alias  = "untagged"
  region = "us-east-1"
}

terraform {
  required_version = ">= 1.3.9"

  # State is kept in a private, versioned S3 bucket in the lab account so teardown
  # still works after a workspace reset. setup/bootstrap-state.sh creates the bucket
  # and writes backend.hcl (git-ignored): terraform init -backend-config=backend.hcl
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}
