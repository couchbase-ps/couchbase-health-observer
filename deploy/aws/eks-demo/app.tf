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
#
# Uses the built-in cbc-pillowfight load generator from the couchbase/server image (no
# custom image to build/push). It connects to the cluster in cb-conn and runs continuous
# KV ops against the observer bucket; on a switch the Lambda rolls this Deployment so its
# new pods pick up the region-b connstring. The container echoes the connstring at start
# so the target region is visible in the logs.
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
          name    = "traffic-app"
          image   = var.cb_server_image
          command = ["sh", "-c"]
          args = [
            "echo \"traffic-app -> $CONNSTRING\"; exec /opt/couchbase/bin/cbc-pillowfight -U \"$CONNSTRING/observer\" -u \"$CB_USER\" -P \"$CB_PASS\" --num-threads 1 --num-items 1000 --rate-limit 50",
          ]
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
