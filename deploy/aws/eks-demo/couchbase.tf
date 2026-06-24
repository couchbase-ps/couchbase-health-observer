# Two Couchbase clusters via the official Couchbase Operator chart (operator + admission
# controller + CouchbaseCluster per release). region-a is the slim primary (3 data nodes),
# region-b the single-node secondary.
locals {
  cb_common = {
    install = {
      couchbaseOperator   = true
      admissionController = true
      couchbaseCluster    = true
      syncGateway         = false
    }
    couchbaseOperator = { scope = "Role" }
    buckets = {
      default = null
      observer = {
        memoryQuota    = "100Mi"
        replicas       = 1
        storageBackend = "couchstore"
      }
    }
    cluster = {
      image                  = "couchbase/server:8.0.1"
      antiAffinity           = false
      autoResourceAllocation = { enabled = true, cpuRequests = "0.25", cpuLimits = "1" }
      security               = { username = var.cb_username, password = var.cb_password }
      buckets                = { managed = true }
      cluster = {
        dataServiceMemoryQuota = "256Mi"
        autoFailoverTimeout    = "5s"
        autoFailoverMaxCount   = 1
      }
    }
  }
}

resource "helm_release" "region_a" {
  name             = "region-a"
  namespace        = "region-a"
  create_namespace = true
  repository       = "https://couchbase-partners.github.io/helm-charts/"
  chart            = "couchbase-operator"
  version          = "2.92.0"
  wait             = true
  timeout          = 900

  values = [yamlencode({
    couchbase-operator = merge(local.cb_common, {
      cluster = merge(local.cb_common.cluster, {
        name    = "region-a"
        servers = { default = null, data = { size = 3, services = ["data"] } }
      })
    })
  })]

  depends_on = [helm_release.alb]
}

resource "helm_release" "region_b" {
  name             = "region-b"
  namespace        = "region-b"
  create_namespace = true
  repository       = "https://couchbase-partners.github.io/helm-charts/"
  chart            = "couchbase-operator"
  version          = "2.92.0"
  wait             = true
  timeout          = 900

  values = [yamlencode({
    couchbase-operator = merge(local.cb_common, {
      buckets = merge(local.cb_common.buckets, { observer = merge(local.cb_common.buckets.observer, { replicas = 0 }) })
      cluster = merge(local.cb_common.cluster, {
        name    = "region-b"
        servers = { default = null, data = { size = 1, services = ["data"] } }
      })
    })
  })]

  depends_on = [helm_release.region_a]
}
