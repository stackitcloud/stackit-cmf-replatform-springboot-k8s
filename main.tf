locals {
  sa_key = jsondecode(file(pathexpand(var.service_account_key_path)))

  bootstrap_project_id = var.bootstrap_project_id != "" ? var.bootstrap_project_id : local.sa_key.projectId
  project_owner_email  = var.target_project_owner_email != "" ? var.target_project_owner_email : local.sa_key.credentials.iss
  dns_contact_email    = var.dns_contact_email != "" ? var.dns_contact_email : local.project_owner_email
  use_bootstrap_lookup = var.create_project && var.parent_container_id == ""

}

data "stackit_resourcemanager_project" "bootstrap" {
  count = local.use_bootstrap_lookup ? 1 : 0

  project_id = local.bootstrap_project_id
}

resource "stackit_resourcemanager_project" "cmf_project" {
  count = var.create_project ? 1 : 0

  name                = var.target_project_name
  owner_email         = local.project_owner_email
  parent_container_id = var.parent_container_id != "" ? var.parent_container_id : data.stackit_resourcemanager_project.bootstrap[0].parent_container_id
}

locals {
  effective_project_id                = var.create_project ? stackit_resourcemanager_project.cmf_project[0].project_id : (var.project_id != "" ? var.project_id : local.bootstrap_project_id)
  create_dns_with_random_suffix       = var.dns_enabled && var.create_dns_zone && strcontains(var.dns_zone_name, "{rand}")
  effective_dns_zone_name             = local.create_dns_with_random_suffix ? replace(var.dns_zone_name, "{rand}", tostring(random_integer.dns_suffix[0].result)) : var.dns_zone_name
  effective_dns_zone_display          = local.create_dns_with_random_suffix ? replace(var.dns_zone_display_name, "{rand}", tostring(random_integer.dns_suffix[0].result)) : var.dns_zone_display_name
  effective_dns_zones                 = var.dns_enabled ? (var.create_dns_zone ? [stackit_dns_zone.cmf_zone[0].dns_name] : [local.effective_dns_zone_name]) : []
  app_fqdn                            = "${var.app_subdomain}.${local.effective_dns_zone_name}"
  effective_observability_instance_id = var.observability_enabled ? (var.create_observability_instance ? stackit_observability_instance.replatform_obs[0].instance_id : var.existing_observability_instance_id) : null
  observability_integration_enabled   = var.observability_enabled && (var.create_observability_instance || var.existing_observability_instance_id != "")

  load_profile_presets = {
    low = {
      min_requests = 2
      max_requests = 6
      min_pause    = 3
      max_pause    = 8
    }
    medium = {
      min_requests = 4
      max_requests = 15
      min_pause    = 1
      max_pause    = 5
    }
    high = {
      min_requests = 10
      max_requests = 40
      min_pause    = 1
      max_pause    = 3
    }
    spiky = {
      min_requests = 1
      max_requests = 80
      min_pause    = 2
      max_pause    = 10
    }
  }

  load_profile_effective = var.load_profile == "custom" ? {
    min_requests = var.load_generator_min_requests_per_cycle
    max_requests = var.load_generator_max_requests_per_cycle
    min_pause    = var.load_generator_min_pause_seconds
    max_pause    = var.load_generator_max_pause_seconds
  } : local.load_profile_presets[var.load_profile]

  postgres_flex_host     = try(stackit_postgresflex_user.app[0].host, "")
  postgres_flex_port     = try(stackit_postgresflex_user.app[0].port, 5432)
  postgres_flex_password = try(stackit_postgresflex_user.app[0].password, "")
  postgres_flex_jdbc_url = var.enable_postgres_flex ? "jdbc:postgresql://${local.postgres_flex_host}:${local.postgres_flex_port}/${var.postgres_flex_target_database}" : ""

  source_postgres_host_is_ipv4 = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.source_postgres_host))
  source_postgres_host_cidr    = local.source_postgres_host_is_ipv4 ? "${var.source_postgres_host}/32" : ""

  postgres_flex_effective_app_acl_cidrs = length(var.postgres_flex_acl) > 0 ? var.postgres_flex_acl : var.postgres_flex_target_app_acl_cidrs
  postgres_flex_effective_temp_acl_cidrs = distinct(compact(concat(
    var.postgres_flex_temp_migration_acl_cidrs,
    var.include_source_postgres_host_in_temp_acl ? [local.source_postgres_host_cidr] : []
  )))
  postgres_flex_effective_acl_cidrs = distinct(compact(concat(
    local.postgres_flex_effective_app_acl_cidrs,
    local.postgres_flex_effective_temp_acl_cidrs
  )))
}

