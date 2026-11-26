#!/bin/bash
# Removes everything this project created, in the order AWS needs.
# Destructive: run only when the project no longer needs to be live.
set -euo pipefail
cd "$(dirname "$0")"
REGION=us-east-1
export AWS_PAGER=""

# 1. Delete the Kubernetes LoadBalancer Services first so AWS releases their load
#    balancers, which would otherwise block deletion of the VPC.
aws eks update-kubeconfig --name cluster --region "$REGION" >/dev/null
kubectl delete service frontend backend --ignore-not-found --wait=true
kubectl delete deployment frontend backend --ignore-not-found

VPC=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=udacity Name=tag:Project,Values=movie-picture-pipeline \
  --query 'Vpcs[0].VpcId' --output text)
echo "Waiting for load balancers in $VPC to be released..."
for i in $(seq 1 30); do
  CLB=$(aws elb describe-load-balancers --query "length(LoadBalancerDescriptions[?VPCId=='${VPC}'])" --output text)
  ALB=$(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?VpcId=='${VPC}'])" --output text)
  echo "  classic=$CLB v2=$ALB"
  [ "$CLB" = "0" ] && [ "$ALB" = "0" ] && break
  sleep 10
done

# 2. Destroy the Terraform-managed infrastructure (VPC, ECR, EKS, IAM).
./bootstrap-state.sh >/dev/null
cd terraform
terraform init -input=false -backend-config=backend.hcl >/dev/null
terraform destroy -input=false -auto-approve

# 3. Delete the Terraform state bucket, including every object version.
BUCKET=$(sed -n 's/^bucket *= *"\(.*\)"/\1/p' backend.hcl)
python3 - "$BUCKET" <<'PY'
import json, subprocess, sys
bucket = sys.argv[1]
out = subprocess.run(["aws", "s3api", "list-object-versions", "--bucket", bucket, "--output", "json"],
                     check=True, capture_output=True, text=True).stdout
data = json.loads(out or "{}")
objs = [{"Key": o["Key"], "VersionId": o["VersionId"]} for o in data.get("Versions", []) + data.get("DeleteMarkers", [])]
for i in range(0, len(objs), 1000):
    subprocess.run(["aws", "s3api", "delete-objects", "--bucket", bucket,
                    "--delete", json.dumps({"Objects": objs[i:i + 1000], "Quiet": True})], check=True)
print(f"deleted {len(objs)} object versions from {bucket}")
PY
aws s3api delete-bucket --bucket "$BUCKET"
rm -f backend.hcl

# 4. Leftover check: everything below should be empty.
aws eks list-clusters --query clusters --output text
aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
aws ec2 describe-vpcs --filters Name=tag:Project,Values=movie-picture-pipeline --query 'Vpcs[].VpcId' --output text
aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
aws iam list-roles --query "Roles[?RoleName=='eks_cluster_role' || RoleName=='udacity-node-group'].RoleName" --output text
aws iam list-users --query "Users[?UserName=='github-action-user'].UserName" --output text
aws iam list-policies --scope Local --query "Policies[?PolicyName=='github-action-user-permission'].PolicyName" --output text
aws s3api list-buckets --query "Buckets[?starts_with(Name, 'movie-picture-tfstate-')].Name" --output text
echo "Teardown finished."
