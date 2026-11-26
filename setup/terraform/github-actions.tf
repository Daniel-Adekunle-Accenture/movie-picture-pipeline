############################################
# GitHub Actions deploy identity
############################################
# The Udacity lab role is denied iam:CreateOpenIDConnectProvider, so GitHub's OIDC
# federation is not available here. The CD workflows instead use an access key for this
# IAM user, stored only in GitHub Secrets (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY).
# Its permissions are limited to what the workflows need.
resource "aws_iam_user" "github_action_user" {
  provider = aws.untagged
  name     = "github-action-user"
  # The access key is created in the console (lesson step 4), outside Terraform;
  # this lets `terraform destroy` delete the user together with that key.
  force_destroy = true
}

# Only what the CD workflows use: ECR login, push/pull on the two project repositories,
# and reading the project cluster's endpoint for kubeconfig.
data "aws_iam_policy_document" "github_actions" {
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushProjectImages"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.frontend.arn, aws_ecr_repository.backend.arn]
  }

  statement {
    sid       = "DescribeProjectCluster"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.main.arn]
  }
}

# Customer managed policy + attachment (the lab role is denied iam:PutUserPolicy).
resource "aws_iam_policy" "github_action_user_permission" {
  provider = aws.untagged
  name     = "github-action-user-permission"
  policy   = data.aws_iam_policy_document.github_actions.json
}

resource "aws_iam_user_policy_attachment" "github_action_user_permission" {
  provider   = aws.untagged
  user       = aws_iam_user.github_action_user.name
  policy_arn = aws_iam_policy.github_action_user_permission.arn
}

# Kubernetes access through an EKS access entry: edit rights in the namespace the
# starter manifests deploy to, instead of cluster admin (replaces setup/init.sh).
resource "aws_eks_access_entry" "github_action_user" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_user.github_action_user.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_action_user" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_user.github_action_user.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [var.app_namespace]
  }

  depends_on = [aws_eks_access_entry.github_action_user]
}