resource "random_integer" "dns_suffix" {
  count = local.create_dns_with_random_suffix ? 1 : 0

  min = 1000
  max = 9999
}

resource "stackit_observability_instance" "replatform_obs" {
  count = var.observability_enabled && var.create_observability_instance ? 1 : 0

  project_id = local.effective_project_id
  name       = var.observability_instance_name
  plan_name  = var.observability_plan_name

  lifecycle {
    ignore_changes = all
  }
}

resource "time_sleep" "observability_ready" {
  count = var.observability_enabled && var.create_observability_instance ? 1 : 0

  create_duration = var.observability_ready_wait_duration
  depends_on      = [stackit_observability_instance.replatform_obs]
}

resource "stackit_observability_alertgroup" "ske_baseline" {
  count = var.observability_enabled && var.enable_observability_alerts ? 1 : 0

  project_id  = local.effective_project_id
  instance_id = local.effective_observability_instance_id
  name        = "${var.ske_cluster_name}-baseline"
  interval    = "60s"

  rules = concat(
    [
      {
        alert      = "SKEClusterNodeNotReady"
        expression = "kube_node_status_condition{condition=\"Ready\",status=\"false\"} > 0"
        for        = "5m"
        labels = {
          severity = "critical"
          scope    = "ske"
        }
        annotations = {
          summary     = "At least one SKE node is not Ready"
          description = "A Kubernetes node in the cluster reports Ready=false for at least 5 minutes."
        }
      },
      {
        alert      = "SpringbootPodCrashLoopRisk"
        expression = "sum(increase(kube_pod_container_status_restarts_total{namespace=\"${var.k8s_namespace}\"}[10m])) > 3"
        for        = "10m"
        labels = {
          severity = "warning"
          scope    = "springboot"
        }
        annotations = {
          summary     = "Spring Boot pods restart repeatedly"
          description = "Pod restart count in namespace ${var.k8s_namespace} increased significantly in the last 10 minutes."
        }
      }
    ],
    var.enable_postgres_flex && var.enable_postgres_flex_metrics_scrape ? [
      {
        alert      = "PostgresFlexExporterDown"
        expression = "max(pg_up) == 0"
        for        = "5m"
        labels = {
          severity = "critical"
          scope    = "postgres-flex"
        }
        annotations = {
          summary     = "PostgreSQL Flex exporter cannot reach the database"
          description = "pg_up is 0 for at least 5 minutes."
        }
      },
      {
        alert      = "PostgresFlexConnectionLimitWarning"
        expression = "(sum(pg_stat_activity_count{state=\"active\"}) / max(pg_settings_max_connections)) > 0.8"
        for        = "10m"
        labels = {
          severity = "warning"
          scope    = "postgres-flex"
        }
        annotations = {
          summary     = "PostgreSQL Flex active connections exceed 80%"
          description = "Active database connections are above 80% of max_connections for at least 10 minutes."
        }
      },
      {
        alert      = "PostgresFlexCacheHitRatioLow"
        expression = "(sum(rate(pg_stat_database_blks_hit[5m])) / (sum(rate(pg_stat_database_blks_hit[5m])) + sum(rate(pg_stat_database_blks_read[5m])))) < 0.95"
        for        = "15m"
        labels = {
          severity = "warning"
          scope    = "postgres-flex"
        }
        annotations = {
          summary     = "PostgreSQL Flex cache hit ratio is below 95%"
          description = "The cache hit ratio stayed below 95% for at least 15 minutes."
        }
      },
      {
        alert      = "PostgresFlexTempFileUsage"
        expression = "sum(rate(pg_stat_database_temp_bytes[5m])) > 0"
        for        = "15m"
        labels = {
          severity = "warning"
          scope    = "postgres-flex"
        }
        annotations = {
          summary     = "PostgreSQL Flex temp file usage detected"
          description = "Temporary files are continuously written for at least 15 minutes."
        }
      }
    ] : []
  )

  depends_on = [time_sleep.observability_ready]
}

