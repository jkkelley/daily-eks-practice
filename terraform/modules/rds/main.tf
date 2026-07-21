# Smallest practical Postgres for the practice app. Single-AZ, tiny instance,
# minimal gp3 storage - this is a learning fixture, not a production database.

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db"
  description = "Postgres access from the EKS cluster only"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

# count (not for_each): the SG ids are apply-time values, but the list LENGTH
# is known at plan time, which is all count needs.
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from EKS"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
  tags                         = var.tags
}

# Generated once, stored in state and pushed into the cluster as a k8s Secret.
# Fine for a practice rig; a real system would use Secrets Manager rotation.
resource "random_password" "master" {
  length  = 24
  special = false
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-db"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.username
  password = random_password.master.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 0 # practice rig: no backups, no snapshot cost
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  performance_insights_enabled = false

  tags = var.tags
}
