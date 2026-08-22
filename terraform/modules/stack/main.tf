locals {
  name_prefix  = "${var.project}-${var.environment}"
  cluster_name = local.name_prefix

  tags = merge({
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "daily-eks-practice"
  }, var.extra_tags)
}

module "vpc" {
  source = "../vpc"

  name_prefix          = local.name_prefix
  cluster_name         = local.cluster_name
  vpc_cidr             = var.vpc_cidr
  az_count             = var.az_count
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  enable_nat_gateway   = var.enable_nat_gateway
  single_nat_gateway   = var.single_nat_gateway
  enable_vpc_endpoints = var.enable_vpc_endpoints
  tags                 = local.tags
}

locals {
  node_subnet_ids          = var.node_subnet_tier == "public" ? module.vpc.public_subnet_ids : module.vpc.private_subnet_ids
  control_plane_subnet_ids = concat(module.vpc.public_subnet_ids, module.vpc.private_subnet_ids)
}

module "eks" {
  source = "../eks"

  name_prefix     = local.name_prefix
  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version
  subnet_ids      = local.control_plane_subnet_ids
  node_subnet_ids = local.node_subnet_ids

  endpoint_public_access                      = var.endpoint_public_access
  endpoint_private_access                     = var.endpoint_private_access
  public_access_cidrs                         = var.public_access_cidrs
  enabled_cluster_log_types                   = var.enabled_cluster_log_types
  authentication_mode                         = var.authentication_mode
  bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions
  access_entries                              = var.access_entries

  node_instance_types  = var.node_instance_types
  capacity_type        = var.capacity_type
  ami_type             = var.ami_type
  node_version         = var.node_version
  node_desired_size    = var.node_desired_size
  node_min_size        = var.node_min_size
  node_max_size        = var.node_max_size
  node_max_unavailable = var.node_max_unavailable
  node_disk_size       = var.node_disk_size

  tags = local.tags
}

module "addons" {
  source = "../addons"

  name_prefix          = local.name_prefix
  cluster_name         = module.eks.cluster_name
  cluster_version      = var.cluster_version
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_provider_url
  node_group_asg_names = module.eks.node_group_asg_names

  managed_addons          = var.managed_addons
  addon_versions          = var.addon_versions
  addon_resolve_conflicts = var.addon_resolve_conflicts

  enable_metrics_server            = var.enable_metrics_server
  metrics_server_chart_version     = var.metrics_server_chart_version
  enable_cluster_autoscaler        = var.enable_cluster_autoscaler
  cluster_autoscaler_chart_version = var.cluster_autoscaler_chart_version
  cluster_autoscaler_image_tag     = var.cluster_autoscaler_image_tag
  enable_cert_manager              = var.enable_cert_manager
  cert_manager_chart_version       = var.cert_manager_chart_version

  tags = local.tags

  depends_on = [module.eks]
}

module "rds" {
  source = "../rds"
  count  = var.enable_rds ? 1 : 0

  name_prefix                = local.name_prefix
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnet_ids
  allowed_security_group_ids = [module.eks.cluster_security_group_id]
  engine_version             = var.rds_engine_version
  instance_class             = var.rds_instance_class
  allocated_storage          = var.rds_allocated_storage
  db_name                    = var.rds_db_name
  username                   = var.rds_username
  tags                       = local.tags
}

module "storage" {
  source = "../storage"
  count  = var.enable_practice_bucket ? 1 : 0

  name_prefix        = local.name_prefix
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_provider_url  = module.eks.oidc_provider_url
  app_namespace      = var.app_namespace
  s3_service_account = var.s3_service_account
  tags               = local.tags
}

module "platform" {
  source = "../platform"

  name_prefix       = local.name_prefix
  cluster_name      = module.eks.cluster_name
  aws_region        = var.aws_region
  vpc_id            = module.vpc.vpc_id
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  enable_alb_controller        = var.enable_alb_controller
  alb_controller_chart_version = var.alb_controller_chart_version

  enable_external_dns        = var.enable_external_dns
  external_dns_chart_version = var.external_dns_chart_version
  dns_zone_name              = var.dns_zone_name

  enable_argocd        = var.enable_argocd
  argocd_chart_version = var.argocd_chart_version

  enable_monitoring                   = var.enable_monitoring
  kube_prometheus_stack_chart_version = var.kube_prometheus_stack_chart_version

  enable_cluster_git       = var.enable_cluster_git
  drill_ingress_group_name = var.drill_ingress_group_name
  drill_allowed_cidrs      = var.drill_allowed_cidrs
  enable_drill_gui         = var.enable_drill_gui
  drill_gui_image          = var.drill_gui_image
  drill_gui_tag            = var.drill_gui_tag

  app_namespace = var.app_namespace

  enable_db_secret = var.enable_rds
  db_host          = var.enable_rds ? module.rds[0].address : ""
  db_port          = var.enable_rds ? module.rds[0].port : 5432
  db_name          = var.enable_rds ? module.rds[0].db_name : ""
  db_username      = var.enable_rds ? module.rds[0].username : ""
  db_password      = var.enable_rds ? module.rds[0].password : ""

  create_s3_service_account = var.enable_practice_bucket
  s3_access_role_arn        = var.enable_practice_bucket ? module.storage[0].s3_access_role_arn : ""
  s3_service_account        = var.s3_service_account

  tags = local.tags

  depends_on = [module.eks, module.addons]
}