resource "stackit_dns_zone" "cmf_zone" {
  count = var.dns_enabled && var.create_dns_zone ? 1 : 0

  project_id    = local.effective_project_id
  name          = local.effective_dns_zone_display
  dns_name      = local.effective_dns_zone_name
  contact_email = local.dns_contact_email
  type          = "primary"
}

resource "stackit_postgresflex_instance" "app" {
  count = var.enable_postgres_flex ? 1 : 0

  project_id      = local.effective_project_id
  name            = var.postgres_flex_instance_name
  acl             = local.postgres_flex_effective_acl_cidrs
  backup_schedule = var.postgres_flex_backup_schedule
  version         = var.postgres_flex_version
  replicas        = var.postgres_flex_replicas

  flavor = {
    cpu = var.postgres_flex_cpu
    ram = var.postgres_flex_ram
  }

  storage = {
    class = var.postgres_flex_storage_class
    size  = var.postgres_flex_storage_size
  }
}

resource "stackit_postgresflex_user" "app" {
  count = var.enable_postgres_flex ? 1 : 0

  project_id  = local.effective_project_id
  instance_id = stackit_postgresflex_instance.app[0].instance_id
  username    = var.postgres_flex_app_username
  roles       = var.postgres_flex_app_roles
}

resource "stackit_ske_cluster" "replatform" {
  project_id             = local.effective_project_id
  name                   = var.ske_cluster_name
  kubernetes_version_min = var.kubernetes_version_min

  node_pools = [
    {
      name               = var.node_pool_name
      machine_type       = var.node_pool_machine_type
      minimum            = var.node_pool_minimum
      maximum            = var.node_pool_maximum
      availability_zones = [var.availability_zone]
      volume_size        = var.node_pool_volume_size
      volume_type        = "storage_premium_perf1"
      os_name            = "flatcar"
    }
  ]

  network = {
    control_plane = {
      access_scope = "PUBLIC"
    }
  }

  maintenance = {
    enable_kubernetes_version_updates    = true
    enable_machine_image_version_updates = true
    start                                = "01:00:00Z"
    end                                  = "02:00:00Z"
  }

  extensions = {
    observability = {
      enabled     = local.observability_integration_enabled
      instance_id = local.effective_observability_instance_id
    }
    dns = {
      enabled = var.dns_enabled
      zones   = local.effective_dns_zones
    }
  }

  depends_on = [time_sleep.observability_ready]
}

resource "kubernetes_namespace_v1" "springboot" {
  count = var.deploy_workload ? 1 : 0

  metadata {
    name = var.k8s_namespace
  }

  depends_on = [stackit_ske_kubeconfig.replatform]
}

resource "kubernetes_secret_v1" "springboot_db" {
  count = var.deploy_workload && var.enable_postgres_flex ? 1 : 0

  metadata {
    name      = "springboot-db-credentials"
    namespace = kubernetes_namespace_v1.springboot[0].metadata[0].name
  }

  data = {
    SPRING_DATASOURCE_URL      = local.postgres_flex_jdbc_url
    SPRING_DATASOURCE_USERNAME = var.postgres_flex_app_username
    SPRING_DATASOURCE_PASSWORD = local.postgres_flex_password
  }

  type = "Opaque"

  depends_on = [stackit_postgresflex_user.app]
}

