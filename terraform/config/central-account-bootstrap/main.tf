provider "aws" {
  region = var.region
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Shared GitHub Connection - authorize once, use everywhere
resource "aws_codestarconnections_connection" "github_shared" {
  name          = "rosa-regional-github-shared"
  provider_type = "GitHub"
}

# Platform Image ECR Repository
module "platform_image" {
  source = "../../modules/platform-image"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  resource_name_base = "rosa-regional"
  tags = {
    Name        = "rosa-regional-platform-image"
    Environment = var.environment
  }
}

module "pipeline_provisioner" {
  source = "../../modules/pipeline-provisioner"

  github_repository     = var.github_repository
  github_branch         = var.github_branch
  region                = var.region
  environment           = var.environment
  github_connection_arn = aws_codestarconnections_connection.github_shared.arn
  codebuild_image       = module.platform_image.container_image
}
