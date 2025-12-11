# 1. Enable Required APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "pubsub.googleapis.com",
    "firestore.googleapis.com",
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "logging.googleapis.com",
    "cloudscheduler.googleapis.com",
    "iam.googleapis.com",
    "monitoring.googleapis.com"  # Added for monitoring/alerting
  ])
  service = each.key
  disable_on_destroy = false
}

# 2. Artifact Registry
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "ats-repo"
  description   = "Docker repository for Adaptive Threat Shadow"
  format        = "DOCKER"
  
  labels = {
    environment = var.environment
    project     = "adaptive-threat-shadow"
    managed_by  = "terraform"
  }
  
  depends_on = [google_project_service.apis]
}

# 3. Pub/Sub Topic
resource "google_pubsub_topic" "osint_events" {
  name = "osint-events-topic"
  
  labels = {
    environment = var.environment
    project     = "adaptive-threat-shadow"
    managed_by  = "terraform"
  }
  
  depends_on = [google_project_service.apis]
}

# 4. Firestore Database
resource "google_firestore_database" "db" {
  name            = "(default)"
  location_id     = "us-central1"
  type            = "FIRESTORE_NATIVE"
  deletion_policy = "ABANDON"  # Change to "ABANDON" for production to prevent accidental deletion
  depends_on      = [google_project_service.apis]
}

# 5. Service Accounts

resource "google_service_account" "collector_sa" {
  account_id   = "ats-collector-sa"
  display_name = "ATS Collector Service Account"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "analyst_sa" {
  account_id   = "ats-analyst-sa"
  display_name = "ATS Analyst Service Account"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "dashboard_sa" {
  account_id   = "ats-dashboard-sa"
  display_name = "ATS Dashboard Service Account"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "scheduler_sa_final" {
  account_id   = "ats-scheduler-final"
  display_name = "ATS Scheduler Service Account Final"
  depends_on   = [google_project_service.apis]
}

# 6. IAM Roles

# Collector permissions
resource "google_project_iam_member" "collector_pubsub" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.collector_sa.email}"
}

# Analyst permissions
resource "google_project_iam_member" "analyst_pubsub" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.analyst_sa.email}"
}

resource "google_project_iam_member" "analyst_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.analyst_sa.email}"
}

resource "google_project_iam_member" "analyst_vertex" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.analyst_sa.email}"
}

resource "google_project_iam_member" "analyst_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.analyst_sa.email}"
}

# Dashboard permissions
resource "google_project_iam_member" "dashboard_firestore" {
  project = var.project_id
  role    = "roles/datastore.viewer"
  member  = "serviceAccount:${google_service_account.dashboard_sa.email}"
}

# Scheduler permissions
resource "google_project_iam_member" "scheduler_invoker_project_final" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.scheduler_sa_final.email}"
}

# 7. Cloud Run Services

# Collector Service
resource "google_cloud_run_v2_service" "collector" {
  name     = "ats-collector"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"  # SECURITY: Internal + Cloud Scheduler only

  labels = {
    environment = var.environment
    project     = "adaptive-threat-shadow"
    managed_by  = "terraform"
    component   = "collector"
  }

  template {
    service_account = google_service_account.collector_sa.email
    
    labels = {
      environment = var.environment
      component   = "collector"
    }
    
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}/collector:latest"
      
      # Resource limits for cost control and stability
      resources {
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
      }
      
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "TOPIC_ID"
        value = google_pubsub_topic.osint_events.name
      }
    }
    
    # Autoscaling configuration
    scaling {
      min_instance_count = 0
      max_instance_count = 5
    }
  }
  
  depends_on = [
    google_artifact_registry_repository.repo,
    google_service_account.collector_sa,
    google_project_iam_member.collector_pubsub
  ]
}

# Allow scheduler to invoke collector (SECURITY: Only scheduler, not public)
resource "google_cloud_run_v2_service_iam_member" "scheduler_collector_invoker" {
  location = google_cloud_run_v2_service.collector.location
  name     = google_cloud_run_v2_service.collector.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_sa_final.email}"
}

