# 01 - Lay of the land

**Time:** ~30 min. **Needs:** cluster up (`make up`), kubeconfig (`make kubeconfig`).

You just joined the team and got handed a cluster.
Before touching anything, learn what is running, where, and why.
Do every task twice: once with `kubectl`, once in the AWS console (EKS UI), so both views feel like home.

## Tasks

1. List the nodes.
   For each node find: instance type, capacity type (spot or on-demand), AZ, kubelet version, and how many pods it can hold.
2. List every namespace and say (out loud, to nobody) what each one is for.
3. Count all running pods and find which node each `practice-app` pod landed on.
4. Find the CoreDNS deployment: how many replicas, what image version.
5. In the EKS console: find the cluster's Kubernetes version, the add-on versions, and the node group's scaling config.
6. In the EC2 console: find the instances backing your nodes and the tags terraform put on them.
7. Look at the practice app in a browser without any Ingress or LoadBalancer existing.
8. Find the RDS instance in the console; from a pod, prove you can reach it on port 5432 without any DB client installed.

## Success criteria (`make check N=01`)

- Cluster reachable, ≥1 Ready node.
- `practice-app` namespace has running frontend + backend pods.
- You can explain what every namespace holds without looking.
