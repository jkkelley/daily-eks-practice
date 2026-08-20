# ---------------------------------------------------------------------------
# Cluster git - the ONLY repository Argo CD ever reads.
#
# Argo pointing at GitHub and a drill pointing at a workspace would be two
# Applications fighting over one namespace. Pointing Argo at a repo that lives in
# the cluster removes the conflict instead of managing it: there is one
# Application, permanently, and GitHub becomes the upstream rather than the source.
#
# Seeding is deliberately NOT done here. An init container cloning GitHub would
# need a PAT in the cluster and would fail for a private repo on first apply.
# Instead the init container creates an empty bare repo, and `make git-seed`
# streams a git bundle in from the laptop. The readiness probe requires the
# .seeded marker, so until that lands the Service has no endpoints and Argo
# retries cleanly. The danger was never that Argo errors - it is that Argo
# SUCCEEDS against a half-served repo and syncs a broken state that looks fine.
#
# ---- WHICH RUNG OF THE FALLBACK LADDER THIS IS, AND WHY --------------------
#
# The plan's Task 3.2 ranks five ways to serve the repo. This is RUNG 3,
# `git daemon` over the git:// protocol. Rungs 1 and 2 were tried first and
# both were ruled out by measurement, on kind, at $0:
#
#   Rung 1, dumb HTTP over static nginx, FAILS. Argo reports
#   "failed to list refs: unexpected EOF": nginx serves the static info/refs as
#   Content-Type application/octet-stream and go-git cannot read that as a
#   smart-HTTP advertisement. The git binary can clone it, but Argo clones with
#   --depth 1 and that returns "fatal: dumb http transport does not support
#   shallow capabilities". Shallow fetch is a smart-transport capability, so no
#   amount of nginx configuration fixes it.
#
#   Rung 2, git http-backend as CGI, is BLOCKED rather than worse. It needs a CGI
#   host and git-http-backend in one image, and no public image has both:
#   alpine/git has neither, bitnami/git has the backend but no CGI host,
#   httpd:2.4-alpine has apache but no git. Reaching it means building and
#   publishing an image, and that infrastructure does not exist until Phase 5.
#
#   Rung 3 is proven end to end by tests/cluster-git-argo.sh: ls-remote, a
#   --depth 1 clone, a push, and an Argo Application reporting OutOfSync with
#   empty .status.conditions. It costs the URL scheme - git:// rather than
#   http:// - and nothing else.
#
# Push is enabled (--enable=receive-pack) because the drill needs it: scenario
# 03's model answer is `git revert <commit> && git push`. That means anonymous
# push, which is acceptable here and only here - the Service is ClusterIP, there
# is no Ingress in front of it, and it holds a copy of a public repo.
#
# Two traps, both found the hard way, both worth not rediscovering:
#   - The image must carry `git-daemon`, which is a separate binary from `git`.
#     alpine/git does not have it. buildpack-deps:*-scm is Debian's full git, is
#     an official image, and has a real version tag to pin - bitnami/git works
#     too but publishes only `latest`.
#   - git refuses to serve a repo whose owner uid differs from the running uid
#     ("detected dubious ownership"). Every container here runs as 1001 with a
#     matching fsGroup so the repo is created 1001:1001 and the question never
#     arises. Do not let the init container run as root.
# ---------------------------------------------------------------------------

locals {
  git_ns   = "git"
  git_repo = "repo.git"
  git_svc  = "git-server"
  git_port = 9418 # the IANA-registered git protocol port; git:// assumes it
  # Mount the volume somewhere the image does not already use. This is NOT
  # cosmetic: bitnami/git ships /srv as a symlink to /var/srv, so a PVC mounted
  # at /srv silently lands somewhere other than where every path in this file says.
  git_root  = "/repos"
  git_uid   = 1001
  git_image = "docker.io/buildpack-deps:bookworm-scm"

  cluster_git_url = var.enable_cluster_git ? "git://${local.git_svc}.${local.git_ns}.svc.cluster.local/${local.git_repo}" : ""
}

