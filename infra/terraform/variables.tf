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
  # Keep this inside EKS standard support: older versions bill the much
  # higher extended-support rate for the control plane.
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.36"
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

variable "db_backup_retention_days" {
  # AWS Free plan accounts allow at most 1 day.
  description = "Days of automated RDS backups (replace the in-cluster backup CronJob)"
  type        = number
  default     = 7
}
