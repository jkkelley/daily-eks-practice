# 06 - Storage: EBS volumes + S3 from a pod

**Time:** ~45 min. **Needs:** cluster up. S3 half needs `enable_practice_bucket = true`.
**Cost note:** EBS bills per provisioned GB-month. Stay at 1-4 GB and delete PVCs when done - `make down` will not delete volumes left behind by dynamic provisioning if their PVs outlive the cluster.

Ticket: "The new service needs a small persistent scratch disk, and the batch job needs to drop files in S3 - without any AWS keys in the pod, obviously."

## Tasks

### EBS via the CSI driver

1. Confirm the `aws-ebs-csi-driver` add-on is installed and its controller pods are running.
2. Is there a default StorageClass? What provisioner does it use, and is it gp2 or gp3?
   Create a gp3 StorageClass (with `WaitForFirstConsumer`) if one doesn't exist.
3. Create a 1Gi PVC + a pod that mounts it and writes a timestamp file every few seconds.
4. Find the actual EBS volume in the EC2 console. Check its tags - can you tell which PVC owns it?
5. Kill the pod; confirm the data survives when a replacement pod mounts the same PVC.
6. Expand the PVC to 2Gi live. Did the filesystem grow? What made that possible?
7. Delete the PVC and verify the EBS volume is gone from the console (reclaim policy).

### S3 via IRSA (no keys anywhere)

8. Find the pre-made `s3-explorer` service account in `practice-app` and read its annotation.
9. Run a pod with the AWS CLI image under that service account; list the practice bucket, upload a file, read it back.
10. Run the same pod WITHOUT the service account and watch S3 say no. Explain exactly where the first pod's credentials came from (token file → STS → role).

## Success criteria (`make check N=06`)

- A gp3 StorageClass exists.
- No leftover practice PVCs/PVs (you cleaned up).
- The practice bucket contains (or contained) an object you put there from a pod.