# OPTIONAL: Add your user for debugging (remove in production)
# Uncomment and replace with your email if needed:
# resource "google_cloud_run_v2_service_iam_member" "admin_collector_debug" {
#   location = google_cloud_run_v2_service.collector.location
#   name     = google_cloud_run_v2_service.collector.name
#   role     = "roles/run.invoker"
#   member   = "user:your-email@example.com"
# }

# Analyst Service
resource "google_cloud_run_v2_service" "analyst" {
  name     = "ats-analyst"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"  # SECURITY: Internal only

  labels = {
    environment = var.environment
    project     = "adaptive-threat-shadow"
    managed_by  = "terraform"
    component   = "analyst"
  }

  template {
    service_account = google_service_account.analyst_sa.email
    
    labels = {
      environment = var.environment
      component   = "analyst"
    }
    
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}/analyst:v3"
      
      # Higher resources for AI processing
      resources {
        limits = {
          cpu    = "2000m"
          memory = "1Gi"
        }
      }
      
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "REGION"
        value = var.region
      }
    }
    
    # Autoscaling configuration
    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }
    
    # Longer timeout for AI processing
    timeout = "300s"
  }
  
  depends_on = [
    google_artifact_registry_repository.repo,
    google_service_account.analyst_sa,
    google_project_iam_member.analyst_firestore,
    google_project_iam_member.analyst_vertex
  ]
}

# Allow analyst service account to invoke itself (for Pub/Sub)
resource "google_cloud_run_v2_service_iam_member" "analyst_invoker" {
  location = google_cloud_run_v2_service.analyst.location
  name     = google_cloud_run_v2_service.analyst.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.analyst_sa.email}"
}

# 8. Pub/Sub Subscription
resource "google_pubsub_subscription" "subscription" {
  name  = "osint-to-analyst-sub"
  topic = google_pubsub_topic.osint_events.name

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.analyst.uri}/process"
    oidc_token {
      service_account_email = google_service_account.analyst_sa.email
    }
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.analyst_invoker
  ]
}

# 9. Dashboard Service
resource "google_cloud_run_v2_service" "dashboard" {
  name     = "ats-dashboard"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  labels = {
    environment = var.environment
    project     = "adaptive-threat-shadow"
    managed_by  = "terraform"
    component   = "dashboard"
  }

  template {
    service_account = google_service_account.dashboard_sa.email
    
    labels = {
      environment = var.environment
      component   = "dashboard"
    }
    
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}/dashboard:latest"
      
      resources {
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
      }
      
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
    }
    
    # Autoscaling configuration
    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }
  }
  
  depends_on = [
    google_artifact_registry_repository.repo,
    google_service_account.dashboard_sa,
    google_project_iam_member.dashboard_firestore
  ]
}

# Make Dashboard Public
resource "google_cloud_run_v2_service_iam_member" "public_dashboard" {
  location = google_cloud_run_v2_service.dashboard.location
  name     = google_cloud_run_v2_service.dashboard.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# 10. Cloud Scheduler Job
resource "google_cloud_scheduler_job" "threat_trigger_hash" {
  name             = "ats-hourly-trigger-hash"
  description      = "Trigger collector service hourly"
  schedule         = "0 * * * *"
  time_zone        = "America/Chicago"
  attempt_deadline = "320s"

  http_target {
    http_method = "POST"
    # Full URL with the /collect endpoint
    uri         = "${google_cloud_run_v2_service.collector.uri}/collect"

    oidc_token {
      service_account_email = google_service_account.scheduler_sa_final.email
      # Audience MUST be only the base URL (no path)
      audience              = google_cloud_run_v2_service.collector.uri
    }
  }

  depends_on = [
    google_project_service.apis,
    google_service_account.scheduler_sa_final,
    google_project_iam_member.scheduler_invoker_project_final,
    google_cloud_run_v2_service_iam_member.scheduler_collector_invoker,
    google_cloud_run_v2_service.collector
  ]
}

# Outputs
output "dashboard_url" {
  value       = google_cloud_run_v2_service.dashboard.uri
  description = "Public URL for the Adaptive Threat Shadow dashboard"
}

