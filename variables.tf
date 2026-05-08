variable "service_account_key_path" {
  type        = string
  description = "Path to the STACKIT service account key JSON"
}

variable "bootstrap_project_id" {
  type        = string
  description = "Bootstrap project ID used to discover parent container and default owner if project is created"
  default     = ""
}

variable "project_id" {
  type        = string
  description = "Existing target project ID (used when create_project = false)"
  default     = ""
}

variable "create_project" {
  type        = bool
  description = "Create a dedicated target project for this example"
  default     = false
}

variable "parent_container_id" {
  type        = string
  description = "Folder/organization container ID for project creation"
  default     = ""
}

variable "target_project_name" {
  type        = string
  description = "Name of target project when create_project = true"
  default     = "cmf-replatform-springboot-k8s"
}

variable "target_project_owner_email" {
  type        = string
  description = "Owner email for project creation; defaults to service account email"
  default     = ""
}

variable "region" {
  type        = string
  description = "STACKIT region"
  default     = "eu01"
}

variable "availability_zone" {
  type        = string
  description = "Availability zone for the small SKE node pool"
  default     = "eu01-1"
}

variable "ske_cluster_name" {
  type        = string
  description = "SKE cluster name"
  default     = "cmf-rpltf"

  validation {
    condition     = length(var.ske_cluster_name) > 0 && length(var.ske_cluster_name) <= 11
    error_message = "SKE cluster name must be between 1 and 11 characters."
  }
}

variable "kubernetes_version_min" {
  type        = string
  description = "Minimum Kubernetes version for the cluster"
  default     = "1.35.4"
}

variable "node_pool_name" {
  type        = string
  description = "SKE node pool name"
  default     = "small"
}

variable "node_pool_machine_type" {
  type        = string
  description = "SKE machine type for cost-effective node pool"
  default     = "g3i.4"
}

variable "node_pool_minimum" {
  type        = number
  description = "Minimum nodes in pool"
  default     = 1
}

variable "node_pool_maximum" {
  type        = number
  description = "Maximum nodes in pool"
  default     = 1
}

variable "node_pool_volume_size" {
  type        = number
  description = "Node pool root volume size in GB"
  default     = 20
}

variable "observability_enabled" {
  type        = bool
  description = "Create and integrate STACKIT Observability instance"
  default     = true
}

variable "create_observability_instance" {
  type        = bool
  description = "Create observability instance resource; set false to reuse an existing instance"
  default     = true
}

variable "existing_observability_instance_id" {
  type        = string
  description = "Existing observability instance ID used when create_observability_instance=false"
  default     = ""

  validation {
    condition = !var.observability_enabled || var.create_observability_instance || trimspace(var.existing_observability_instance_id) != ""
    error_message = "Set existing_observability_instance_id when observability_enabled=true and create_observability_instance=false."
  }
}

variable "observability_ready_wait_duration" {
  type        = string
  description = "Wait duration before configuring observability-dependent resources after creating an instance"
  default     = "300s"
}

variable "observability_instance_name" {
  type        = string
  description = "Name of the Observability instance"
  default     = "cmf-replatform-observability"
}

variable "observability_plan_name" {
  type        = string
  description = "Observability plan name"
  default     = "Observability-Starter-EU01"
}

variable "enable_observability_alerts" {
  type        = bool
  description = "Create baseline observability alert rules for SKE and Spring Boot"
  default     = true
}

variable "create_grafana_dashboard" {
  type        = bool
  description = "Import a starter Grafana dashboard for SKE and Spring Boot"
  default     = true
}

variable "dns_enabled" {
  type        = bool
  description = "Create and integrate DNS zone for external-dns"
  default     = true
}

variable "create_dns_zone" {
  type        = bool
  description = "Create DNS zone resource in target project; set false to reuse an existing delegated zone"
  default     = true
}

variable "dns_zone_name" {
  type        = string
  description = "Subzone under the free STACKIT runs.onstackit.cloud domain pool"
  default     = "cmf-{rand}.runs.onstackit.cloud"
}

variable "dns_zone_display_name" {
  type        = string
  description = "Display name for DNS zone resource"
  default     = "cmf-zone-{rand}"
}

