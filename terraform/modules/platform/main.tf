# Platform layer: the in-cluster machinery every scenario leans on.
# Everything is toggleable from scripts/config.toml so you can practise
# installing pieces by hand, and chart versions are pinnable ("" = latest).

locals {
  chart_version = {
    alb          = var.alb_controller_chart_version == "" ? null : var.alb_controller_chart_version
    external_dns = var.external_dns_chart_version == "" ? null : var.external_dns_chart_version
    argocd       = var.argocd_chart_version == "" ? null : var.argocd_chart_version
    monitoring   = var.kube_prometheus_stack_chart_version == "" ? null : var.kube_prometheus_stack_chart_version
  }
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller (ALB Ingress + NLB services) via IRSA
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "alb_trust" {
  count = var.enable_alb_controller ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  count = var.enable_alb_controller ? 1 : 0

  name               = "${var.name_prefix}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_trust[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "alb_controller" {
  count = var.enable_alb_controller ? 1 : 0

  name   = "alb-controller"
  role   = aws_iam_role.alb_controller[0].id
  policy = file("${path.module}/files/alb-controller-iam-policy.json")
}

resource "helm_release" "alb_controller" {
  count = var.enable_alb_controller ? 1 : 0

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = local.chart_version.alb
  namespace  = "kube-system"

  values = [yamlencode({
    clusterName = var.cluster_name
    region      = var.aws_region
    vpcId       = var.vpc_id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller[0].arn
      }
    }
    replicaCount = 1 # practice rig: one replica is plenty
    resources = {
      requests = { cpu = "50m", memory = "96Mi" }
      limits   = { memory = "192Mi" }
    }
  })]

  depends_on = [aws_iam_role_policy.alb_controller]
}

# ---------------------------------------------------------------------------
# external-dns (optional; needs a Route53 hosted zone you already own)
# ---------------------------------------------------------------------------

data "aws_route53_zone" "practice" {
  count = var.enable_external_dns ? 1 : 0
  name  = var.dns_zone_name
}

data "aws_iam_policy_document" "external_dns_trust" {
  count = var.enable_external_dns ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:external-dns"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  statement {
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [data.aws_route53_zone.practice[0].arn]
  }
  statement {
    actions   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name               = "${var.name_prefix}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_trust[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name   = "external-dns-route53"
  role   = aws_iam_role.external_dns[0].id
  policy = data.aws_iam_policy_document.external_dns[0].json
}

resource "helm_release" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  version    = local.chart_version.external_dns
  namespace  = "kube-system"

  values = [yamlencode({
    provider      = { name = "aws" }
    txtOwnerId    = var.cluster_name
    domainFilters = [var.dns_zone_name]
    policy        = "sync" # also removes records when the Ingress/Service goes away
    serviceAccount = {
      create = true
      name   = "external-dns"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns[0].arn
      }
    }
    resources = {
      requests = { cpu = "25m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
  })]

  depends_on = [aws_iam_role_policy.external_dns]
}

# ---------------------------------------------------------------------------
# Argo CD - in-cluster, its own namespace, slimmed for a small node group
# ---------------------------------------------------------------------------

resource "helm_release" "argocd" {
  count = var.enable_argocd ? 1 : 0

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = local.chart_version.argocd
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    configs = {
      cm = {
        # Argo polls its source every 180s by default. The drill loop is push-then-
        # watch in one browser, and a three-minute wait after a push is a bad drill.
        # The usual warnings about low intervals are about hundreds of Applications
        # hitting github.com rate limits; here it is one Application against a git
        # server two hops away, with manifests cached by commit SHA. Cost is nil.
        "timeout.reconciliation" = "10s"
      }
      params = {
        "server.insecure" = true # plain HTTP behind port-forward/Ingress; TLS is a scenario
      }
    }
    dex           = { enabled = false } # no SSO on a practice rig; saves a pod
    notifications = { enabled = false }
    controller = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }
    server = {
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }
    }
    repoServer = {
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }
    }
  })]
}

# ---------------------------------------------------------------------------
# kube-prometheus-stack (Prometheus + Grafana), sized for t3-class nodes
# ---------------------------------------------------------------------------

resource "random_password" "grafana_admin" {
  count   = var.enable_monitoring ? 1 : 0
  length  = 20
  special = false
}

resource "helm_release" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  name             = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = local.chart_version.monitoring
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 900

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        retention = "1d" # ephemeral rig - keep memory/disk tiny
        resources = {
          requests = { cpu = "100m", memory = "512Mi" }
          limits   = { memory = "1Gi" }
        }
        # No storageSpec on purpose: emptyDir. Adding an EBS-backed PVC is a scenario.
      }
    }
    grafana = {
      adminPassword = random_password.grafana_admin[0].result
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }
    }
    alertmanager = {
      alertmanagerSpec = {
        resources = {
          requests = { cpu = "25m", memory = "64Mi" }
          limits   = { memory = "128Mi" }
        }
      }
    }
  })]
}

# ---------------------------------------------------------------------------
# Practice app namespace, DB secret, and the IRSA-annotated S3 service account
# ---------------------------------------------------------------------------

resource "kubectl_manifest" "app_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = var.app_namespace }
  })
}

resource "kubectl_manifest" "db_secret" {
  count = var.enable_db_secret ? 1 : 0

  sensitive_fields = ["stringData"]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "practice-db"
      namespace = var.app_namespace
    }
    type = "Opaque"
    stringData = {
      host     = var.db_host
      port     = tostring(var.db_port)
      dbname   = var.db_name
      username = var.db_username
      password = var.db_password
      db-uri   = "postgres://${var.db_username}:${var.db_password}@${var.db_host}:${var.db_port}/${var.db_name}"
    }
  })

  depends_on = [kubectl_manifest.app_namespace]
}

resource "kubectl_manifest" "s3_service_account" {
  # Gated by a static bool - the role arn itself is an apply-time value.
  count = var.create_s3_service_account ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = var.s3_service_account
      namespace = var.app_namespace
      annotations = {
        "eks.amazonaws.com/role-arn" = var.s3_access_role_arn
      }
    }
  })

  depends_on = [kubectl_manifest.app_namespace]
}
