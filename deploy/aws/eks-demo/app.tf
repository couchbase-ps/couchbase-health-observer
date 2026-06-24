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

resource "kubernetes_deployment" "mock_app" {
  metadata {
    name      = "mock-app"
    namespace = "default"
    labels    = { app = "mock-app" }
  }
  spec {
    replicas = 2
    selector {
      match_labels = { app = "mock-app" }
    }
    template {
      metadata {
        labels = { app = "mock-app" }
      }
      spec {
        container {
          name    = "mock-app"
          image   = "busybox:1.36"
          command = ["sh", "-c", "while true; do echo connstring=$CONNSTRING; sleep 5; done"]
          env {
            name = "CONNSTRING"
            value_from {
              config_map_key_ref {
                name = "cb-conn"
                key  = "connstring"
              }
            }
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
