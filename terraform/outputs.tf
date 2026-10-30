output "cluster_name" {
  description = "Name of the EKS Cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.main.endpoint
}

output "kubeconfig_command" {
  description = "Command to connect local kubectl with the new EKS cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}

output "load_balancer_hostname" {
  description = "Public URL / Hostname of the AWS Load Balancer"
  value       = try(kubernetes_service_v1.health_service.status[0].load_balancer[0].ingress[0].hostname, "Pending provisioning by AWS...")
}

output "rds_endpoint" {
  description = "The connection endpoint for the RDS MySQL instance"
  value       = aws_db_instance.mysql.endpoint
}

output "rds_hostname" {
  description = "Hostname of RDS MySQL instance (for DB_HOST in Infisical)"
  value       = aws_db_instance.mysql.address
}

output "rds_password" {
  description = "Database master password (for DB_PASSWORD in Infisical)"
  value       = random_password.db_password.result
  sensitive   = true
}

output "rds_username" {
  description = "Database master user (for DB_USER in Infisical)"
  value       = aws_db_instance.mysql.username
}

output "rds_dbname" {
  description = "Database name (for DB_NAME in Infisical)"
  value       = aws_db_instance.mysql.db_name
}