resource "kubernetes_secret_v1" "source_postgres" {
  count = var.deploy_workload && var.enable_postgres_flex && var.deploy_postgres_migration_job ? 1 : 0

  metadata {
    name      = "source-postgres-credentials"
    namespace = kubernetes_namespace_v1.springboot[0].metadata[0].name
  }

  data = {
    SOURCE_HOST     = var.source_postgres_host
    SOURCE_PORT     = tostring(var.source_postgres_port)
    SOURCE_DATABASE = var.source_postgres_database
    SOURCE_USERNAME = var.source_postgres_username
    SOURCE_PASSWORD = var.source_postgres_password
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "springboot" {
  count = var.deploy_workload ? 1 : 0

  metadata {
    name      = "springboot"
    namespace = kubernetes_namespace_v1.springboot[0].metadata[0].name
    labels = {
      app = "springboot"
    }
  }

  spec {
    replicas = var.springboot_replicas

    selector {
      match_labels = {
        app = "springboot"
      }
    }

    template {
      metadata {
        labels = {
          app = "springboot"
        }
      }

      spec {
        container {
          image = var.springboot_image
          name  = "springboot"

          env {
            name  = "JAVA_TOOL_OPTIONS"
            value = "-Xms128m -Xmx512m"
          }

          dynamic "env" {
            for_each = var.enable_postgres_flex ? {
              SPRING_DATASOURCE_URL      = "SPRING_DATASOURCE_URL"
              SPRING_DATASOURCE_USERNAME = "SPRING_DATASOURCE_USERNAME"
              SPRING_DATASOURCE_PASSWORD = "SPRING_DATASOURCE_PASSWORD"
            } : {}

            content {
              name = env.key
              value_from {
                secret_key_ref {
                  name = kubernetes_secret_v1.springboot_db[0].metadata[0].name
                  key  = env.value
                }
              }
            }
          }

          port {
            container_port = var.springboot_container_port
          }

          startup_probe {
            http_get {
              path = "/"
              port = var.springboot_container_port
            }
            # Older Spring Boot images can need multiple minutes for full bootstrap.
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 10
            failure_threshold     = 60
          }

          liveness_probe {
            http_get {
              path = "/"
              port = var.springboot_container_port
            }
            initial_delay_seconds = 120
            period_seconds        = 20
            timeout_seconds       = 10
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/"
              port = var.springboot_container_port
            }
            initial_delay_seconds = 60
            period_seconds        = 10
            timeout_seconds       = 10
            failure_threshold     = 12
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
        }

        dynamic "container" {
          for_each = var.enable_postgres_flex && var.enable_postgres_flex_exporter ? [1] : []

          content {
            name  = "postgres-flex-exporter"
            image = "quay.io/prometheuscommunity/postgres-exporter:v0.16.0"

            env {
              name  = "DATA_SOURCE_URI"
              value = "${local.postgres_flex_host}:${local.postgres_flex_port}/${var.postgres_flex_target_database}?sslmode=require"
            }

            env {
              name  = "DATA_SOURCE_USER"
              value = var.postgres_flex_app_username
            }

            env {
              name  = "DATA_SOURCE_PASS"
              value = local.postgres_flex_password
            }

            port {
              container_port = var.postgres_flex_exporter_port
            }

            resources {
              requests = {
                cpu    = "20m"
                memory = "64Mi"
              }
              limits = {
                cpu    = "200m"
                memory = "256Mi"
              }
            }
          }
        }

        container {
          name  = "metrics-exporter"
          image = "python:3.12-alpine"

          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            set -eu
            cat >/tmp/exporter.py <<'PY'
            import json
            import urllib.request
            from http.server import BaseHTTPRequestHandler, HTTPServer

            TARGET = "http://127.0.0.1:${var.springboot_container_port}/metrics"

            def esc(value: str) -> str:
                return value.replace("\\", "\\\\").replace('"', '\\"')

            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    if not self.path.startswith("/metrics"):
                        self.send_response(404)
                        self.end_headers()
                        return
                    try:
                        req = urllib.request.Request(TARGET, headers={"Accept": "application/json"})
                        with urllib.request.urlopen(req, timeout=5) as resp:
                            payload = resp.read().decode("utf-8")
                        data = json.loads(payload)
                    except Exception:
                        self.send_response(503)
                        self.end_headers()
                        return

                    lines = [
                        "# HELP springboot_legacy_counter Spring Boot legacy counter metrics",
                        "# TYPE springboot_legacy_counter gauge",
                        "# HELP springboot_legacy_gauge Spring Boot legacy gauge metrics",
                        "# TYPE springboot_legacy_gauge gauge",
                        "# HELP springboot_legacy_metric Spring Boot legacy numeric metrics",
                        "# TYPE springboot_legacy_metric gauge",
                    ]

                    for k, v in data.items():
                        if not isinstance(v, (int, float)):
                            continue
                        if k.startswith("counter."):
                            metric = "springboot_legacy_counter"
                        elif k.startswith("gauge."):
                            metric = "springboot_legacy_gauge"
                        else:
                            metric = "springboot_legacy_metric"
                        lines.append(f'{metric}{{name="{esc(k)}"}} {float(v)}')

                    body = "\n".join(lines) + "\n"
                    encoded = body.encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)

                def log_message(self, fmt, *args):
                    return

            if __name__ == "__main__":
                HTTPServer(("0.0.0.0", ${var.springboot_metrics_exporter_port}), Handler).serve_forever()
            PY
            exec python /tmp/exporter.py
          EOT
          ]

          port {
            container_port = var.springboot_metrics_exporter_port
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.springboot]
}

resource "kubernetes_job_v1" "postgres_migrate" {
  count = var.deploy_workload && var.enable_postgres_flex && var.deploy_postgres_migration_job ? 1 : 0

  metadata {
    name      = "springboot-postgres-migrate"
    namespace = kubernetes_namespace_v1.springboot[0].metadata[0].name
  }

  spec {
    backoff_limit = 2

    template {
      metadata {
        labels = {
          app = "springboot-postgres-migrate"
        }
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name  = "postgres-migration"
          image = "postgres:17"

          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            set -euo pipefail

            echo "Checking source PostgreSQL readiness..."
            until pg_isready -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$SOURCE_USERNAME" >/dev/null 2>&1; do
              sleep 5
            done

            echo "Checking target PostgreSQL Flex readiness..."
            until pg_isready -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$TARGET_USERNAME" >/dev/null 2>&1; do
              sleep 5
            done

            export PGPASSWORD="$SOURCE_PASSWORD"
            pg_dump \
              --host="$SOURCE_HOST" \
              --port="$SOURCE_PORT" \
              --username="$SOURCE_USERNAME" \
              --dbname="$SOURCE_DATABASE" \
              --format=custom \
              --no-owner \
              --no-privileges \
              --file=/tmp/source.dump

            export PGPASSWORD="$TARGET_PASSWORD"
            pg_restore \
              --host="$TARGET_HOST" \
              --port="$TARGET_PORT" \
              --username="$TARGET_USERNAME" \
              --dbname="$TARGET_DATABASE" \
              --clean \
              --if-exists \
              --no-owner \
              --no-privileges \
              /tmp/source.dump

            echo "PostgreSQL migration job finished successfully."
          EOT
          ]

          env {
            name = "SOURCE_HOST"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.source_postgres[0].metadata[0].name
                key  = "SOURCE_HOST"
              }
            }
          }

          env {
            name = "SOURCE_PORT"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.source_postgres[0].metadata[0].name
                key  = "SOURCE_PORT"
              }
            }
          }

          env {
            name = "SOURCE_DATABASE"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.source_postgres[0].metadata[0].name
                key  = "SOURCE_DATABASE"
              }
            }
          }

          env {
            name = "SOURCE_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.source_postgres[0].metadata[0].name
                key  = "SOURCE_USERNAME"
              }
            }
          }

          env {
            name = "SOURCE_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.source_postgres[0].metadata[0].name
                key  = "SOURCE_PASSWORD"
              }
            }
          }

          env {
            name  = "TARGET_HOST"
            value = local.postgres_flex_host
          }

          env {
            name  = "TARGET_PORT"
            value = tostring(local.postgres_flex_port)
          }

          env {
            name  = "TARGET_DATABASE"
            value = var.postgres_flex_target_database
          }

          env {
            name  = "TARGET_USERNAME"
            value = var.postgres_flex_app_username
          }

          env {
            name  = "TARGET_PASSWORD"
            value = local.postgres_flex_password
          }
        }
      }
    }
  }

  wait_for_completion = true

  depends_on = [
    stackit_postgresflex_user.app,
    kubernetes_secret_v1.source_postgres,
    kubernetes_deployment_v1.springboot
  ]
}

