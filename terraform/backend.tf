terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "fincorp-tfstate-265267290744"
    key          = "fincorp/pipeline/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
  }
}
