# Managed Kubernetes: AWS runs the control plane, we run two worker nodes.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # No pod needs its own AWS role (IRSA), so no OIDC identity provider.
  # It is also blocked on AWS Free plan accounts.
  enable_irsa = false

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  # The module only opens ports 1025-65535 between nodes. Pods also talk to the
  # Ingress controller on port 80 across nodes (e.g. the in-cluster k6 Job).
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node, all ports"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  eks_managed_node_groups = {
    general = {
      # Amazon Linux 2 images stop at Kubernetes 1.32; AL2023 covers newer versions.
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
    }
  }
}
