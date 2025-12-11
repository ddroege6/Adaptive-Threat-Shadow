# Monitoring and Alerting Configuration

# Notification Channel (Email)
resource "google_monitoring_notification_channel" "email" {
  display_name = "ATS Admin Email"
  type         = "email"
  
  labels = {
    email_address = var.alert_email
  }
  
  enabled = true
}

# Alert Policy: High Error Rate on Collector
resource "google_monitoring_alert_policy" "collector_errors" {
  display_name = "ATS Collector - High Error Rate"
  combiner     = "OR"
  
  conditions {
    display_name = "Error rate above 10%"
    
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"ats-collector\" AND metric.type=\"run.googleapis.com/request_count\" AND metric.labels.response_code_class=\"5xx\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }
  
  notification_channels = [google_monitoring_notification_channel.email.id]
  
  alert_strategy {
    auto_close = "1800s"
  }
  
  depends_on = [google_project_service.apis]
}

# Alert Policy: Analyst Service Down
resource "google_monitoring_alert_policy" "analyst_down" {
  display_name = "ATS Analyst - Service Unavailable"
  combiner     = "OR"
  
  conditions {
    display_name = "No successful requests in 10 minutes"
    
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"ats-analyst\" AND metric.type=\"run.googleapis.com/request_count\" AND metric.labels.response_code_class=\"2xx\""
      duration        = "600s"
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }
  
  notification_channels = [google_monitoring_notification_channel.email.id]
  
  alert_strategy {
    auto_close = "1800s"
  }
  
  depends_on = [google_project_service.apis]
}

# Alert Policy: Dashboard High Latency
resource "google_monitoring_alert_policy" "dashboard_latency" {
  display_name = "ATS Dashboard - High Latency"
  combiner     = "OR"
  
  conditions {
    display_name = "Request latency above 2 seconds"
    
    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"ats-dashboard\" AND metric.type=\"run.googleapis.com/request_latencies\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 2000  # milliseconds
      
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_PERCENTILE_95"
      }
    }
  }
  
  notification_channels = [google_monitoring_notification_channel.email.id]
  
  alert_strategy {
    auto_close = "1800s"
  }
  
  depends_on = [google_project_service.apis]
}

# Alert Policy: Firestore High Write Rate (Cost Control)
resource "google_monitoring_alert_policy" "firestore_high_writes" {
  display_name = "ATS Firestore - Unusually High Write Rate"
  combiner     = "OR"
  
  conditions {
    display_name = "Write rate above 100/min"
    
    condition_threshold {
      filter          = "resource.type=\"firestore.googleapis.com/Database\" AND metric.type=\"firestore.googleapis.com/api/request_count\" AND metric.label.response_code=\"OK\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 500
      
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }
  
  notification_channels = [google_monitoring_notification_channel.email.id]
  
  alert_strategy {
    auto_close = "1800s"
  }
  
  depends_on = [google_project_service.apis]
}

# Log-based Metric: Critical Errors
resource "google_logging_metric" "critical_errors" {
  name   = "ats-critical-errors"
  filter = "resource.type=\"cloud_run_revision\" AND (resource.labels.service_name=\"ats-collector\" OR resource.labels.service_name=\"ats-analyst\") AND severity>=ERROR"
  
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    
    labels {
      key         = "service"
      value_type  = "STRING"
      description = "Service name"
    }
  }
  
  label_extractors = {
    "service" = "EXTRACT(resource.labels.service_name)"
  }
}