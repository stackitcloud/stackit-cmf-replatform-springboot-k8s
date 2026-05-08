# stackit-cmf-replatform-springboot-k8s

Runnable replatform example for STACKIT: migrate a Spring Boot workload to SKE with DNS and Observability.

## What this example creates

- Optional target project creation
- SKE cluster (small default node pool)
- DNS zone and external-dns integration
- STACKIT Observability instance
- Spring Boot Deployment + Service (LoadBalancer)
- Optional Horizontal Pod Autoscaler (HPA) for Spring Boot
- Metrics exporter sidecar on port 9090
- Observability scrape config for Spring Boot metrics
- Grafana dashboard import
- Optional load-generator pod

## Prerequisites

- Terraform >= 1.5
- Service account key file
- Required permissions for SKE, DNS, Observability, and optional project creation

## 1) Configure variables

Copy the example file:

```bash
cp env.tfvars.example env.tfvars
```

Then edit `env.tfvars`.

### Values you must replace (currently `xxxx`)

- `target_project_owner_email`
- `parent_container_id`
- `ske_cluster_name`
- `observability_instance_name`
- `dns_zone_name`
- `dns_zone_display_name`

### Notes for these required values

- `target_project_owner_email`: service account or owner email used for project creation
- `parent_container_id`: folder/container ID (for `create_project = true`)
- `ske_cluster_name`: max 11 characters
- `observability_instance_name`: unique readable instance name
- `dns_zone_name`: delegated DNS zone (for example `cmf-1234.runs.onstackit.cloud`)
- `dns_zone_display_name`: display name for the DNS zone resource

### Commonly adjusted values

- `service_account_key_path`
- `target_project_name`
- `region`, `availability_zone`
- `node_pool_machine_type`
- `springboot_image`
- `enable_springboot_hpa`, `springboot_hpa_*`
- `enable_load_generator`, `load_profile`

## Kubernetes rightsizing options

For replatformed workloads on SKE, rightsizing can be applied at multiple layers:

- Pod layer: adjust requests/limits and optionally enable HPA.
- Node pool layer: tune node pool min/max and machine type.
- Storage layer: choose suitable storage classes for persistence characteristics.

### Enable HPA (optional)

Set in `env.tfvars`:

```hcl
enable_springboot_hpa                         = true
springboot_hpa_min_replicas                   = 1
springboot_hpa_max_replicas                   = 5
springboot_hpa_target_cpu_utilization_percentage = 70
```

Then apply:

```bash
terraform apply -var-file=env.tfvars
```

## 2) Deploy

```bash
terraform init
terraform validate
terraform plan -var-file=env.tfvars
terraform apply -var-file=env.tfvars
```

## 3) Verify workload

```bash
mkdir -p .tmp
terraform output -raw kubeconfig > .tmp/replatform.kubeconfig
export KUBECONFIG=$PWD/.tmp/replatform.kubeconfig
kubectl get ns
kubectl get deploy,svc -n springboot
kubectl get pods -n springboot
```

## 4) Verify metrics path

```bash
HOST=$(terraform output -raw springboot_hostname)
curl -sS "http://$HOST:9090/metrics" | head -n 30
```

Expected: lines beginning with `springboot_legacy_counter`, `springboot_legacy_gauge`, `springboot_legacy_metric`.

## 5) Verify outputs

```bash
terraform output
```

Important outputs:

- `springboot_url`
- `springboot_hostname`
- `observability_grafana_url`
- `project_id`

## Troubleshooting

- If `metrics-exporter` restarts, inspect logs:

```bash
POD=$(kubectl get pod -n springboot -l app=springboot -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n springboot "$POD" -c metrics-exporter --tail=200
kubectl logs -n springboot "$POD" -c metrics-exporter --previous --tail=200
```

- If scrape exists but no data arrives, check target health in Prometheus/Grafana datasource (`up{job="<scrape-job>"}`).
- Scrape interval must be greater than `60s` for this environment (`61s` is set by default).

## Destroy

```bash
terraform destroy -var-file=env.tfvars
```
