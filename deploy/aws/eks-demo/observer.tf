# The detector fleet: N observer replicas in observe mode, each watching region-a via its
# own SDK connection and serving /health/couchbase. The monitoring ALB target group
# health-checks them (registered by the TargetGroupBinding below); CloudWatch turns the
# unhealthy ratio into the quorum decision.
resource "kubernetes_deployment" "observer" {
  metadata {
    name      = "cb-observer-health"
    namespace = "default"
    labels    = { app = "cb-observer-health" }
  }
  spec {
    replicas = var.observer_replicas
    selector {
      match_labels = { app = "cb-observer-health" }
    }
    template {
      metadata {
        labels = { app = "cb-observer-health" }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = { app = "cb-observer-health" }
          }
        }
        container {
          name  = "observer"
          image = var.observer_image
          args = [
            "--mode=observe",
            "--conn=couchbase://region-a-srv.region-a.svc",
            "--bucket=observer",
            "--user=${var.cb_username}",
            "--pass=${var.cb_password}",
            "--critical=kv",
            "--addr=:8080",
          ]
          port {
            container_port = 8080
          }
          # probes use /healthz (static) so a Couchbase-DOWN keeps the pod Ready and
          # registered; only the ALB target group checks /health/couchbase.
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
      }
    }
  }

  depends_on = [helm_release.region_a]
}

resource "kubernetes_service" "observer" {
  metadata {
    name      = "cb-observer-health"
    namespace = "default"
  }
  spec {
    selector = { app = "cb-observer-health" }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

# Register the observer pods into the monitoring target group (no Ingress). Uses the
# kubectl provider because the TargetGroupBinding CRD is installed by the ALB controller
# in this same apply (the kubernetes_manifest resource would require the CRD at plan time).
resource "kubectl_manifest" "target_group_binding" {
  yaml_body = yamlencode({
    apiVersion = "elbv2.k8s.aws/v1beta1"
    kind       = "TargetGroupBinding"
    metadata = {
      name      = "cb-observer-health-monitoring"
      namespace = "default"
    }
    spec = {
      serviceRef     = { name = "cb-observer-health", port = 8080 }
      targetGroupARN = module.agg.monitoring_target_group_arn
      targetType     = "ip"
    }
  })

  depends_on = [helm_release.alb, kubernetes_service.observer, module.agg]
}
