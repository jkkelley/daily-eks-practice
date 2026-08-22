# ---------------------------------------------------------------------------
# The drill GUI - one long-lived pod serving the terminal, the editor, the
# explorer, the source control view, the Argo widget and the grader.
#
# This is the only surface the user ever works from, and the only thing in the
# stack that creates a load balancer.
#
# ---- IT IS AN UNAUTHENTICATED CLUSTER-ADMIN WEB TERMINAL -------------------
#
# There is no login. The pod's ServiceAccount is bound to cluster-admin. The single
# control is the source-IP allow list on the security group in drill-ingress.tf,
# which is defensible only because the target was checked and found to be a
# directly-assigned residential /32. Read the header of that file before changing
# anything here, and never widen drill_allowed_cidrs to 0.0.0.0/0 - there is a
# precondition that fails the plan if you try.
#
# cluster-admin is deliberate rather than lazy. Scenario 10 is break/fix: it deletes
# things and puts them back. A read-only role cannot do it, and a role scoped to
# exactly what the twelve scenarios need today is a role that silently breaks the
# thirteenth. The blast radius is one throwaway practice cluster.
#
# ---- THE WORKSPACE IS A CLONE, NEVER A COPY -------------------------------
#
# The init container CLONES cluster git into the PVC. That is not a convenience:
# scenario 03's model answer is `git revert <commit> && git push`, and a copied
# directory has no remote, so the push fails at exactly the moment the drill is
# testing. The clone is also what makes `origin` a dead end that never reaches the
# user's real GitHub account, which is what makes practising a force-push safe.
# ---------------------------------------------------------------------------

locals {
  drill_ns    = "practice-drill"
  drill_sa    = "drill"
  drill_app   = "drill-gui"
  drill_port  = 8090
  drill_uid   = 1001
  drill_home  = "/home/drill"
  drill_ws    = "/home/drill/practice-app"
  drill_logs  = "/home/drill/.drill/pty"
  drill_image = "${var.drill_gui_image}:${var.drill_gui_tag}"

  # The GUI needs a repo to clone, so it follows cluster git rather than standing on
  # its own. Enabling it without that would produce a pod stuck in Init forever.
  drill_enabled = var.enable_drill_gui && var.enable_cluster_git
}

resource "kubectl_manifest" "drill_namespace" {
  count = local.drill_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name   = local.drill_ns
      labels = { "app.kubernetes.io/part-of" = "drill-platform" }
    }
  })
}

resource "kubectl_manifest" "drill_service_account" {
  count = local.drill_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata   = { name = local.drill_sa, namespace = local.drill_ns }
  })

  depends_on = [kubectl_manifest.drill_namespace]
}

# See the header. This is the scenario 10 requirement, written down where somebody
# tightening it will read the reason first.
resource "kubectl_manifest" "drill_cluster_admin" {
  count = local.drill_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata   = { name = "${local.drill_ns}-cluster-admin" }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "cluster-admin"
    }
    subjects = [{
      kind      = "ServiceAccount"
      name      = local.drill_sa
      namespace = local.drill_ns
    }]
  })

  depends_on = [kubectl_manifest.drill_service_account]
}

# The workspace, the PTY log and the shell history all live here, so a pod restart
# mid-drill does not lose the work or the scrollback.
#
# 15 GB is far more than the workspace needs and the size is not the point - it costs
# about 1.6 cents for a ten-hour drill. Orphaning is the real cost, and Task 4.2's
# pre-destroy is what handles that.
#
# No storageClassName, matching cluster-git.tf and for the same reason: the cluster's
# default class is right in both places this runs, gp2/EBS on EKS and local-path on
# kind. The plan says "gp3", which is the EBS type worth having and which needs a
# StorageClass this project does not create yet - naming one here would cost nothing
# on EKS and would break the kind sandbox outright, which is where this gets tested.
resource "kubectl_manifest" "drill_pvc" {
  count = local.drill_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolumeClaim"
    metadata   = { name = "drill-workspace", namespace = local.drill_ns }
    spec = {
      accessModes = ["ReadWriteOnce"]
      resources   = { requests = { storage = "15Gi" } }
    }
  })

  depends_on = [kubectl_manifest.drill_namespace]
}