variable "dns_contact_email" {
  type        = string
  description = "Contact email for DNS SOA"
  default     = ""
}

variable "deploy_workload" {
  type        = bool
  description = "Deploy Spring Boot workload directly via Terraform Kubernetes provider"
  default     = true
}

variable "k8s_namespace" {
  type        = string
  description = "Namespace for Spring Boot workload"
  default     = "springboot"
}

variable "springboot_image" {
  type        = string
  description = "Container image for Spring Boot application"
  default     = "yanivomc/spring-music:latest"
}

variable "springboot_container_port" {
  type        = number
  description = "Container port exposed by Spring Boot app"
  default     = 8080
}

variable "springboot_replicas" {
  type        = number
  description = "Initial replica count"
  default     = 1
}

variable "enable_springboot_hpa" {
  type        = bool
  description = "Enable Horizontal Pod Autoscaler for the Spring Boot deployment"
  default     = false
}

variable "springboot_hpa_min_replicas" {
  type        = number
  description = "Minimum Spring Boot replicas when HPA is enabled"
  default     = 1
}

variable "springboot_hpa_max_replicas" {
  type        = number
  description = "Maximum Spring Boot replicas when HPA is enabled"
  default     = 3
}

variable "springboot_hpa_target_cpu_utilization_percentage" {
  type        = number
  description = "Target average CPU utilization percentage for Spring Boot HPA"
  default     = 70
}

variable "app_subdomain" {
  type        = string
  description = "Subdomain label for ingress hostname"
  default     = "springboot"
}

variable "enable_ingress" {
  type        = bool
  description = "Create Kubernetes Ingress resource (requires ingress controller in cluster)"
  default     = false
}

variable "wait_for_workload_endpoint" {
  type        = bool
  description = "Wait until workload endpoint is reachable via DNS and HTTP after deployment"
  default     = true
}

variable "workload_endpoint_wait_timeout_seconds" {
  type        = number
  description = "Maximum time in seconds to wait for DNS + HTTP endpoint readiness"
  default     = 900
}

variable "workload_endpoint_wait_interval_seconds" {
  type        = number
  description = "Polling interval in seconds while waiting for endpoint readiness"
  default     = 10
}

variable "observability_metrics_warmup_duration" {
  type        = string
  description = "Additional wait after endpoint readiness before importing Grafana dashboard"
  default     = "120s"
}

variable "enable_load_generator" {
  type        = bool
  description = "Deploy a lightweight pod that generates random HTTP load against Spring Boot"
  default     = false
}

variable "load_profile" {
  type        = string
  description = "Random load profile preset: low, medium, high, spiky, custom"
  default     = "medium"

  validation {
    condition     = contains(["low", "medium", "high", "spiky", "custom"], var.load_profile)
    error_message = "load_profile must be one of: low, medium, high, spiky, custom."
  }
}

variable "load_generator_replicas" {
  type        = number
  description = "Number of load generator replicas"
  default     = 1
}

variable "load_generator_min_requests_per_cycle" {
  type        = number
  description = "Minimum number of requests in one randomized burst"
  default     = 2
}

variable "load_generator_max_requests_per_cycle" {
  type        = number
  description = "Maximum number of requests in one randomized burst"
  default     = 15
}

variable "load_generator_min_pause_seconds" {
  type        = number
  description = "Minimum pause between randomized bursts in seconds"
  default     = 1
}

variable "load_generator_max_pause_seconds" {
  type        = number
  description = "Maximum pause between randomized bursts in seconds"
  default     = 6
}

variable "enable_springboot_metrics_scrape" {
  type        = bool
  description = "Create observability scrape config for converted Spring Boot metrics"
  default     = true
}

variable "springboot_metrics_exporter_port" {
  type        = number
  description = "Port exposed by the sidecar exporter that converts legacy /metrics JSON to Prometheus format"
  default     = 9090
}

variable "springboot_metrics_scrape_interval" {
  type        = string
  description = "Scrape interval for Spring Boot metrics exporter"
  default     = "61s"
}

variable "springboot_metrics_scrape_timeout" {
  type        = string
  description = "Scrape timeout for Spring Boot metrics exporter"
  default     = "10s"
}
