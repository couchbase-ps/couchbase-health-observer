# The dependent application: reads its Couchbase connection string from a ConfigMap. The
# switch Lambda flips this ConfigMap and rolls the Deployment on a sustained quorum-DOWN.
resource "kubernetes_config_map" "cb_conn" {
  metadata {
    name      = "cb-conn"
    namespace = "default"
  }
  data = {
    connstring = "couchbase://region-a-srv.region-a.svc"
  }
}

# A real Couchbase workload: continuously upserts/reads a doc against the cluster named in
# cb-conn, logging each op. On a switch the Lambda flips cb-conn to region-b and rolls this
# Deployment, so its new pods re-bootstrap against region-b -- you can watch ops fail on
# the dead cluster and resume on the secondary.
resource "kubernetes_deployment" "traffic_app" {
  metadata {
    name      = "traffic-app"
    namespace = "default"
    labels    = { app = "traffic-app" }
  }
  spec {
    replicas = 2
    selector {
      match_labels = { app = "traffic-app" }
    }
    template {
      metadata {
        labels = { app = "traffic-app" }
      }
      spec {
        container {
          name  = "traffic-app"
          image = var.traffic_image
          env {
            name = "CONNSTRING"
            value_from {
              config_map_key_ref {
                name = "cb-conn"
                key  = "connstring"
              }
            }
          }
          env {
            name  = "BUCKET"
            value = "observer"
          }
          env {
            name  = "CB_USER"
            value = var.cb_username
          }
          env {
            name  = "CB_PASS"
            value = var.cb_password
          }
        }
      }
    }
  }

  lifecycle {
    # the switch Lambda stamps a restart annotation on the pod template; do not fight it
    ignore_changes = [spec[0].template[0].metadata[0].annotations]
  }
}