resource "kubernetes_service_v1" "springboot" {
  count = var.deploy_workload ? 1 : 0

  metadata {
    name      = "springboot"
    namespace = kubernetes_namespace_v1.springboot[0].metadata[0].name
    annotations = {
      "external-dns.alpha.kubernetes.io/hostname" = local.app_fqdn
    }
  }

  spec {
    selector = {
      app = "springboot"
    }

    port {
      name        = "http"
      port        = 80
      target_port = var.springboot_container_port
      protocol    = "TCP"
    }

    port {
      name        = "metrics"
      port        = var.springboot_metrics_exporter_port
      target_port = var.springboot_metrics_exporter_port
      protocol    = "TCP"
    }

    dynamic "port" {
      for_each = var.enable_postgres_flex && var.enable_postgres_flex_exporter ? [1] : []

      content {
        name        = "postgres-metrics"
        port        = var.postgres_flex_exporter_port
        target_port = var.postgres_flex_exporter_port
        protocol    = "TCP"
      }
    }

    type = "LoadBalancer"
  }

  depends_on = [kubernetes_deployment_v1.springboot]
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "springboot" {
  count = var.deploy_workload && var.enable_springboot_hpa ? 1 : 0

  metadata {
    name      = "springboot"
    namespace = kubernetes_namespace_v1.springboot[0].metadata[0].name
  }

  spec {
    min_replicas = var.springboot_hpa_min_replicas
    max_replicas = var.springboot_hpa_max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.springboot[0].metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.springboot_hpa_target_cpu_utilization_percentage
        }
      }
    }
  }

  depends_on = [kubernetes_deployment_v1.springboot]
}

