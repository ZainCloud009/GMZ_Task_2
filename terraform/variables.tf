variable "aws_region" {
  description = "AWS Region for deployment"
  type        = string
  default     = "eu-north-1"
}

variable "cluster_name" {
  description = "Name of the EKS Cluster"
  type        = string
  default     = "gmz-k8s-cluster"
}

variable "node_instance_type" {
  description = "EC2 Instance type for worker nodes"
  type        = string
  default     = "t3.small"
}

variable "docker_image" {
  description = "Docker image for the health app"
  type        = string
  default     = "zaindevops009/gmz-health-app:latest"
}

variable "docker_username" {
  description = "Docker Hub Username"
  type        = string
  default     = "zaindevops009"
}

variable "docker_password" {
  description = "Docker Hub Password or Token (optional if public)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "app_replicas" {
  description = "Number of pod replicas"
  type        = number
  default     = 2
}
