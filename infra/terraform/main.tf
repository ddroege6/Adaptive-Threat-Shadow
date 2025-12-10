# 1. Enable Required APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "pubsub.googleapis.com",
    "firestore.googleapis.com",
    "aiplatform.googleapis.com", # Vertex AI
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "logging.googleapis.com",
    "cloudscheduler.googleapis.com"
  ])
  service = each.key
  disable_on_destroy = false
}

# 2. Artifact Registry (To store Docker images)
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "ats-repo"
  description   = "Docker repository for Adaptive Threat Shadow"
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

# 3. Pub/Sub Topic (The Event Bus)
resource "google_pubsub_topic" "osint_events" {
  name = "osint-events-topic"
  depends_on = [google_project_service.apis]
}

# 4. Firestore Database (The Memory)
resource "google_firestore_database" "db" {
  name        = "(default)"
  location_id = "us-central1" # Firestore needs specific location format
  type        = "FIRESTORE_NATIVE"
  depends_on  = [google_project_service.apis]
}

# 5. Service Accounts (Security Best Practice: Least Privilege)

# SA for Collector
resource "google_service_account" "collector_sa" {
  account_id   = "ats-collector-sa"
  display_name = "ATS Collector Service Account"
}

# SA for Analyst
resource "google_service_account" "analyst_sa" {
  account_id   = "ats-analyst-sa"
  display_name = "ATS Analyst Service Account"
}

# 6. IAM Roles (Giving permissions)

# Collector needs to Publish to Pub/Sub
resource "google_project_iam_member" "collector_pubsub" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.collector_sa.email}"
}

# Analyst needs to Read Pub/Sub, Write Firestore, Use Vertex AI
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
  role    = "roles/aiplatform.user" # Required for Gemini
  member  = "serviceAccount:${google_service_account.analyst_sa.email}"
}
resource "google_project_iam_member" "analyst_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.analyst_sa.email}"
}

# Grant the Dashboard permission to READ from the Database
resource "google_project_iam_member" "dashboard_firestore_viewer" {
  project = var.project_id
  role    = "roles/datastore.viewer"
  # IMPORTANT: Change 'dashboard_sa' below to the actual name of the SA used by your dashboard service
  member  = "serviceAccount:ats-dashboard-sa@ats-security-project-2025.iam.gserviceaccount.com" 
}

# 7. Cloud Run Services (The Code Runners)

# Collector Service
resource "google_cloud_run_v2_service" "collector" {
  name     = "ats-collector"
  location = var.region
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.collector_sa.email
    containers {
      # We point to a 'latest' image. We will push this image in Phase 3.
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}/collector:latest"
      env {
        name = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name = "TOPIC_ID"
        value = google_pubsub_topic.osint_events.name
      }
    }
  }
  depends_on = [google_artifact_registry_repository.repo]
}

# Analyst Service
resource "google_cloud_run_v2_service" "analyst" {
  name     = "ats-analyst"
  location = var.region
  ingress = "INGRESS_TRAFFIC_ALL" # Security: Only Pub/Sub can call this

  template {
    service_account = google_service_account.analyst_sa.email
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}/analyst:v3"
      env {
        name = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name = "REGION"
        value = var.region
      }
    }
  }
  depends_on = [google_artifact_registry_repository.repo]
}

# 8. Pub/Sub Subscription (Connecting the pipes)
# This pushes messages from the Topic to the Analyst Service
resource "google_pubsub_subscription" "subscription" {
  name  = "osint-to-analyst-sub"
  topic = google_pubsub_topic.osint_events.name

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.analyst.uri}/process"
    oidc_token {
      service_account_email = google_service_account.analyst_sa.email
    }
  }
}


# Allow the Service Account (used by Pub/Sub) to invoke the Analyst Service
resource "google_cloud_run_service_iam_member" "analyst_invoker" { 
  location = google_cloud_run_v2_service.analyst.location 
  service = google_cloud_run_v2_service.analyst.name 
  role = "roles/run.invoker" 
  member = "serviceAccount:${google_service_account.analyst_sa.email}" 
}

# --- NEW: Dashboard Infrastructure ---

# 1. Dashboard Service Account
resource "google_service_account" "dashboard_sa" {
  account_id   = "ats-dashboard-sa"
  display_name = "ATS Dashboard Service Account"
}

# 2. Grant Permissions (Read-Only)
resource "google_project_iam_member" "dashboard_firestore" {
  project = var.project_id
  role    = "roles/datastore.viewer" # Read-only access to DB
  member  = "serviceAccount:${google_service_account.dashboard_sa.email}"
}

# 3. Dashboard Cloud Run Service
resource "google_cloud_run_v2_service" "dashboard" {
  name     = "ats-dashboard"
  location = var.region
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.dashboard_sa.email
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}/dashboard:latest"
      env {
        name = "PROJECT_ID"
        value = var.project_id
      }
    }
  }
}

# 4. Make Dashboard Public (So you can share the link!)
resource "google_cloud_run_service_iam_member" "public_dashboard" {
  location = google_cloud_run_v2_service.dashboard.location
  service  = google_cloud_run_v2_service.dashboard.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# 5. Output the Dashboard URL
output "dashboard_url" {
  value = google_cloud_run_v2_service.dashboard.uri
}


# --- NEW: Automation & Scheduling ---

# 1. Cloud Scheduler Service Account
# Best Practice: Give the scheduler its own identity
resource "google_service_account" "scheduler_sa" {
  account_id   = "ats-scheduler-sa"
  display_name = "ATS Scheduler Service Account"
}

# 2. Grant Invoker Permission
# Allows this SA to call the Collector Cloud Run service
resource "google_cloud_run_service_iam_member" "scheduler_invoker" {
  location = google_cloud_run_v2_service.collector.location
  service  = google_cloud_run_v2_service.collector.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_sa.email}"
}

# 3. The Job Itself
resource "google_cloud_scheduler_job" "threat_trigger" {
  name             = "ats-hourly-trigger"
  description      = "Triggers the OSINT Collector every hour"
  schedule         = "0 * * * *" # Run at minute 0 of every hour
  time_zone        = "America/Chicago" # Set to your local time
  attempt_deadline = "320s"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.collector.uri}/collect"

    # OIDC Token for secure authentication
    oidc_token {
      service_account_email = google_service_account.scheduler_sa.email
    }
  }
}