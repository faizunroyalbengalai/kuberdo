# DigitalOcean Kubernetes (DOKS) — Terraform
#
# Unlike EKS we do NOT need:
#   - a VPC module (DO auto-attaches a VPC)
#   - IAM/OIDC trust policies (DO's cloud-controller-manager auths via DO_TOKEN)
#   - a separate ELB controller (Service type=LoadBalancer auto-provisions a DO LB)
#
# Resources created:
#   1. digitalocean_kubernetes_cluster — the control plane + default node pool
#   2. digitalocean_container_registry — DOCR for image storage (account-scoped)
#
# Image push happens in GHA via `doctl` before `terraform apply`, so the
# registry is created here only if it doesn't already exist (DOCR is one-per-account).

terraform {
  backend "s3" {
    endpoints = {
      s3 = "https://nyc3.digitaloceanspaces.com"
    }
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

# ── Variables ────────────────────────────────────────────────────────────────
variable "do_token" {
  type      = string
  sensitive = true
}

variable "project_name" {
  type = string
}

variable "do_region" {
  type    = string
  default = "nyc3"
}

variable "cluster_version" {
  description = "DOKS Kubernetes version slug (e.g. 1.31.1-do.0). Empty = latest stable."
  type        = string
  default     = ""
}

variable "node_size" {
  description = "Droplet size slug for worker nodes."
  type        = string
  default     = "s-2vcpu-2gb"
}

variable "min_nodes" {
  type    = number
  default = 1
}

variable "max_nodes" {
  type    = number
  default = 3
}

variable "node_count" {
  type    = number
  default = 2
}

variable "registry_name" {
  description = "DOCR name (globally unique, one per DO account)."
  type        = string
}

variable "registry_subscription_tier" {
  description = "DOCR tier: starter (free, 500MB, 1 repo) | basic ($5/mo, 5GB) | professional"
  type        = string
  default     = "basic"
}

# ── Locals ───────────────────────────────────────────────────────────────────
locals {
  # DOKS cluster name: lowercase, alphanumeric+hyphens, <= 63 chars
  cluster_name = substr(
    lower(replace(replace(var.project_name, "_", "-"), " ", "-")),
    0, 32
  )
}

# ── DOKS Cluster ─────────────────────────────────────────────────────────────
# We pick "latest" version when cluster_version is unset by reading from the
# DO API at plan time. This avoids hardcoding a version that DO may have
# already deprecated by the time this template runs.
data "digitalocean_kubernetes_versions" "available" {}

resource "digitalocean_kubernetes_cluster" "app" {
  name    = local.cluster_name
  region  = var.do_region
  version = var.cluster_version != "" ? var.cluster_version : data.digitalocean_kubernetes_versions.available.latest_version

  # Allow control plane to keep running even when no nodes — saves accidental destroy
  destroy_all_associated_resources = true

  node_pool {
    name       = "${local.cluster_name}-default"
    size       = var.node_size
    node_count = var.node_count
    auto_scale = true
    min_nodes  = var.min_nodes
    max_nodes  = var.max_nodes

    labels = {
      project = var.project_name
    }
  }

  tags = ["udap", var.project_name]

  lifecycle {
    # DO upgrades versions automatically on patch releases; ignore that drift.
    ignore_changes = [version]
  }
}

# ── DO Container Registry (DOCR) ─────────────────────────────────────────────
# DOCR is one-per-account. If a registry already exists for the account this
# resource will fail terraform apply — the GHA workflow handles the "already
# exists" case by skipping creation, and we import it here on subsequent runs.
resource "digitalocean_container_registry" "app" {
  name                   = var.registry_name
  subscription_tier_slug = var.registry_subscription_tier
  region                 = var.do_region

  lifecycle {
    # DO does not let you change the tier in-place via Terraform without
    # destroying — ignore that to avoid accidental data loss.
    ignore_changes = [subscription_tier_slug]
  }
}

# ── Outputs ──────────────────────────────────────────────────────────────────
output "cluster_id" {
  value = digitalocean_kubernetes_cluster.app.id
}

output "cluster_name" {
  value = digitalocean_kubernetes_cluster.app.name
}

output "cluster_endpoint" {
  value = digitalocean_kubernetes_cluster.app.endpoint
}

output "registry_name" {
  value = digitalocean_container_registry.app.name
}

output "registry_endpoint" {
  value = digitalocean_container_registry.app.endpoint
}

output "namespace" {
  value = local.cluster_name
}