resource "stackit_observability_scrapeconfig" "springboot_metrics" {
  count = var.observability_enabled && var.enable_springboot_metrics_scrape && var.deploy_workload ? 1 : 0

  project_id   = local.effective_project_id
  instance_id  = local.effective_observability_instance_id
  name         = "${var.ske_cluster_name}-springboot-metrics"
  metrics_path = "/metrics"
  targets = [{
    urls = ["${local.app_fqdn}:${var.springboot_metrics_exporter_port}"]
  }]
  scheme          = "http"
  scrape_interval = var.springboot_metrics_scrape_interval
  scrape_timeout  = var.springboot_metrics_scrape_timeout

  depends_on = [terraform_data.workload_endpoint_ready]
}

resource "stackit_observability_scrapeconfig" "postgres_flex_metrics" {
  count = var.observability_enabled && var.enable_postgres_flex && var.enable_postgres_flex_exporter && var.enable_postgres_flex_metrics_scrape && var.deploy_workload ? 1 : 0

  project_id   = local.effective_project_id
  instance_id  = local.effective_observability_instance_id
  name         = "${var.ske_cluster_name}-postgres-flex-metrics"
  metrics_path = "/metrics"
  targets = [{
    urls = ["${local.app_fqdn}:${var.postgres_flex_exporter_port}"]
  }]
  scheme          = "http"
  scrape_interval = var.postgres_flex_metrics_scrape_interval
  scrape_timeout  = var.postgres_flex_metrics_scrape_timeout

  depends_on = [terraform_data.workload_endpoint_ready]
}

