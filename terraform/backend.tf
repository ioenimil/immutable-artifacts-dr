terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "fincorp-tfstate-486128667962"
    key          = "fincorp/pipeline/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
  }
}
