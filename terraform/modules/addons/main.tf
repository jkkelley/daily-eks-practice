data "aws_region" "current" {}

# ===========================================================================
# EBS CSI driver IRSA role (classic IRSA - teaches the OIDC trust pattern)
# ===========================================================================
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name_prefix}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ===========================================================================
# EKS-managed add-ons
# ===========================================================================
# The VPC CNI creates secondary ENIs (one per batch of pod IPs) that no Terraform
# resource owns, so tag_specifications can't reach them. ADDITIONAL_ENI_TAGS tells
# the CNI to stamp our tags on every ENI it allocates - the last untagged surface.
locals {
  vpc_cni_configuration = jsonencode({
    env = {
      ADDITIONAL_ENI_TAGS = jsonencode(var.tags)
    }
  })
}

resource "aws_eks_addon" "this" {
  for_each = toset(var.managed_addons)

  cluster_name  = var.cluster_name
  addon_name    = each.key
  addon_version = lookup(var.addon_versions, each.key, null)

  service_account_role_arn = each.key == "aws-ebs-csi-driver" ? aws_iam_role.ebs_csi.arn : null

  configuration_values = each.key == "vpc-cni" ? local.vpc_cni_configuration : null

  resolve_conflicts_on_create = var.addon_resolve_conflicts
  resolve_conflicts_on_update = var.addon_resolve_conflicts

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.ebs_csi]
}

# ===========================================================================
# cluster-autoscaler: IRSA role + ASG discovery tags + Helm release
# ===========================================================================
data "aws_iam_policy_document" "ca_assume" {
  count = var.enable_cluster_autoscaler ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ca_policy" {
  count = var.enable_cluster_autoscaler ? 1 : 0
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "ca" {
  count              = var.enable_cluster_autoscaler ? 1 : 0
  name               = "${var.name_prefix}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.ca_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "ca" {
  count  = var.enable_cluster_autoscaler ? 1 : 0
  name   = "cluster-autoscaler"
  role   = aws_iam_role.ca[0].id
  policy = data.aws_iam_policy_document.ca_policy[0].json
}

# count (not for_each) because ASG names are unknown until the node group applies,
# and for_each keys must be known at plan time. A managed node group has one ASG.
resource "aws_autoscaling_group_tag" "ca_enabled" {
  count                  = var.enable_cluster_autoscaler ? 1 : 0
  autoscaling_group_name = var.node_group_asg_names[0]
  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }
}

resource "aws_autoscaling_group_tag" "ca_cluster" {
  count                  = var.enable_cluster_autoscaler ? 1 : 0
  autoscaling_group_name = var.node_group_asg_names[0]
  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = false
  }
}

resource "helm_release" "cluster_autoscaler" {
  count            = var.enable_cluster_autoscaler ? 1 : 0
  name             = "cluster-autoscaler"
  repository       = "https://kubernetes.github.io/autoscaler"
  chart            = "cluster-autoscaler"
  version          = var.cluster_autoscaler_chart_version == "" ? null : var.cluster_autoscaler_chart_version
  namespace        = "kube-system"
  create_namespace = false

  set {
    name  = "cloudProvider"
    value = "aws"
  }
  set {
    name  = "awsRegion"
    value = data.aws_region.current.region
  }
  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.ca[0].arn
  }
  # Pinned on purpose - must track the cluster minor version.
  set {
    name  = "image.tag"
    value = var.cluster_autoscaler_image_tag
  }
  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }

  depends_on = [aws_iam_role_policy.ca]
}

# ===========================================================================
# metrics-server
# ===========================================================================
resource "helm_release" "metrics_server" {
  count      = var.enable_metrics_server ? 1 : 0
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version == "" ? null : var.metrics_server_chart_version
  namespace  = "kube-system"
}

# ===========================================================================
# cert-manager (optional)
# ===========================================================================
resource "helm_release" "cert_manager" {
  count            = var.enable_cert_manager ? 1 : 0
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version == "" ? null : var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "crds.enabled"
    value = "true"
  }
}