resource "kubernetes_deployment_v1" "loadgen" {
  count = var.deploy_workload && var.enable_load_generator ? 1 : 0

  metadata {
    name      = "springboot-loadgen"
    namespace = kubernetes_namespace_v1.springboot[0].metadata[0].name
    labels = {
      app = "springboot-loadgen"
    }
  }

  spec {
    replicas = var.load_generator_replicas

    selector {
      match_labels = {
        app = "springboot-loadgen"
      }
    }

    template {
      metadata {
        labels = {
          app = "springboot-loadgen"
        }
      }

      spec {
        container {
          name  = "loadgen"
          image = "busybox:1.36"

          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            set -eu
            TARGET_URL="http://springboot.${var.k8s_namespace}.svc.cluster.local/"
            MIN_REQ=${local.load_profile_effective.min_requests}
            MAX_REQ=${local.load_profile_effective.max_requests}
            MIN_PAUSE=${local.load_profile_effective.min_pause}
            MAX_PAUSE=${local.load_profile_effective.max_pause}

            if [ "$MAX_REQ" -lt "$MIN_REQ" ]; then
              MAX_REQ="$MIN_REQ"
            fi
            if [ "$MAX_PAUSE" -lt "$MIN_PAUSE" ]; then
              MAX_PAUSE="$MIN_PAUSE"
            fi

            rand_int() {
              local min="$1"
              local max="$2"
              awk -v min="$min" -v max="$max" 'BEGIN { srand(); print int(min + rand() * (max - min + 1)) }'
            }

            while true; do
              burst=$(rand_int "$MIN_REQ" "$MAX_REQ")
              pause_s=$(rand_int "$MIN_PAUSE" "$MAX_PAUSE")

              i=1
              while [ "$i" -le "$burst" ]; do
                wget -q -T 3 -O /dev/null "$TARGET_URL" || true
                i=$((i + 1))
              done

              sleep "$pause_s"
            done
          EOT
          ]

          resources {
            requests = {
              cpu    = "20m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_service_v1.springboot]
}

resource "terraform_data" "workload_endpoint_ready" {
  count = var.deploy_workload && var.wait_for_workload_endpoint ? 1 : 0

  depends_on = [kubernetes_service_v1.springboot]

  triggers_replace = [
    local.app_fqdn,
    tostring(var.workload_endpoint_wait_timeout_seconds),
    tostring(var.workload_endpoint_wait_interval_seconds)
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      HOST="${local.app_fqdn}"
      TIMEOUT=${var.workload_endpoint_wait_timeout_seconds}
      INTERVAL=${var.workload_endpoint_wait_interval_seconds}
      ATTEMPTS=$(( TIMEOUT / INTERVAL ))

      if [[ "$ATTEMPTS" -lt 1 ]]; then
        ATTEMPTS=1
      fi

      for ((i=1; i<=ATTEMPTS; i++)); do
        if getent ahostsv4 "$HOST" >/dev/null 2>&1; then
          if curl -fsS --max-time 8 "http://$HOST/" >/dev/null 2>&1; then
            echo "Workload endpoint is reachable: http://$HOST/"
            exit 0
          fi
        fi
        echo "Waiting for endpoint http://$HOST/ ($i/$ATTEMPTS)..."
        sleep "$INTERVAL"
      done

      echo "Timed out waiting for workload endpoint http://$HOST/" >&2
      exit 1
    EOT
  }
}

resource "time_sleep" "metrics_warmup" {
  count = var.observability_enabled && var.create_grafana_dashboard && var.deploy_workload ? 1 : 0

  create_duration = var.observability_metrics_warmup_duration
  depends_on = [
    kubernetes_deployment_v1.springboot,
    terraform_data.workload_endpoint_ready
  ]
}

resource "kubernetes_ingress_v1" "springboot" {
  count = var.deploy_workload && var.enable_ingress ? 1 : 0

  metadata {
    name      = "springboot"
    namespace = kubernetes_namespace_v1.springboot[0].metadata[0].name

    annotations = {
      "kubernetes.io/ingress.class"               = "nginx"
      "external-dns.alpha.kubernetes.io/hostname" = local.app_fqdn
    }
  }

  spec {
    rule {
      host = local.app_fqdn

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.springboot[0].metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_service_v1.springboot]
}

resource "terraform_data" "grafana_dashboard" {
  count = var.observability_enabled && var.create_observability_instance && var.create_grafana_dashboard ? 1 : 0

  depends_on = [
    stackit_observability_instance.replatform_obs,
    stackit_ske_cluster.replatform,
    time_sleep.metrics_warmup
  ]

  triggers_replace = [
    stackit_observability_instance.replatform_obs[0].instance_id,
    stackit_observability_instance.replatform_obs[0].grafana_url,
    stackit_observability_instance.replatform_obs[0].grafana_initial_admin_user,
    stackit_observability_instance.replatform_obs[0].grafana_initial_admin_password,
    filesha256("${path.module}/dashboards/replatform-ske-springboot-dashboard.json")
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      GURL="${stackit_observability_instance.replatform_obs[0].grafana_url}"
      GUSER="${stackit_observability_instance.replatform_obs[0].grafana_initial_admin_user}"
      GPASS="${stackit_observability_instance.replatform_obs[0].grafana_initial_admin_password}"

      PROM_UID=$(curl -fsS -u "$GUSER:$GPASS" "$GURL/api/datasources" | jq -r 'map(select(.type=="prometheus"))[0].uid // empty')
      if [[ -z "$PROM_UID" ]]; then
        echo "No Prometheus datasource found in Grafana" >&2
        exit 1
      fi

      DASHBOARD_JSON=$(sed "s/__PROM_UID__/$PROM_UID/g" "${path.module}/dashboards/replatform-ske-springboot-dashboard.json")
      PAYLOAD=$(mktemp)
      printf '{"dashboard":%s,"overwrite":true}' "$DASHBOARD_JSON" > "$PAYLOAD"

      HTTP=$(curl -sS -o /tmp/replatform_dashboard_import.json -w '%%{http_code}' -u "$GUSER:$GPASS" -H 'Content-Type: application/json' -X POST "$GURL/api/dashboards/db" --data-binary @"$PAYLOAD")
      rm -f "$PAYLOAD"
      if [[ "$HTTP" != "200" ]]; then
        echo "Dashboard import failed with HTTP $HTTP" >&2
        cat /tmp/replatform_dashboard_import.json >&2 || true
        exit 1
      fi
    EOT
  }
}
