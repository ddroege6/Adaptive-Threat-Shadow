# Remote State Backend Configuration
# This stores your Terraform state in Google Cloud Storage for:
# - Team collaboration
# - State locking (prevents concurrent modifications)
# - State versioning and backup
# - Disaster recovery

# Remote State Backend Configuration
terraform {
  backend "gcs" {
    bucket = "ats-terraform-state-bucket" 
    prefix = "terraform/state"
  }
  
  required_version = ">= 1.0"
}