variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "name" {
  description = "Name used for the cluster and every resource"
  type        = string
  default     = "nephele"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "EC2 type for the worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "db_instance_class" {
  description = "RDS instance size"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Keep a standby database in a second Availability Zone"
  type        = bool
  default     = false
}
