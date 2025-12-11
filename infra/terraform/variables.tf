variable "project_id" {
  description = "The GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

# --- NEW VARIABLES ---

variable "environment" {
  description = "The deployment environment (dev, prod, etc.)"
  type        = string
  default     = "dev"
}

variable "alert_email" {
  description = "Email address to receive security alerts"
  type        = string
  # No default value -> forces you to set it in terraform.tfvars
}