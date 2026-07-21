# 05 - DNS, inside and out

**Time:** ~45 min. **Needs:** cluster up, app deployed. External half needs `enable_external_dns = true` + a Route53 zone you own (`dns_zone_name`).

Ticket: "Service A can't reach service B by name" is the most common page you'll ever get.
Learn how DNS actually flows in this cluster before it happens for real.

## Tasks

### In-cluster DNS

1. From a throwaway pod, resolve `practice-app-backend.practice-app.svc.cluster.local`.
   Then resolve just `practice-app-backend` from inside the same namespace. Why does the short name work?
2. Look at `/etc/resolv.conf` in a pod: what nameserver IP is in there, and what k8s object does it belong to?
3. Trace the chain: pod → kube-dns Service → CoreDNS pods → (for external names) the VPC resolver.
   Read the CoreDNS Corefile ConfigMap and identify which plugin does what.
4. Break it on purpose: scale CoreDNS to 0, watch in-cluster resolution die from a test pod, scale it back.
5. Resolve an external name (e.g. `www.wikipedia.org`) from a pod and explain who answered it.

### External DNS (optional, needs a hosted zone)

6. Turn on `enable_external_dns` + set `dns_zone_name` in `scripts/config.toml`, `make apply`.
7. Enable the Ingress with a `host` under your zone; watch external-dns create the Route53 record; open the app by name.
8. Delete the Ingress and confirm the record disappears (that's the `sync` policy at work).

## Success criteria (`make check N=05`)

- CoreDNS has ≥1 ready replica and in-cluster lookups resolve from a test pod.
- You can name the CoreDNS Service IP without looking it up again.
- (If external half done) the app answered on your own domain at least once.
