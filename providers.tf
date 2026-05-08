terraform {
  required_version = ">= 1.5.0"

  required_providers {
    stackit = {
      source  = "stackitcloud/stackit"
      version = ">= 0.94.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30.0"
    }

    time = {
      source  = "hashicorp/time"
      version = ">= 0.11.0"
    }

    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

provider "stackit" {
  default_region           = var.region
  service_account_key_path = pathexpand(var.service_account_key_path)
}

resource "stackit_ske_kubeconfig" "replatform" {
  project_id   = local.effective_project_id
  cluster_name = stackit_ske_cluster.replatform.name

  refresh        = true
  expiration     = 7200
  refresh_before = 1800
}

provider "kubernetes" {
  host                   = yamldecode(stackit_ske_kubeconfig.replatform.kube_config).clusters[0].cluster.server
  client_certificate     = base64decode(yamldecode(stackit_ske_kubeconfig.replatform.kube_config).users[0].user["client-certificate-data"])
  client_key             = base64decode(yamldecode(stackit_ske_kubeconfig.replatform.kube_config).users[0].user["client-key-data"])
  cluster_ca_certificate = base64decode(yamldecode(stackit_ske_kubeconfig.replatform.kube_config).clusters[0].cluster["certificate-authority-data"])
}
