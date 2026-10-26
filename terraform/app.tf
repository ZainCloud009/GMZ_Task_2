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

  depends_on = [aws_eks_node_group.main]
}

# --------------------------------------------------
# Kubernetes Service (AWS Elastic Load Balancer)
# --------------------------------------------------
resource "kubernetes_service_v1" "health_service" {
  metadata {
    name = "gmz-health-service"
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
  }

  depends_on = [kubernetes_deployment_v1.health_app]
}
