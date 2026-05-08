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
  effective_project_id = var.create_project ? stackit_resourcemanager_project.cmf_project[0].project_id : (var.project_id != "" ? var.project_id : local.bootstrap_project_id)
  create_dns_with_random_suffix = var.dns_enabled && var.create_dns_zone && strcontains(var.dns_zone_name, "{rand}")
  effective_dns_zone_name       = local.create_dns_with_random_suffix ? replace(var.dns_zone_name, "{rand}", tostring(random_integer.dns_suffix[0].result)) : var.dns_zone_name
  effective_dns_zone_display    = local.create_dns_with_random_suffix ? replace(var.dns_zone_display_name, "{rand}", tostring(random_integer.dns_suffix[0].result)) : var.dns_zone_display_name
  effective_dns_zones           = var.dns_enabled ? (var.create_dns_zone ? [stackit_dns_zone.cmf_zone[0].dns_name] : [local.effective_dns_zone_name]) : []
  app_fqdn                      = "${var.app_subdomain}.${local.effective_dns_zone_name}"
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

  rules = [
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
  ]

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

    type = "LoadBalancer"
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