resource "kubectl_manifest" "git_namespace" {
  count = var.enable_cluster_git ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = local.git_ns, labels = { "app.kubernetes.io/part-of" = "drill-platform" } }
  })
}

# The repo outlives pod restarts but dies with the cluster, which is correct:
# GitHub is the durable copy and drill-progress/ is the durable practice record.
# No storageClassName on purpose: the cluster's default class is right in both
# places this runs (gp2/EBS on EKS, local-path on kind).
resource "kubectl_manifest" "git_pvc" {
  count = var.enable_cluster_git ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolumeClaim"
    metadata   = { name = "git-repo", namespace = local.git_ns }
    spec = {
      accessModes = ["ReadWriteOnce"]
      resources   = { requests = { storage = "1Gi" } }
    }
  })

  depends_on = [kubectl_manifest.git_namespace]
}

resource "kubectl_manifest" "git_server" {
  count = var.enable_cluster_git ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata   = { name = local.git_svc, namespace = local.git_ns }
    spec = {
      replicas = 1
      strategy = { type = "Recreate" } # one RWO volume; two pods cannot both mount it
      selector = { matchLabels = { app = local.git_svc } }
      template = {
        metadata = { labels = { app = local.git_svc } }
        spec = {
          securityContext = {
            runAsUser    = local.git_uid
            runAsGroup   = local.git_uid
            fsGroup      = local.git_uid
            runAsNonRoot = true
          }
          # Init containers run to completion before any main container starts, so
          # the daemon can never serve a directory that has not been initialised.
          initContainers = [{
            name    = "init-repo"
            image   = local.git_image
            command = ["/bin/sh", "-c"]
            args = [<<-EOT
              set -e
              if [ ! -d ${local.git_root}/${local.git_repo} ]; then
                git init --bare ${local.git_root}/${local.git_repo}
                touch ${local.git_root}/${local.git_repo}/git-daemon-export-ok
                echo "init-repo: created an empty bare repo, waiting for 'make git-seed'"
              else
                echo "init-repo: repo already present, leaving it alone"
              fi
            EOT
            ]
            volumeMounts = [{ name = "repo", mountPath = local.git_root }]
          }]
          containers = [{
            name  = "git"
            image = local.git_image
            command = [
              "git", "daemon",
              "--reuseaddr",
              "--base-path=${local.git_root}",
              "--export-all",
              "--enable=receive-pack", # the drill pushes; see the header
              "--informative-errors",  # otherwise every failure is just "access denied"
              "--verbose",             # the log is the only view into who cloned what
              "--listen=0.0.0.0",
              "--port=${local.git_port}",
            ]
            ports = [{ name = "git", containerPort = local.git_port }]
            # The readiness gate. An exec probe on the marker says exactly what is
            # meant - "the bundle has landed" - with no HTTP endpoint in between.
            readinessProbe = {
              exec                = { command = ["/bin/sh", "-c", "test -f ${local.git_root}/${local.git_repo}/.seeded"] }
              initialDelaySeconds = 2
              periodSeconds       = 3
            }
            livenessProbe = {
              tcpSocket           = { port = "git" }
              initialDelaySeconds = 10
              periodSeconds       = 20
            }
            volumeMounts = [{ name = "repo", mountPath = local.git_root }]
            resources = {
              requests = { cpu = "25m", memory = "48Mi" }
              limits   = { memory = "192Mi" }
            }
          }]
          volumes = [
            { name = "repo", persistentVolumeClaim = { claimName = "git-repo" } },
          ]
        }
      }
    }
  })

  depends_on = [kubectl_manifest.git_pvc]
}

resource "kubectl_manifest" "git_service" {
  count = var.enable_cluster_git ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata   = { name = local.git_svc, namespace = local.git_ns }
    spec = {
      selector = { app = local.git_svc }
      ports    = [{ name = "git", port = local.git_port, targetPort = "git" }]
    }
  })

  depends_on = [kubectl_manifest.git_server]
}
