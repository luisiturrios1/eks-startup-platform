locals {
  karpenter_tagging_statements = [
    {
      Sid      = "TagOnCreation"
      Effect   = "Allow"
      Action   = ["ec2:CreateTags"]
      Resource = [for kind in ["fleet", "instance", "volume", "network-interface", "launch-template", "spot-instances-request"] : "arn:${local.partition}:ec2:${var.region}:${var.account_id}:${kind}/*"]
      Condition = {
        StringEquals = {
          "aws:RequestTag/kubernetes.io/cluster/${local.name}" = "owned"
          "ec2:CreateAction"                                   = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
        }
        StringLike = { "aws:RequestTag/karpenter.sh/nodepool" = "*" }
      }
    },
    {
      Sid      = "TagOwnedInstances"
      Effect   = "Allow"
      Action   = ["ec2:CreateTags"]
      Resource = "arn:${local.partition}:ec2:${var.region}:${var.account_id}:instance/*"
      Condition = {
        StringEquals                = { "aws:ResourceTag/kubernetes.io/cluster/${local.name}" = "owned" }
        StringLike                  = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" }
        "ForAllValues:StringEquals" = { "aws:TagKeys" = ["Name", "karpenter.sh/nodeclaim", "eks:eks-cluster-name"] }
        StringEqualsIfExists        = { "aws:RequestTag/eks:eks-cluster-name" = local.name }
      }
    }
  ]
}

resource "aws_iam_role_policy" "karpenter" {
  role = aws_iam_role.karpenter.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect    = "Allow"
        Action    = ["ec2:Describe*", "ssm:GetParameter"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.region } }
      },
      {
        Effect = "Allow"
        Action = ["ec2:RunInstances", "ec2:CreateFleet"]
        Resource = [
          "arn:${local.partition}:ec2:${var.region}::image/*",
          "arn:${local.partition}:ec2:${var.region}::snapshot/*",
          "arn:${local.partition}:ec2:${var.region}:${var.account_id}:subnet/*",
          "arn:${local.partition}:ec2:${var.region}:${var.account_id}:security-group/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
        Resource = [for kind in ["instance", "volume", "network-interface", "fleet", "spot-instances-request", "launch-template"] : "arn:${local.partition}:ec2:${var.region}:${var.account_id}:${kind}/*"]
        Condition = {
          StringEquals = { "aws:RequestTag/kubernetes.io/cluster/${local.name}" = "owned" }
          StringLike   = { "aws:RequestTag/karpenter.sh/nodepool" = "*" }
        }
      },
      {
        Effect    = "Allow"
        Action    = ["ec2:RunInstances", "ec2:CreateFleet"]
        Resource  = "arn:${local.partition}:ec2:${var.region}:${var.account_id}:launch-template/*"
        Condition = { StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${local.name}" = "owned" } }
      }
      ], local.karpenter_tagging_statements, [
      {
        Effect   = "Allow"
        Action   = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
        Resource = ["arn:${local.partition}:ec2:${var.region}:${var.account_id}:instance/*", "arn:${local.partition}:ec2:${var.region}:${var.account_id}:launch-template/*"]
        Condition = {
          StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${local.name}" = "owned" }
          StringLike   = { "aws:ResourceTag/karpenter.sh/nodepool" = "*" }
        }
      },
      {
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.karpenter_node.arn
        Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } }
      },
      { Effect = "Allow", Action = "eks:DescribeCluster", Resource = aws_eks_cluster.this.arn },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.interruptions.arn
      }
    ])
  })
}
