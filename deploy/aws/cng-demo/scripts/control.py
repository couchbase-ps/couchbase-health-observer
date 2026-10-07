#!/usr/bin/env python3
"""Lifecycle and workload contracts shared by AWS orchestration and validation."""
import json, pathlib, re, subprocess, os

def assert_owner(owner, actual):
    for key in ('account', 'name', 'region'):
        if owner.get(key) != actual.get(key):
            raise ValueError('demo ownership mismatch: '+key)
    if not re.fullmatch(r'cng-demo(?:-[a-z0-9-]+)?', owner['name']):
        raise ValueError('invalid demo stack name')

def assert_gateways(pods, expected_removals=None):
    for pod in pods['items']:
        if pod['metadata']['name'] in (expected_removals or set()):continue
        for c in pod.get('status', {}).get('containerStatuses', []):
            if c.get('restartCount', 0) or 'terminated' in c.get('state', {}):
                raise ValueError('unexpected gateway termination/restart: '+pod['metadata']['name'])

def gateway_identity(pods):
    return {p['metadata']['name']:p['metadata']['uid'] for p in pods['items']}

def assert_gateway_identity(before, after, expected_removals):
    for name, uid in before.items():
        if name not in expected_removals and after.get(name) != uid:
            raise ValueError('unexpected gateway replacement: '+name)

def assert_fleet_connections(counts):
    if len(counts)<2 or any(count<=0 for count in counts.values()):
        raise ValueError('every primary gateway must receive actual client connections')

def harness_job(name, seconds, run_id, image, startup=True, region='a', extra=None):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]*', name):
        raise ValueError('invalid workload name')
    values={'CB_CONN':'couchbase2://envoy.cng-demo.svc.cluster.local','CB_BUCKET':'lbtest',
            'TLS_CA':'/certs/ca.crt','OPS_PER_SEC':'20','QUERY_PER_SEC':'1','RUN_SECONDS':str(seconds),
            'RUN_ID':run_id,'OUT_CSV':'/out/'+name+'.csv','STARTUP_CSV':'/out/'+name+'.startup.csv',
            'READY_FILE':'/out/'+name+'.ready.json','STARTUP_REQUIRED':str(startup).lower(),'EXPECTED_REGION':region}
    values.update(extra or {})
    env=[{'name':k,'value':v} for k,v in values.items()]
    env += [{'name':k,'valueFrom':{'secretKeyRef':{'name':'cb-admin','key':field}}} for k,field in [('CB_USER','username'),('CB_PASS','password')]]
    return {'apiVersion':'batch/v1','kind':'Job','metadata':{'name':'harness-'+name,'namespace':'cng-demo','labels':{'demo.couchbase.com/stack':'cng-demo','demo.couchbase.com/run':run_id}},
      'spec':{'backoffLimit':0,'template':{'metadata':{'labels':{'app':'harness','demo.couchbase.com/stack':'cng-demo','demo.couchbase.com/run':run_id}},'spec':{
       'restartPolicy':'Never','automountServiceAccountToken':False,'nodeSelector':{'demo.couchbase.com/pool':'apps'},
       'affinity':{'podAffinity':{'requiredDuringSchedulingIgnoredDuringExecution':[{'labelSelector':{'matchLabels':{'app':'cng-demo-tools'}},'topologyKey':'kubernetes.io/hostname'}]}},
       'containers':[{'name':'harness','image':image,'env':env,'resources':{'requests':{'cpu':'100m','memory':'256Mi'},'limits':{'memory':'768Mi'}},
         'volumeMounts':[{'name':'out','mountPath':'/out'},{'name':'certs','mountPath':'/certs','readOnly':True},{'name':'bad-ca','mountPath':'/bad','readOnly':True}]}],
       'volumes':[{'name':'out','persistentVolumeClaim':{'claimName':'cng-demo-output'}},{'name':'certs','secret':{'secretName':'cng-tls'}},{'name':'bad-ca','secret':{'secretName':'bad-ca'}}]}}}}

class Kube:
    def __init__(self, kubeconfig):
        self.prefix=[os.environ.get('KUBECTL','kubectl'),'--kubeconfig',str(kubeconfig),'--request-timeout=30s']
    def run(self,*args,input=None,check=True,timeout=60):
        p=subprocess.run(self.prefix+list(args),input=input,text=True,capture_output=True,timeout=timeout)
        if check and p.returncode:
            raise RuntimeError('kubectl '+args[0]+' failed: '+p.stderr.strip())
        return p
    def get(self,kind,namespace=None,selector=None):
        args=['get',kind,'-o','json']
        if namespace:args+=['-n',namespace]
        elif kind in ('pods','events','services','jobs','pvc'):args+=['-A']
        if selector:args+=['-l',selector]
        return json.loads(self.run(*args).stdout)
    def apply(self,obj):return self.run('apply','-f','-',input=json.dumps(obj))
    def exec(self,code,args=(),timeout=60):
        return self.run('exec','-n','cng-demo','deployment/cng-demo-tools','--','python3','-c',code,*args,timeout=timeout).stdout
