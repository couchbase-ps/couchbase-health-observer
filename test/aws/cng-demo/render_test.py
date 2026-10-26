#!/usr/bin/env python3
"""Architecture assertions over real Helm renders; no AWS or cluster required."""
import json, pathlib, subprocess, unittest
import yaml
ROOT = pathlib.Path(__file__).resolve().parents[3]
CHART = ROOT / 'deploy/aws/cng-demo/chart'
class Architecture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        p = subprocess.run(['helm','template','cng-demo',str(CHART),'-n','cng-demo',
            '--set','observerImage=example.com/observer@sha256:'+'1'*64,
            '--set','harnessImage=example.com/harness@sha256:'+'2'*64,
            '--set','envoy.enabled=true','--set','observerAddresses.a=10.0.0.1','--set','observerAddresses.b=10.0.0.2'],
            capture_output=True,text=True,check=True)
        cls.docs = [d for d in yaml.safe_load_all(p.stdout) if d]
    def objects(self, kind): return [x for x in self.docs if x['kind']==kind]
    def test_initial_database_stage_has_no_gateways_or_envoy(self):
        p=subprocess.run(['helm','template','cng-demo',str(CHART),'-n','cng-demo','--set','gateways.enabled=false','--set','envoy.enabled=false'],capture_output=True,text=True,check=True)
        docs=[d for d in yaml.safe_load_all(p.stdout) if d]
        containers=[c['name'] for d in docs if d['kind']=='Deployment' for c in d['spec']['template']['spec']['containers']]
        self.assertNotIn('cng',containers);self.assertNotIn('envoy',containers)
        self.assertIn('tools',containers)
    def test_full_backend_topology_and_storage(self):
        clusters=self.objects('CouchbaseCluster');self.assertEqual(len(clusters),2)
        a,b=sorted(clusters,key=lambda x:x['metadata']['name'])
        self.assertEqual([(s['size'],s['services']) for s in a['spec']['servers']],[(3,['data']),(2,['index','query'])])
        self.assertEqual([(s['size'],s['services']) for s in b['spec']['servers']],[(1,['data','index','query'])])
        for c in clusters:
            self.assertNotIn('cloudNativeGateway',c['spec'].get('networking',{}))
            self.assertEqual(c['spec']['cluster']['autoFailoverTimeout'],'30s')
            self.assertEqual(c['spec']['cluster']['autoFailoverMaxCount'],100)
            self.assertEqual(c['spec']['security']['adminSecret'],'cb-admin')
            self.assertEqual(c['spec']['cluster']['indexStorageSetting'],'plasma')
            for server in c['spec']['servers']:
                self.assertEqual(server['volumeMounts']['default'],'data')
                self.assertIn(server['pod']['spec']['nodeSelector']['demo.couchbase.com/pool'],['primary','secondary'])
        pvcs=self.objects('CouchbaseCluster')[0]['spec']['volumeClaimTemplates']
        self.assertEqual(pvcs[0]['spec']['storageClassName'],'cng-demo-gp3')
    def test_standalone_gateway_replicas_and_secrets(self):
        gateways=[d for d in self.objects('Deployment') if any(c['image'].startswith('couchbase/cloud-native-gateway:') for c in d['spec']['template']['spec']['containers'])]
        self.assertEqual(len(gateways),2)
        for d in gateways:
            self.assertEqual(d['spec']['replicas'],2)
            pod=d['spec']['template']['spec'];self.assertEqual(pod['nodeSelector']['demo.couchbase.com/pool'],'apps')
            self.assertEqual(len(pod['containers']),1)
            c=pod['containers'][0];self.assertIn('--cb-pass=$(CB_PASS)',c['args'])
            self.assertEqual(c['env'][1]['valueFrom']['secretKeyRef']['name'],'cb-admin')
            self.assertIn('requiredDuringSchedulingIgnoredDuringExecution',pod['affinity']['podAntiAffinity'])
    def test_headless_gateway_and_observer_health(self):
        services={s['metadata']['name']:s for s in self.objects('Service')}
        for role in ('a','b'):
            self.assertEqual(services['cng-'+role]['spec']['clusterIP'],'None')
            observer=next(d for d in self.objects('Deployment') if d['metadata']['name']=='observer-'+role)
            c=observer['spec']['template']['spec']['containers'][0]
            self.assertIn('--critical=kv',c['args']);self.assertIn('--probe-timeout=1s',c['args'])
            self.assertNotIn('--actuators=k8s',c['args'])
            self.assertNotEqual(c['readinessProbe']['httpGet']['path'],'/health/couchbase')
    def test_envoy_preserves_failover_contract(self):
        config=next(d for d in self.objects('ConfigMap') if d['metadata']['name']=='envoy-config')
        e=yaml.safe_load(config['data']['envoy.yaml']);cluster=e['static_resources']['clusters'][0]
        self.assertEqual(cluster['type'],'STRICT_DNS')
        self.assertTrue(cluster['close_connections_on_host_health_failure'])
        hc=cluster['health_checks'][0];self.assertEqual(hc['unhealthy_threshold'],12)
        self.assertEqual(hc['interval'],'5s');self.assertEqual(hc['timeout'],'4s')
        self.assertEqual(hc['http_health_check']['retriable_statuses'],[{'start':503,'end':504}])
        endpoints=cluster['load_assignment']['endpoints'];self.assertEqual([e['priority'] for e in endpoints],[0,1])
        for index,address in enumerate(('10.0.0.1','10.0.0.2')):
            self.assertEqual(endpoints[index]['lb_endpoints'][0]['endpoint']['health_check_config']['address']['socket_address']['address'],address)
    def test_cluster_replicas_and_quota_are_not_slimmed(self):
        buckets=sorted(self.objects('CouchbaseBucket'),key=lambda x:x['metadata']['namespace'])
        self.assertEqual([x['spec']['replicas'] for x in buckets],[1,0])
        for bucket in buckets:self.assertEqual(bucket['spec']['memoryQuota'],'512Mi')
        for c in self.objects('CouchbaseCluster'):
            self.assertEqual(c['spec']['cluster']['dataServiceMemoryQuota'],'2Gi')
            self.assertEqual(c['spec']['cluster']['indexServiceMemoryQuota'],'512Mi')
    def test_envoy_admin_is_loopback_only(self):
        config=next(d for d in self.objects('ConfigMap') if d['metadata']['name']=='envoy-config')
        e=yaml.safe_load(config['data']['envoy.yaml'])
        self.assertEqual(e['admin']['address']['socket_address']['address'],'127.0.0.1')
        service=next(s for s in self.objects('Service') if s['metadata']['name']=='envoy')
        self.assertEqual([p['name'] for p in service['spec']['ports']],['grpc'])
        envoy=next(c for d in self.objects('Deployment') for c in d['spec']['template']['spec']['containers'] if c['name']=='envoy')
        self.assertEqual([p['name'] for p in envoy['ports']],['grpc'])
        probe=envoy['readinessProbe'];self.assertNotIn('httpGet',probe)
        self.assertEqual(probe['exec']['command'][-2:],['/ready','9901'])
        import sys;sys.path.insert(0,str(ROOT/'deploy/aws/cng-demo/scripts'));import runner
        self.assertEqual(probe['exec']['command'][2],runner.ENVOY_ADMIN_GET)
    def test_couchbase_console_is_not_exposed(self):
        for c in self.objects('CouchbaseCluster'):
            self.assertNotIn('exposeAdminConsole',c['spec'].get('networking',{}))
    def test_server_image_passes_operator_crd_validation(self):
        import re
        # Pattern of CouchbaseCluster spec.image in Operator 2.9 (chart 2.93.0).
        crd=r'^(.*?(:\d+)?/)?.*?/.*?(:.*?\d+\.\d+\.\d+.*|@sha256:[0-9a-f]{64})$'
        for c in self.objects('CouchbaseCluster'):self.assertRegex(c['spec']['image'],crd)
    def test_cpu_quantities_are_canonical_for_server_side_apply(self):
        # The Operator rewrites 0.25 to 250m and owns the field; any other
        # spelling makes the next helm upgrade conflict.
        for c in self.objects('CouchbaseCluster'):
            self.assertEqual(c['spec']['autoResourceAllocation']['cpuRequests'],'250m')
            self.assertEqual(c['spec']['autoResourceAllocation']['cpuLimits'],'1')
if __name__=='__main__':unittest.main()