resource "kubectl_manifest" "drill_deployment" {
  count = local.drill_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata   = { name = local.drill_app, namespace = local.drill_ns }
    spec = {
      replicas = 1
      # One RWO volume; two pods cannot both mount it. Also correct on its own terms:
      # the session is stateful and a second replica would be a second tmux server
      # with a different scrollback.
      strategy = { type = "Recreate" }
      selector = { matchLabels = { app = local.drill_app } }
      template = {
        metadata = { labels = { app = local.drill_app } }
        spec = {
          serviceAccountName = local.drill_sa
          # The prompt shows this. The default is the pod name, and
          # `drill-gui-7d4f9c8b5-x2kqp:~/practice-app$` announces that you are inside
          # somebody's Deployment; `drill:~/practice-app$` is a machine you were given.
          hostname = "drill"
          securityContext = {
            runAsUser  = local.drill_uid
            runAsGroup = local.drill_uid
            # Without a matching fsGroup the PVC mounts root-owned, the clone fails,
            # and if it somehow succeeded git would refuse to operate in a repo whose
            # owner is not the running user. Same trap cluster-git.tf documents.
            fsGroup      = local.drill_uid
            runAsNonRoot = true
          }

          initContainers = [{
            name  = "clone-workspace"
            image = local.git_image
            env = [
              { name = "REPO", value = local.cluster_git_url },
              { name = "WORKSPACE", value = local.drill_ws },
              { name = "LOGS", value = local.drill_logs },
            ]
            command = ["/bin/sh", "-c"]
            args = [<<-EOT
              set -e
              mkdir -p "$LOGS"
              if [ -d "$WORKSPACE/.git" ]; then
                # The PVC survives pod restarts, so a restart mid-drill finds a
                # workspace with the learner's uncommitted edits in it. Clobbering
                # that would throw away the work the drill is about.
                echo "clone-workspace: workspace already present, leaving it alone"
                exit 0
              fi
              echo "clone-workspace: cloning $REPO"
              git clone "$REPO" "$WORKSPACE"
              # A commit needs an identity, and git's guessed one fails outright in a
              # container with no passwd entry for the uid. Scenario 03's model answer
              # is a commit, so this is load-bearing rather than cosmetic.
              git -C "$WORKSPACE" config user.email "drill@localhost"
              git -C "$WORKSPACE" config user.name  "drill"
              echo "clone-workspace: ready"
            EOT
            ]
            volumeMounts = [{ name = "workspace", mountPath = local.drill_home }]
          }]

          containers = [{
            name  = local.drill_app
            image = local.drill_image
            env = [
              { name = "DRILL_WORKSPACE", value = local.drill_ws },
              # Outside the workspace on purpose: it is on the same volume so a
              # restart replays the scrollback, and outside the git tree so the
              # trainer's own log files never show up in the learner's `git status`.
              { name = "DRILL_LOG_DIR", value = local.drill_logs },
              { name = "HOME", value = local.drill_home },
              # Where the two lifecycle ConfigMaps live. Threaded from the local
              # rather than left to the server's default so the two cannot drift:
              # a server looking in the wrong namespace finds no `drill-request`,
              # silently keeps the fallback scenario below, and nothing anywhere
              # says why the pause menu's switch did nothing.
              { name = "DRILL_NAMESPACE", value = local.drill_ns },
              # THE FALLBACK, not the source of truth. `drill-request` - written by
              # `make scenario N=NN` and by the laptop watcher - is what decides
              # which scenario runs, and the server reads it at startup and polls
              # it after. This is what a pod that has never been told anything
              # comes up in, and it is what keeps `drill-dev` working with no
              # cluster at all.
              { name = "DRILL_SCENARIO", value = "03" },
              { name = "DRILL_CLUSTER_GIT_URL", value = local.cluster_git_url },
              { name = "DRILL_SERVICE_ACCOUNT", value = local.drill_sa },
            ]
            ports = [{ name = "http", containerPort = local.drill_port }]
            # /healthz answers as soon as Fastify is listening, which is what both
            # probes want to know. Readiness is what keeps the ALB from routing to a
            # pod whose init container has not finished cloning.
            readinessProbe = {
              httpGet             = { path = "/healthz", port = "http" }
              initialDelaySeconds = 3
              periodSeconds       = 5
            }
            livenessProbe = {
              httpGet             = { path = "/healthz", port = "http" }
              initialDelaySeconds = 20
              periodSeconds       = 20
            }
            volumeMounts = [{ name = "workspace", mountPath = local.drill_home }]
            resources = {
              # A terminal, a node server and whatever the learner runs in it -
              # `helm template`, a kubectl watch, a curl loop. No CPU limit on
              # purpose: throttling a shell makes the drill feel broken, and this is
              # a single-tenant practice cluster.
              requests = { cpu = "100m", memory = "256Mi" }
              limits   = { memory = "1Gi" }
            }
          }]

          volumes = [
            { name = "workspace", persistentVolumeClaim = { claimName = "drill-workspace" } },
          ]
        }
      }
    }
  })

  depends_on = [
    kubectl_manifest.drill_pvc,
    kubectl_manifest.drill_cluster_admin,
    kubectl_manifest.git_service,
  ]
}

