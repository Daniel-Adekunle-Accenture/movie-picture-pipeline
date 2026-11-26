#!/bin/bash
# Creates (or finds) the private S3 bucket that holds this project's Terraform state,
# then writes setup/terraform/backend.hcl for `terraform init -backend-config=backend.hcl`.
# Safe to re-run, including after a workspace reset.
set -euo pipefail
cd "$(dirname "$0")/terraform"
REGION=us-east-1
PREFIX=movie-picture-tfstate-

BUCKET=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${PREFIX}')].Name | [0]" --output text)
if [ -z "$BUCKET" ] || [ "$BUCKET" = "None" ]; then
  BUCKET="${PREFIX}$(openssl rand -hex 4)"
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging 'TagSet=[{Key=Project,Value=movie-picture-pipeline}]'
  echo "Created state bucket $BUCKET"
else
  echo "Using existing state bucket $BUCKET"
fi

cat > backend.hcl <<EOF
bucket  = "${BUCKET}"
key     = "movie-picture-pipeline/terraform.tfstate"
region  = "${REGION}"
encrypt = true
EOF
echo "Wrote $(pwd)/backend.hcl"
