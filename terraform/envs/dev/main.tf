module "stack" {
  source = "../../modules/stack"

  project         = var.project
  environment     = var.environment
  aws_region      = var.aws_region
  cluster_version = var.cluster_version

  vpc_cidr             = var.vpc_cidr
  az_count             = var.az_count
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  node_subnet_tier     = var.node_subnet_tier
  enable_nat_gateway   = var.enable_nat_gateway
  single_nat_gateway   = var.single_nat_gateway
  enable_vpc_endpoints = var.enable_vpc_endpoints

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

  managed_addons                   = var.managed_addons
  addon_versions                   = var.addon_versions
  addon_resolve_conflicts          = var.addon_resolve_conflicts
  enable_metrics_server            = var.enable_metrics_server
  metrics_server_chart_version     = var.metrics_server_chart_version
  enable_cluster_autoscaler        = var.enable_cluster_autoscaler
  cluster_autoscaler_chart_version = var.cluster_autoscaler_chart_version
  cluster_autoscaler_image_tag     = var.cluster_autoscaler_image_tag
  enable_cert_manager              = var.enable_cert_manager
  cert_manager_chart_version       = var.cert_manager_chart_version

  enable_rds            = var.enable_rds
  rds_engine_version    = var.rds_engine_version
  rds_instance_class    = var.rds_instance_class
  rds_allocated_storage = var.rds_allocated_storage
  rds_db_name           = var.rds_db_name
  rds_username          = var.rds_username

  enable_practice_bucket = var.enable_practice_bucket

  enable_alb_controller               = var.enable_alb_controller
  alb_controller_chart_version        = var.alb_controller_chart_version
  enable_external_dns                 = var.enable_external_dns
  external_dns_chart_version          = var.external_dns_chart_version
  dns_zone_name                       = var.dns_zone_name
  enable_argocd                       = var.enable_argocd
  argocd_chart_version                = var.argocd_chart_version
  enable_monitoring                   = var.enable_monitoring
  kube_prometheus_stack_chart_version = var.kube_prometheus_stack_chart_version

  app_namespace      = var.app_namespace
  s3_service_account = var.s3_service_account

  extra_tags = var.extra_tags
}