resource "kubectl_manifest" "drill_service" {
  count = local.drill_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata   = { name = local.drill_app, namespace = local.drill_ns }
    spec = {
      selector = { app = local.drill_app }
      ports    = [{ name = "http", port = local.drill_port, targetPort = "http" }]
    }
  })

  depends_on = [kubectl_manifest.drill_deployment]
}

# ---------------------------------------------------------------------------
# The Ingress, and the shared ALB.
#
# `group.name` is the whole point. Without it every ops Ingress - this one, Argo CD,
# Grafana - provisions its OWN load balancer, and the difference is one ALB at about
# $16/month against three. The other two join this group when scenario 07 is ported;
# this is the first member, which is why it is also the first point at which
# WO-20260819-1fea's AC-H3 is observable at all.
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "drill_ingress" {
  count = local.drill_enabled && var.enable_alb_controller ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = local.drill_app
      namespace = local.drill_ns
      annotations = {
        "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
        "alb.ingress.kubernetes.io/target-type"      = "ip"
        "alb.ingress.kubernetes.io/group.name"       = var.drill_ingress_group_name
        "alb.ingress.kubernetes.io/listen-ports"     = jsonencode([{ HTTP = 80 }])
        "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz"

        # The source-restricted group from drill-ingress.tf. Naming it here means the
        # controller attaches it rather than creating its own wide-open one.
        "alb.ingress.kubernetes.io/security-groups" = aws_security_group.drill_alb[0].id
        # ...and naming it also switches OFF the controller's automatic node-side
        # rules, which would otherwise leave the ALB unable to reach the pods. Turning
        # this back on is what keeps the allow list as the only thing restricting
        # access, rather than the only thing that works.
        "alb.ingress.kubernetes.io/manage-backend-security-group-rules" = "true"

        # The terminal is a websocket that sits idle whenever the learner is reading
        # rather than typing, and an ALB's default idle timeout is 60 seconds. Left at
        # the default the socket is dropped a minute into every card, the GUI silently
        # reconnects, and it reads as a flaky drill rather than as a timeout.
        "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=3600"
      }
    }
    spec = {
      ingressClassName = "alb"
      rules = [{
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = local.drill_app
                port = { number = local.drill_port }
              }
            }
          }]
        }
      }]
    }
  })

  depends_on = [
    kubectl_manifest.drill_service,
    terraform_data.drill_cidr_guard,
  ]
}
