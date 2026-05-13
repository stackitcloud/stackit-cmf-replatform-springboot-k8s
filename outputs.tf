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

output "postgres_flex_instance_id" {
  value = var.enable_postgres_flex ? stackit_postgresflex_instance.app[0].instance_id : null
}

output "postgres_flex_host" {
  value = var.enable_postgres_flex ? local.postgres_flex_host : null
}

output "postgres_flex_port" {
  value = var.enable_postgres_flex ? local.postgres_flex_port : null
}

output "postgres_flex_app_username" {
  value = var.enable_postgres_flex ? var.postgres_flex_app_username : null
}

output "postgres_flex_app_password" {
  value     = var.enable_postgres_flex ? local.postgres_flex_password : null
  sensitive = true
}

output "postgres_flex_jdbc_url" {
  value = var.enable_postgres_flex ? local.postgres_flex_jdbc_url : null
}

output "postgres_flex_effective_acl_cidrs" {
  value = var.enable_postgres_flex ? local.postgres_flex_effective_acl_cidrs : []
}

output "postgres_flex_target_app_acl_cidrs" {
  value = var.enable_postgres_flex ? local.postgres_flex_effective_app_acl_cidrs : []
}

output "postgres_flex_temporary_migration_acl_cidrs" {
  value = var.enable_postgres_flex ? local.postgres_flex_effective_temp_acl_cidrs : []
}

output "postgres_flex_source_host_acl_suggestion" {
  value = var.enable_postgres_flex && local.source_postgres_host_is_ipv4 ? local.source_postgres_host_cidr : null
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
