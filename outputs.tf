output "project_id" {
  value = local.effective_project_id
}

output "ske_cluster_name" {
  value = stackit_ske_cluster.replatform.name
}

output "ske_cluster_region" {
  value = stackit_ske_cluster.replatform.region
}

output "observability_instance_id" {
  value = local.effective_observability_instance_id
}

output "observability_grafana_url" {
  value = var.observability_enabled && var.create_observability_instance ? stackit_observability_instance.replatform_obs[0].grafana_url : null
}

output "dns_zone_name" {
  value = var.dns_enabled ? (var.create_dns_zone ? stackit_dns_zone.cmf_zone[0].dns_name : local.effective_dns_zone_name) : null
}

output "springboot_hostname" {
  value = var.deploy_workload ? local.app_fqdn : null
}

output "springboot_url" {
  value = var.deploy_workload ? "http://${local.app_fqdn}" : null
}

output "kubeconfig" {
  value     = stackit_ske_kubeconfig.replatform.kube_config
  sensitive = true
}

output "kubectl_quickstart" {
  value = join("\n", [
    "mkdir -p .tmp",
    "terraform output -raw kubeconfig > .tmp/replatform.kubeconfig",
    "export KUBECONFIG=$PWD/.tmp/replatform.kubeconfig",
    "kubectl get ns",
    "kubectl get deploy,svc,ing -n ${var.k8s_namespace}",
    "kubectl get pods -n ${var.k8s_namespace}"
  ])
}
