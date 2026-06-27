terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = "nsp-sandbox"
}

# DR provider alias — used by the backup module for eu-central-1 resources
provider "aws" {
  alias   = "dr"
  region  = "eu-central-1"
  profile = "nsp-sandbox"
}
