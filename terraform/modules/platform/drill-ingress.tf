# ---------------------------------------------------------------------------
# Security group for the shared ops ALB.
#
# This is not a hardening nicety. The drill GUI serves a real PTY in a pod whose
# ServiceAccount is cluster-admin, over plain HTTP with no login. Without a source
# restriction it is a remote root shell on the cluster for anyone who finds the
# hostname. The allow list lives in scripts/config.toml, which is git-ignored, so
# a personal IP never reaches the remote.
#
# HTTPS + ALB OIDC auth is the documented growth path and is deferred only because
# it needs an ACM cert, which needs a Route53 zone this project does not configure
# yet (enable_external_dns = false, dns_zone_name = ""). It is a good scenario in
# its own right.
#
# Source IP is the ONLY control, and that is defensible only because the target was
# checked and found to be a directly-assigned residential /32 rather than carrier
# NAT. Add the application-level shared secret before drilling from a cafe, a phone
# tether, a corporate network, a commercial VPN exit, or with a second person on the
# platform - in all of those the allow list means "everyone sharing this egress
# address". The full argument is at the top of plan Task 4.1.
#
# The Ingress resources themselves ship in Phase 5 with the GUI. This file provides
# only what they annotate against, so the ALB is never created before something
# needs it.
# ---------------------------------------------------------------------------

resource "aws_security_group" "drill_alb" {
  count = var.enable_alb_controller ? 1 : 0

  name        = "${var.name_prefix}-drill-alb"
  description = "Source-restricted access to the shared ops ALB (drill GUI, Argo CD, Grafana)"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-drill-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "drill_alb_http" {
  for_each = var.enable_alb_controller ? toset(var.drill_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.drill_alb[0].id
  description       = "HTTP from an allowed operator IP"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "drill_alb_all" {
  count = var.enable_alb_controller ? 1 : 0

  security_group_id = aws_security_group.drill_alb[0].id
  description       = "ALB to targets"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# A wide-open allow list on an unauthenticated cluster-admin terminal is not a
# configuration choice, it is an incident. Fail the plan instead of the postmortem.
#
# This is a resource precondition rather than a variable validation block on purpose.
# The variable is threaded through three modules and is set even when the ALB
# controller is off, and a validation block would reject a config that cannot build
# an ALB at all. The precondition is scoped to the case where the security group is
# actually going to exist.
resource "terraform_data" "drill_cidr_guard" {
  count = var.enable_alb_controller ? 1 : 0

  lifecycle {
    precondition {
      condition     = !contains(var.drill_allowed_cidrs, "0.0.0.0/0")
      error_message = "drill_allowed_cidrs must not contain 0.0.0.0/0 - the drill GUI is an unauthenticated cluster-admin web terminal. Set it to your own /32 in scripts/config.toml (curl -s https://checkip.amazonaws.com)."
    }
    precondition {
      condition     = length(var.drill_allowed_cidrs) > 0
      error_message = "drill_allowed_cidrs is empty - nothing would be able to reach the drill GUI."
    }
  }
}
