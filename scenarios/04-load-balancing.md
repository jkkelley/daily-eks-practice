# 04 - Load balancing (NLB + ALB)

**Time:** ~45 min. **Needs:** cluster up, app deployed, `enable_alb_controller = true`.
**Cost note:** each LB is ~$0.02/hr + per-hour LCU/IP charges. Delete them (revert your changes) before `make down` - the controller must remove them BEFORE the cluster dies, or they orphan.

Ticket: "The app needs to be reachable from the internet. Expose it properly, both ways we use at work: an NLB for raw TCP and an ALB via Ingress for HTTP."

## Tasks

1. Confirm the AWS Load Balancer Controller is running. Whose credentials is it using? (Hint: look at its service account.)
2. Switch the frontend Service to `type: LoadBalancer` in values and deploy.
   Watch the NLB appear in the EC2 console; open the app through it.
3. Inspect: what target type is it using (instance vs ip)? Why does that matter on EKS?
4. Revert the Service to ClusterIP. Enable the Ingress in values instead and deploy.
   Watch the ALB provision; open the app through the ALB DNS name.
5. In the console, look at the ALB's target group health checks - map each healthy target back to a pod IP.
6. Break it on purpose: scale the frontend to 0 and watch the target group drain. Scale back.
7. Clean up: disable the Ingress (and any LoadBalancer Service), confirm the ALB/NLB are actually gone from the console.

## Success criteria (`make check N=04`)

- At some point an Ingress existed with an ADDRESS (the check accepts either a live ALB or a cleaned-up state with the controller healthy).
- ALB controller deployment is ready in kube-system.
- No orphaned load balancers after cleanup (check knows the tag to look for).
