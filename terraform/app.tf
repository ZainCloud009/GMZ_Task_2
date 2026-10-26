# --------------------------------------------------
# Optional: Docker Hub Credentials Secret for Private Repositories
# --------------------------------------------------
resource "kubernetes_secret_v1" "dockerhub_secret" {
  count = var.docker_password != "" ? 1 : 0

  metadata {
    name = "dockerhub-secret"
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "https://index.docker.io/v1/" = {
          "username" = var.docker_username
          "password" = var.docker_password
          "auth"     = base64encode("${var.docker_username}:${var.docker_password}")
        }
      }
    })
  }

  depends_on = [aws_eks_node_group.main]
}

# --------------------------------------------------
# Kubernetes Deployment for Node.js Health Application
# --------------------------------------------------
resource "kubernetes_deployment_v1" "health_app" {
  metadata {
    name = "gmz-health-app"
    labels = {
      app = "gmz-health-app"
    }
  }

  wait_for_rollout = false

  spec {
    replicas = var.app_replicas

    selector {
      match_labels = {
        app = "gmz-health-app"
      }
    }

    template {
      metadata {
        labels = {
          app = "gmz-health-app"
        }
      }

      spec {
        dynamic "image_pull_secrets" {
          for_each = var.docker_password != "" ? [1] : []
          content {
            name = kubernetes_secret_v1.dockerhub_secret[0].metadata[0].name
          }
        }

        container {
          name              = "health-app-container"
          image             = var.docker_image
          image_pull_policy = "Always"

          port {
            container_port = 3000
          }

          env {
            name  = "AWS_REGION"
            value = var.aws_region
          }

          env {
            name  = "DB_SECRET_NAME"
            value = aws_secretsmanager_secret.db_secret.name
          }

          env {
            name  = "ADMINER_SERVICE_URL"
            value = "http://gmz-adminer-service:8080"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 3000
            }
            initial_delay_seconds = 15
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 3000
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }

  depends_on = [
    aws_eks_node_group.main,
    aws_db_instance.postgres,
    aws_secretsmanager_secret_version.db_secret_val
  ]
}

# --------------------------------------------------
# Kubernetes Service (AWS Elastic Load Balancer with SSL)
# --------------------------------------------------
resource "kubernetes_service_v1" "health_service" {
  metadata {
    name = "gmz-health-service"
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"         = "arn:aws:acm:eu-north-1:634236768016:certificate/ffad07b4-c0d7-4748-bcdd-3f5d77406911"
      "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"        = "https"
      "service.beta.kubernetes.io/aws-load-balancer-backend-protocol" = "http"
    }
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = "gmz-health-app"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 3000
      protocol    = "TCP"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 3000
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_deployment_v1.health_app]
}

# --------------------------------------------------
# Adminer Deployment (PostgreSQL Web GUI / phpMyAdmin equivalent)
# --------------------------------------------------
resource "kubernetes_deployment_v1" "adminer" {
  metadata {
    name = "gmz-db-adminer"
    labels = {
      app = "gmz-db-adminer"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "gmz-db-adminer"
      }
    }

    template {
      metadata {
        labels = {
          app = "gmz-db-adminer"
        }
      }

      spec {
        container {
          name  = "adminer"
          image = "adminer:latest"

          port {
            container_port = 8080
          }

          env {
            name  = "ADMINER_DEFAULT_SERVER"
            value = aws_db_instance.postgres.address
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [aws_eks_node_group.main, aws_db_instance.postgres]
}

# --------------------------------------------------
# Adminer ClusterIP Service
# --------------------------------------------------
resource "kubernetes_service_v1" "adminer_service" {
  metadata {
    name = "gmz-adminer-service"
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "gmz-db-adminer"
    }

    port {
      port        = 8080
      target_port = 8080
    }
  }

  depends_on = [kubernetes_deployment_v1.adminer]
}
