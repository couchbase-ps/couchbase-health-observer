#!/usr/bin/env python3
"""Kubernetes CNG scenarios with retained failures and unchanged measurement budgets."""
import base64,csv,http.client,io,importlib.util,json,os,pathlib,re,subprocess,threading,time,urllib.parse
from control import Kube,assert_gateways,gateway_identity,assert_gateway_identity,assert_fleet_connections,harness_job
ROOT=pathlib.Path(__file__).resolve().parents[4]
spec=importlib.util.spec_from_file_location('evidence',ROOT/'test/compose-cng/evidence.py')
evidence=importlib.util.module_from_spec(spec);spec.loader.exec_module(evidence)

# Envoy admin listens on loopback only; read it inside the Envoy pod. Args: path, port.
# Envoy rejects HTTP/1.0 (426) and answers HTTP/1.1 chunked; envoy_admin_body decodes it.
ENVOY_ADMIN_GET=r'''exec 3<>/dev/tcp/127.0.0.1/"$2" || exit 1
printf 'GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' "$1" >&3
IFS= read -r status <&3
case "$status" in *" 200 "*) ;; *) exit 1;; esac
printf '%s\n' "$status"
cat <&3'''

def envoy_admin_body(raw):
    class Raw:
        def makefile(self,*a,**k):return io.BytesIO(raw)
    r=http.client.HTTPResponse(Raw());r.begin()
    if r.status!=200:raise ValueError('Envoy admin returned '+str(r.status))
    return r.read().decode()

def envoy_admin_args(path):
    return ['exec','-n','cng-demo','deployment/envoy','-c','envoy','--','bash','-c',ENVOY_ADMIN_GET,'envoy-admin',path,'9901']

def pods_with_service(pods,service):
    # Operator 2.9 marks each enabled service as couchbase_service_<name>=enabled.
    return sorted([p for p in pods if p['metadata']['labels'].get('couchbase_service_'+service)=='enabled'],key=lambda p:p['metadata']['name'])

def query_success(response,expected=None):
    if response.get('status')!='success' or response.get('errors') or expected is not None and (response.get('results')!=expected or any(type(a) is not type(b) for a,b in zip(response.get('results',[]),expected))):
        raise ValueError('query did not return required successful result')

def require_certificate_rejection(result):
    if not result.get('certificate_error'):
        raise ValueError('wrong CA control did not prove certificate rejection')

def quantity(s,cpu=False):
    s=str(s)
    if cpu:return float(s[:-1])/1000 if s.endswith('m') else float(s)
    units={'Ki':1024,'Mi':1024**2,'Gi':1024**3,'K':1000,'M':1000**2,'G':1000**3}
    for suffix,factor in units.items():
        if s.endswith(suffix):return float(s[:-len(suffix)])*factor
    return float(s)

def capacity_report(nodes,pods):
    report={n['metadata']['name']:{'cpu':quantity(n['status']['allocatable']['cpu'],True),'memory':quantity(n['status']['allocatable']['memory']),'requested_cpu':0,'requested_memory':0} for n in nodes['items']}
    for p in pods['items']:
        if p.get('status',{}).get('phase') in ('Succeeded','Failed'):continue
        node=p['spec'].get('nodeName')
        if node not in report:continue
        for resource,cpu in [('cpu',True),('memory',False)]:
            regular=sum(quantity(c.get('resources',{}).get('requests',{}).get(resource,'0'),cpu) for c in p['spec']['containers'])
            initial=max((quantity(c.get('resources',{}).get('requests',{}).get(resource,'0'),cpu) for c in p['spec'].get('initContainers',[])),default=0)
            report[node]['requested_'+resource]+=max(regular,initial)
    for node,r in report.items():
        if r['requested_cpu']>r['cpu'] or r['requested_memory']>r['memory']:raise ValueError('pod requests exceed allocatable: '+node)
    return report

def connection_counts(text,ips):
    counts={ip:0 for ip in ips}
    for ip in ips:
        match=re.search(r'cng_cluster::'+re.escape(ip)+r':18098::cx_total::(\d+)',text)
        if match:counts[ip]=int(match[1])
    return counts

class Runner:
    def __init__(self,state):
        self.state=pathlib.Path(state);self.kube=Kube(self.state/'kubeconfig')
        self.out=self.state/'evidence';self.out.mkdir(exist_ok=True)
        self.password=json.loads((self.state/'credentials.json').read_text())['password']
        self.image=json.loads((self.state/'image-values.json').read_text())['harnessImage']
        self.run_id='r'+str(int(time.time()));self.replicas=2
        self.faults={};self.expected_gateway_removals=set();self.monitor_stop=threading.Event();self.monitor_error=None
        self.before_gateways={};self.before_clients={}
    def redact(self,text):return text.replace(self.password,'<redacted>')
    def http(self,url,statement=None,auth=False):
        code='''import urllib.request,urllib.parse,json,sys,os,base64
url,statement,auth=sys.argv[1:];headers={}
if auth=='true':headers['Authorization']='Basic '+base64.b64encode((os.environ['CB_USER']+':'+os.environ['CB_PASS']).encode()).decode()
data=urllib.parse.urlencode({'statement':statement}).encode() if statement else None
req=urllib.request.Request(url,data=data,headers=headers)
try:
 with urllib.request.urlopen(req,timeout=5) as r: print(json.dumps({'code':r.status,'body':r.read().decode()}))
except urllib.error.HTTPError as e:print(json.dumps({'code':e.code,'body':e.read().decode()}))
except Exception as e:print(json.dumps({'code':0,'error':str(e)}))
'''
        return json.loads(self.kube.exec(code,(url,statement or '',str(auth).lower()),timeout=20))
    def query(self,role,statement,expected=None):
        pods=self.backend_pods(role)
        host=next(p['status']['podIP'] for p in pods_with_service(pods,'query') if p.get('status',{}).get('podIP'))
        response=self.http('http://'+host+':8093/query/service',statement,True)
        if response['code']!=200:raise ValueError('query transport failed: HTTP'+str(response['code']))
        result=json.loads(response['body']);query_success(result,expected);return result
    def backend_pods(self,role):return self.kube.get('pods','cb-'+role,'couchbase_cluster=cb-'+role)['items']
    def backend_host(self,role):
        return next(p['status']['podIP'] for p in self.backend_pods(role) if p.get('status',{}).get('podIP') and p['status'].get('phase')=='Running')
    def pools(self,role):
        r=self.http('http://'+self.backend_host(role)+':8091/pools/default',auth=True)
        if r['code']!=200:raise ValueError('cluster API unavailable')
        return json.loads(r['body'])
    def retry(self,label,seconds,fn):
        deadline=time.monotonic()+seconds;error=None
        while time.monotonic()<deadline:
            try:return fn()
            except (ValueError,RuntimeError,StopIteration) as e:error=e;time.sleep(2)
        raise TimeoutError(label+' timed out: '+str(error))
    def seed(self):
        for role in ('a','b'):
            self.retry('query readiness '+role,120,lambda:self.query(role,'SELECT RAW 1',expected=[1]))
            self.retry('primary index '+role,180,lambda:self.query(role,'CREATE PRIMARY INDEX IF NOT EXISTS ON `lbtest`'))
            self.retry('online index '+role,180,lambda:self.query(role,'SELECT RAW 1 FROM system:indexes WHERE (keyspace_id="lbtest" OR bucket_id="lbtest") AND is_primary=true AND state="online" LIMIT 1',expected=[1]))
            self.retry('marker '+role,180,lambda:self.query(role,'UPSERT INTO `lbtest` (KEY,VALUE) VALUES ("region::marker",{"region":"'+role+'"})'))
            self.retry('marker read '+role,60,lambda:self.query(role,'SELECT RAW COUNT(*) FROM `lbtest` USE KEYS "region::marker" WHERE region="'+role+'"',expected=[1]))
    def assert_topology(self):
        for role,count in [('a',5),('b',1)]:
            nodes=self.pools(role)['nodes']
            if len(nodes)!=count or any(n['status']!='healthy' or n['clusterMembership']!='active' for n in nodes):raise ValueError('backend '+role+' not at complete healthy topology')
            services=sorted(tuple(sorted(n['services'])) for n in nodes)
            expected=sorted([('kv',)]*3+[('index','n1ql')]*2) if role=='a' else [('index','kv','n1ql')]
            if services!=expected:raise ValueError('backend service topology differs from approved plan')
    def observer(self,role):return self.http('http://observer-'+role+':8080/health/couchbase')
    def envoy(self):
        p=subprocess.run(self.kube.prefix+envoy_admin_args('/clusters'),capture_output=True,timeout=20)
        if p.returncode:raise ValueError('Envoy admin unavailable')
        return envoy_admin_body(p.stdout)
    def gateway_pods(self):return self.kube.get('pods','cng-demo','app in (cng-a,cng-b)')
    def assert_no_crash(self):
        pods=self.gateway_pods();assert_gateways(pods,self.expected_gateway_removals)
        if self.before_gateways:assert_gateway_identity(self.before_gateways,gateway_identity(pods),self.expected_gateway_removals)
        if self.monitor_error:raise ValueError(self.monitor_error)
    def wait_baseline(self):
        def baseline():
            for role in ('a','b'):
                r=self.observer(role)
                if r['code']!=200 or json.loads(r['body'])['status']!='UP':raise ValueError('Observer '+role+' not UP')
            text=self.envoy()
            ips=[p['status']['podIP'] for p in self.gateway_pods()['items'] if p['status'].get('podIP')]
            if not ips or any('cng_cluster::'+ip+':18098::health_flags::healthy' not in text for ip in ips):raise ValueError('Envoy gateways not all healthy')
        self.retry('healthy Observer/Envoy baseline',300,baseline)
        report=capacity_report(self.kube.get('nodes'),self.kube.get('pods'))
        (self.out/'capacity.json').write_text(json.dumps(report,indent=2))
    def capture(self,label):
        dest=self.out/label;dest.mkdir(exist_ok=True)
        for ns in ('cb-a','cb-b','cng-demo'):
            for kind in ('pods','events','services'):
                try:(dest/(ns+'-'+kind+'.json')).write_text(json.dumps(self.kube.get(kind,ns),indent=2))
                except Exception as e:(dest/(ns+'-'+kind+'.error')).write_text(str(e))
            try:pods=self.kube.get('pods',ns)['items']
            except Exception as e:
                (dest/(ns+'-logs.error')).write_text(str(e));pods=[]
            for p in pods:
                for previous in (False,True):
                    args=['logs',p['metadata']['name'],'-n',ns,'--all-containers=true','--timestamps=true']
                    if previous:args+=['--previous']
                    log=self.kube.run(*args,check=False)
                    (dest/(p['metadata']['name']+('.previous' if previous else '')+'.log')).write_text(self.redact(log.stdout+log.stderr))
        for role in ('a','b'):
            for kind,fn in [('pools',lambda:self.pools(role)),('observer',lambda:self.observer(role))]:
                try:(dest/(role+'-'+kind+'.json')).write_text(json.dumps(fn(),indent=2))
                except Exception as e:(dest/(role+'-'+kind+'.error')).write_text(str(e))
        try:(dest/'envoy-clusters.txt').write_text(self.envoy())
        except Exception as e:(dest/'envoy.error').write_text(str(e))
    def export_all(self):
        # Binary tar requires a binary subprocess, not text decoding.
        p=subprocess.run(self.kube.prefix+['exec','-n','cng-demo','deployment/cng-demo-tools','--','tar','czf','-','-C','/out','.'],capture_output=True)
        if p.returncode:raise RuntimeError('Could not export persistent workload evidence before teardown')
        (self.out/'workload-output.tar.gz').write_bytes(p.stdout)
    def read_file(self,name):
        return self.kube.exec('import pathlib,sys; print(pathlib.Path("/out",sys.argv[1]).read_text(),end="")',(name,))
    def write_file(self,name,text):
        self.kube.exec('import pathlib,sys,base64; pathlib.Path("/out",sys.argv[1]).write_bytes(base64.b64decode(sys.argv[2]))',(name,base64.b64encode(text.encode()).decode()))
    def monitor(self):
        while not self.monitor_stop.is_set():
            sample={'epoch_ms':time.time_ns()//1000000}
            try:
                pods=self.gateway_pods();sample['gateways']=pods
                assert_gateways(pods,self.expected_gateway_removals);assert_gateway_identity(self.before_gateways,gateway_identity(pods),self.expected_gateway_removals)
            except Exception as e:
                if not self.monitor_stop.is_set():self.monitor_error=str(e);sample['gateway_error']=str(e)
            for role in ('a','b'):
                try:sample['observer_'+role]=self.observer(role)
                except Exception as e:sample['observer_'+role]={'error':str(e)}
            try:sample['envoy']=self.envoy()
            except Exception as e:sample['envoy_error']=str(e)
            try:
                sample['nodes']=self.kube.get('nodes')
                sample['pods']=self.kube.get('pods')
                sample['resource_usage']={}
                for n in sample['nodes']['items']:
                    name=n['metadata']['name']
                    p=self.kube.run('get','--raw','/api/v1/nodes/'+name+'/proxy/stats/summary',check=False,timeout=40)
                    if p.returncode==0:sample['resource_usage'][name]=json.loads(p.stdout)
                if self.monitor_error:self.capture('crash-'+str(sample['epoch_ms']))
            except Exception as e:sample['resource_error']=str(e)
            with (self.out/'health-resource.jsonl').open('a') as f:f.write(self.redact(json.dumps(sample))+'\n')
            self.monitor_stop.wait(5)
    def start_monitor(self):
        self.before_gateways=gateway_identity(self.gateway_pods());self.monitor_stop.clear();self.monitor_error=None
        self.thread=threading.Thread(target=self.monitor,daemon=True);self.thread.start()
    def stop_monitor(self):
        self.monitor_stop.set()
        if hasattr(self,'thread'):self.thread.join(60)
    def fault(self,name):
        self.assert_no_crash();now=time.time_ns()//1000000;self.faults[name]=now
        with (self.out/'fault-events.jsonl').open('a') as f:f.write(json.dumps({'scenario':name,'fault_epoch_ms':now})+'\n')
        self.write_file(name+'.fault-ms',str(now));return now
    def client(self,name,seconds,startup=True,region='a',extra=None,target_ip=None):
        self.kube.run('delete','job','harness-'+name,'-n','cng-demo','--ignore-not-found','--wait=true')
        job=harness_job(name,seconds,self.run_id,self.image,startup,region,extra)
        if target_ip:job['spec']['template']['spec']['hostAliases']=[{'ip':target_ip,'hostnames':['envoy.cng-demo.svc.cluster.local']}]
        self.kube.apply(job)
        deadline=time.monotonic()+300;started=None
        while time.monotonic()<deadline:
            pods=self.kube.get('pods','cng-demo','job-name=harness-'+name)['items']
            if pods:
                pod=pods[0]
                if pod['status']['phase']=='Failed':raise ValueError('workload failed before readiness: '+name)
                if pod['status']['phase']=='Running':
                    if started is None:started=time.monotonic();self.before_clients[name]=pod['metadata']['uid']
                    if time.monotonic()-started>=90:raise TimeoutError('current-run client readiness exceeded90s')
                    try:
                        ready=json.loads(self.read_file(name+'.ready.json'))
                        if ready['run_id']==self.run_id and ready['warmup_required']==startup and ready['ready']==startup and ready.get('measurement_start_epoch_ms'):
                            if startup and ready['observed_region']!=region:raise ValueError('client started in wrong region')
                            return
                    except (RuntimeError,json.JSONDecodeError):pass
            self.assert_no_crash();time.sleep(1)
        raise TimeoutError('workload pod did not start within300s')
    def finish(self,name,negative=False):
        deadline=time.monotonic()+600
        while time.monotonic()<deadline:
            pods=self.kube.get('pods','cng-demo','job-name=harness-'+name)['items']
            if len(pods)!=1 or pods[0]['metadata']['uid']!=self.before_clients[name]:raise ValueError('application pod replaced during scenario')
            p=pods[0];statuses=p['status'].get('containerStatuses',[])
            if any(c['restartCount'] for c in statuses):raise ValueError('application restarted')
            if p['status']['phase'] in ('Succeeded','Failed'):
                code=statuses[0]['state']['terminated']['exitCode'];(self.out/(name+'.exit-code')).write_text(str(code)+'\n')
                for suffix in ('.csv','.startup.csv','.startup.json','.ready.json'):
                    try:(self.out/(name+suffix)).write_text(self.read_file(name+suffix))
                    except RuntimeError:pass
                if code!=0:raise ValueError('workload exit'+str(code)+': '+name)
                self.assert_no_crash();return self.summary(name,negative)
            self.assert_no_crash();time.sleep(2)
        raise TimeoutError('workload completion exceeded600s')
    def summary(self,name,negative=False):
        path=self.out/(name+'.csv');data=evidence.measure(path,self.faults.get(name))
        (self.out/(name+'.summary.json')).write_text(json.dumps(data,indent=2)+'\n')
        if negative:
            if data['ok'] or any(data['operations'][op]['err']==0 for op in ('get','upsert')):raise ValueError('negative workload lacks required real failures')
            for row in csv.DictReader(path.open()):
                if row['op'] in evidence.OPS and int(row['latency_ms'])>(5500 if row['op']=='query' else 2500):raise ValueError('negative request exceeds operation budget')
        elif any(not v['terminal_recovered'] for v in data['operations'].values()):raise ValueError('not every operation reached sustained terminal recovery')
        return data
    def cli(self,role,*args):
        host=self.backend_host(role)
        code='''import os,subprocess,sys
host,*args=sys.argv[1:]
p=subprocess.run(['/opt/couchbase/bin/couchbase-cli',*args,'--cluster','http://'+host+':8091','--username',os.environ['CB_USER'],'--password',os.environ['CB_PASS']],capture_output=True,text=True,timeout=180)
print(p.stdout+p.stderr,end='');sys.exit(p.returncode)
'''
        return self.kube.exec(code,(host,*args),timeout=210)
    def pause(self,role):
        self.kube.run('patch','couchbasecluster','cb-'+role,'-n','cb-'+role,'--type=merge','-p','{"spec":{"paused":true}}')
        # Readback must confirm fencing before a destructive fault.
        c=self.kube.get('couchbasecluster/cb-'+role,'cb-'+role)
        if not c['spec'].get('paused'):raise ValueError('Operator did not pause')
    def data_pods(self,role):
        return pods_with_service(self.backend_pods(role),'data')
    def delete_backends(self,role,pods):
        self.pause(role)
        names=[p['metadata']['name'] for p in pods]
        self.kube.run('delete','pod',*names,'-n','cb-'+role,'--grace-period=0','--force','--wait=true')
    def recover(self,role='a'):
        self.kube.run('patch','couchbasecluster','cb-'+role,'-n','cb-'+role,'--type=merge','-p','{"spec":{"paused":false,"hibernate":false}}')
        self.kube.run('wait','--for=condition=Available','couchbasecluster/cb-'+role,'-n','cb-'+role,'--timeout=900s',timeout=930)
        self.retry('restored healthy topology',300,self.assert_topology)
    def reset(self):
        self.capture('before-reset-'+str(int(time.time())));self.export_all()
        self.kube.run('delete','jobs','-n','cng-demo','-l','demo.couchbase.com/stack=cng-demo','--ignore-not-found','--wait=true')
        # Explicit operator-controlled reset, never automatic crash recovery.
        for role in ('a','b'):
            self.kube.run('patch','couchbasecluster','cb-'+role,'-n','cb-'+role,'--type=merge','-p','{"spec":{"paused":false,"hibernate":false}}')
            self.kube.run('wait','--for=condition=Available','couchbasecluster/cb-'+role,'-n','cb-'+role,'--timeout=900s',timeout=930)
        self.retry('reset topology',300,self.assert_topology)
        for d in ('cng-a','cng-b','observer-a','observer-b','envoy'):
            desired=self.replicas if d.startswith('cng-') else 1
            self.kube.run('scale','deployment/'+d,'-n','cng-demo','--replicas='+str(desired))
        self.wait_baseline();self.assert_no_crash()
    def regions(self,data,wanted):
        if data['regions']!=wanted:raise ValueError('unexpected exact regions: '+str(data['regions']))
    def bound(self,data,maximum):
        if data['zero_success_gap_ms']<0 or data['zero_success_gap_ms']>maximum:raise ValueError('no-success gap exceeds unchanged budget')
    def node_membership(self,pools,pod):
        ip=pod['status']['podIP'];name=pod['metadata']['name']
        found=[n for n in pools['nodes'] if n['hostname'].split(':')[0]==ip or n['hostname'].startswith(name+'.')]
        return found[0]['clusterMembership'] if found else None
    def run_scenario(self,number):
        print('Scenario '+str(number),flush=True)
        if number=='1':
            self.client('s1',30);d=self.finish('s1');self.regions(d,['a'])
            if d['err']:raise ValueError('healthy baseline contains errors')
        elif number in ('2','3','10'):
            self.assert_topology();self.wait_baseline()
            if number=='10':
                if not (self.out/'s2.passed-run-id').exists() or (self.out/'s2.passed-run-id').read_text()!=self.run_id:raise ValueError('bootstrap comparison requires successful same-run scenario2')
            name='s'+number;self.client(name,150 if number=='2' else 180);time.sleep(10)
            data=self.data_pods('a')
            targets=[data[0]] if number=='10' else data[1:2] if number=='2' else data[1:3]
            self.fault(name);self.delete_backends('a',targets)
            d=self.finish(name)
            self.regions(d,['a','b'] if number=='3' else ['a'])
            self.bound(d,120000 if number=='3' else 60000)
            pools=self.pools('a');(self.out/(name+'.pools.json')).write_text(json.dumps(pools,indent=2))
            if number in ('2','10') and self.node_membership(pools,targets[0]) not in ('inactiveFailed',None):raise ValueError('single-node loss not absorbed')
            if number=='3' and any(self.node_membership(pools,p)!='active' for p in targets):raise ValueError('two-node failover unexpectedly absorbed')
            if number=='10':
                baseline=json.loads((self.out/'s2.summary.json').read_text())
                ratio=d['err']/d['samples'];base=baseline['err']/baseline['samples']
                spans=[max(x['error_span_ms'] for x in s['operations'].values()) for s in (baseline,d)]
                if ratio>max(base*3,0.01) or spans[1]>max(spans[0]*3,60000):raise ValueError('bootstrap loss worse than same-run absorbed-node baseline')
            if number!='3':
                self.recover()
                if number=='2':(self.out/'s2.passed-run-id').write_text(self.run_id)
        elif number=='4':
            self.recover();self.wait_baseline();self.client('s4',180);time.sleep(10)
            self.fault('s4');self.delete_backends('a',self.backend_pods('a'))
            primary=[p['metadata']['name'] for p in self.gateway_pods()['items'] if p['metadata']['labels']['app']=='cng-a']
            self.assert_no_crash();self.expected_gateway_removals.update(primary)
            self.kube.run('scale','deployment/cng-a','deployment/observer-a','-n','cng-demo','--replicas=0')
            d=self.finish('s4');self.regions(d,['a','b']);self.bound(d,150000)
        elif number=='5':
            self.fault('s5');self.delete_backends('b',self.backend_pods('b'))
            secondary=[p['metadata']['name'] for p in self.gateway_pods()['items'] if p['metadata']['labels']['app']=='cng-b']
            self.assert_no_crash();self.expected_gateway_removals.update(secondary)
            self.kube.run('scale','deployment/cng-b','deployment/observer-b','-n','cng-demo','--replicas=0')
            self.retry('both Envoy endpoints gone',120,lambda:self.require_no_hosts())
            self.client('s5',30,startup=False);self.finish('s5',True)
        elif number=='6':
            # Planned whole-cluster loss removed these gateways; restore explicitly.
            self.stop_monitor();self.before_gateways={}
            for role in ('a','b'):
                self.kube.run('patch','couchbasecluster','cb-'+role,'-n','cb-'+role,'--type=merge','-p','{"spec":{"paused":false,"hibernate":false}}')
                self.kube.run('wait','--for=condition=Available','couchbasecluster/cb-'+role,'-n','cb-'+role,'--timeout=900s',timeout=930)
            for d in ('cng-a','cng-b','observer-a','observer-b'):
                self.kube.run('scale','deployment/'+d,'-n','cng-demo','--replicas='+(str(self.replicas) if d.startswith('cng-') else '1'))
                self.kube.run('rollout','status','deployment/'+d,'-n','cng-demo','--timeout=300s',timeout=330)
            self.expected_gateway_removals.clear();self.wait_baseline();self.start_monitor()
            self.client('s6',120,extra={'IDLE_AT_SECOND':'15','IDLE_SECONDS':'60'})
            d=self.finish('s6');self.regions(d,['a'])
            rows=list(csv.DictReader((self.out/'s6.csv').open()));idle=next((int(r['epoch_ms']) for r in rows if r['op']=='idle'),None)
            after=[r for r in rows if idle is not None and int(r['epoch_ms'])>idle and r['op']!='idle']
            if not after or any(r['outcome']=='err' for r in after):raise ValueError('idle resume not successful')
        elif number=='7':
            self.assert_topology();self.fault('s7');self.delete_backends('a',self.data_pods('a')[1:3]);time.sleep(90)
            doc='stranded::'+str(time.time_ns());self.query('b','UPSERT INTO `lbtest` (KEY,VALUE) VALUES ("'+doc+'",{"written_in":"b"})')
            self.query('b','SELECT RAW COUNT(*) FROM `lbtest` USE KEYS "'+doc+'"',expected=[1])
            self.client('s7-longlived',240,region='b');time.sleep(10);self.recover();self.wait_baseline();healthy=time.time_ns()//1000000
            self.client('s7-newclient',30);new=self.finish('s7-newclient');old=self.finish('s7-longlived')
            self.regions(new,['a']);self.regions(old,['b'])
            newrows=list(csv.DictReader((self.out/'s7-newclient.csv').open()));oldrows=list(csv.DictReader((self.out/'s7-longlived.csv').open()))
            a=[int(r['epoch_ms'])+int(r['latency_ms']) for r in newrows if r['outcome']=='ok' and r['region']=='a' and r['op'] in ('get','query')]
            b=[int(r['epoch_ms'])+int(r['latency_ms']) for r in oldrows if r['outcome']=='ok' and r['region']=='b' and r['op'] in ('get','query')]
            overlap=[t for t in b if max(healthy,min(a))<=t<=max(a)]
            if not overlap:raise ValueError('no old-b/new-a concurrent exact observations')
            (self.out/'s7.overlap.json').write_text(json.dumps({'old_b_observations':len(overlap),'new_a_observations':len(a),'healthy_epoch_ms':healthy}))
            self.query('a','SELECT RAW COUNT(*) FROM `lbtest` USE KEYS "'+doc+'"',expected=[0])
        elif number=='8':
            self.wait_baseline()
            code='''import ssl,socket,json,sys,base64
ctx=ssl.create_default_context(cadata=base64.b64decode(sys.argv[1]).decode())
try:
 with socket.create_connection(('envoy',18098),timeout=5) as s:
  with ctx.wrap_socket(s,server_hostname='envoy.cng-demo.svc.cluster.local') as tls:print(json.dumps({'verified':True}))
except ssl.SSLCertVerificationError:print(json.dumps({'certificate_error':True}))
except Exception as e:print(json.dumps({'transport_error':str(e)}))
'''
            bad=base64.b64encode((self.state/'certs/bad.crt').read_bytes()).decode()
            require_certificate_rejection(json.loads(self.kube.exec(code,(bad,))))
            good=base64.b64encode((self.state/'certs/ca.crt').read_bytes()).decode()
            if not json.loads(self.kube.exec(code,(good,))).get('verified'):raise ValueError('correct CA did not verify')
            self.client('s8-neg',15,startup=False,extra={'TLS_CA':'/bad/ca.crt','OPS_PER_SEC':'5'});self.finish('s8-neg',True)
            self.client('s8',180);time.sleep(10);self.fault('s8');self.delete_backends('a',self.data_pods('a')[1:3]);d=self.finish('s8');self.regions(d,['a','b']);self.bound(d,120000)
        elif number=='readiness':
            self.recover();self.wait_baseline();before=self.observer('a');cng=self.http('http://cng-a:9091/health')
            if before['code']!=200 or cng['code']!=200:raise ValueError('readiness lacks verified healthy baseline')
            self.fault('readiness');self.delete_backends('a',self.backend_pods('a'));time.sleep(60)
            after=self.observer('a');pods=self.gateway_pods()['items'];readings={}
            for p in pods:
                if p['metadata']['labels']['app']=='cng-a':readings[p['metadata']['name']]=self.http('http://'+p['status']['podIP']+':9091/health')
            if after['code']!=503 or json.loads(after['body'])['status']!='DOWN':raise ValueError('Observer did not detect whole backend outage')
            if any(r['code'] not in (200,503) for r in readings.values()):raise ValueError('CNG readiness probe failed to receive HTTP result')
            (self.out/'readiness.json').write_text(json.dumps({'before_observer':before,'before_cng':cng,'after_observer':after,'after_gateways':readings},indent=2));self.recover()
        elif number=='gateway':self.gateway_scenario()
        else:raise ValueError('unknown scenario; DNS scenario9 remains deferred')
        self.assert_no_crash();self.capture('after-'+number)
    def require_no_hosts(self):
        if '::health_flags::healthy' in self.envoy():raise ValueError('Envoy still has a healthy host')
    def gateway_scenario(self):
        self.wait_baseline();pods=self.gateway_pods()['items']
        a=[p for p in pods if p['metadata']['labels']['app']=='cng-a']
        if len(a)!=2:raise ValueError('gateway availability proof requires2 primary replicas')
        # First verify real operations through every gateway, retaining exact targets.
        targets=[]
        for index,p in enumerate(pods):
            name='direct-gateway-'+str(index);role=p['metadata']['labels']['app'][-1]
            self.client(name,30,region=role,target_ip=p['status']['podIP'])
            d=self.finish(name);self.regions(d,[role])
            if d['err']:raise ValueError('healthy direct gateway probe has errors')
            targets.append({'pod':p['metadata']['name'],'uid':p['metadata']['uid'],'ip':p['status']['podIP'],'workload':name,'direct':True})
        (self.out/'direct-gateway-probes.json').write_text(json.dumps(targets,indent=2))
        before=connection_counts(self.envoy(),[p['status']['podIP'] for p in a])
        for index in range(4):self.client('fleet-'+str(index),60,extra={'OPS_PER_SEC':'5'})
        for index in range(4):self.finish('fleet-'+str(index))
        after=connection_counts(self.envoy(),list(before));delta={ip:after[ip]-before[ip] for ip in before}
        assert_fleet_connections(delta);(self.out/'fleet-connections.json').write_text(json.dumps(delta,indent=2))
        self.client('gateway-loss',120);time.sleep(10);self.fault('gateway-loss')
        victim=sorted(a,key=lambda p:p['metadata']['name'])[0]['metadata']['name']
        for p in a:
            self.kube.run('annotate','pod',p['metadata']['name'],'-n','cng-demo','controller.kubernetes.io/pod-deletion-cost='+('-1000' if p['metadata']['name']==victim else '1000'),'--overwrite')
        self.assert_no_crash();self.expected_gateway_removals.add(victim)
        self.kube.run('scale','deployment/cng-a','-n','cng-demo','--replicas=1')
        d=self.finish('gateway-loss');self.regions(d,['a']);self.bound(d,60000)
        self.stop_monitor();self.kube.run('scale','deployment/cng-a','-n','cng-demo','--replicas=2')
        self.kube.run('rollout','status','deployment/cng-a','-n','cng-demo','--timeout=300s',timeout=330)
        self.expected_gateway_removals.clear();self.wait_baseline();self.start_monitor()
    def validate(self,replicas=2):
        self.replicas=replicas
        profile='single' if replicas==1 else 'fleet'
        self.out=self.state/'evidence'/(self.run_id+'-'+profile);self.out.mkdir(parents=True)
        self.write_file('run-id',self.run_id)
        (self.out/'commit.txt').write_text(subprocess.check_output(['git','-C',ROOT,'rev-parse','HEAD'],text=True))
        for role in ('a','b'):
            self.kube.run('scale','deployment/cng-'+role,'-n','cng-demo','--replicas='+str(replicas))
            self.kube.run('rollout','status','deployment/cng-'+role,'-n','cng-demo','--timeout=300s',timeout=330)
        self.wait_baseline();self.assert_topology();self.start_monitor()
        code=1
        try:
            for number in ('1','2','3','4','5','6','7','10','8','readiness'):
                self.run_scenario(number)
            if replicas==2:self.run_scenario('gateway')
            self.assert_no_crash();code=0
        finally:
            self.finalize(code)
        print('ALL AWS SCENARIOS PASSED: '+profile,flush=True)
    def scenario(self,number):
        self.out=self.state/'evidence'/(self.run_id+'-scenario-'+number);self.out.mkdir(parents=True)
        self.wait_baseline();self.assert_topology();self.start_monitor();code=1
        try:
            self.run_scenario(number);code=0
        finally:
            self.finalize(code)

    def finalize(self,code):
        errors=[];self.stop_monitor()
        try:self.capture('final')
        except Exception as e:errors.append(str(e))
        # Preserve Pod/log state first, then stop only this run's writers.
        try:self.kube.run('delete','jobs','-n','cng-demo','-l','demo.couchbase.com/run='+self.run_id,'--ignore-not-found','--wait=true')
        except Exception as e:errors.append(str(e))
        for name in self.before_clients:
            for suffix in ('.csv','.startup.csv','.startup.json','.ready.json'):
                try:(self.out/(name+suffix)).write_text(self.read_file(name+suffix))
                except Exception:pass
            if code and (self.out/(name+'.csv')).exists():
                try:(self.out/(name+'.partial.summary.json')).write_text(json.dumps(evidence.measure(self.out/(name+'.csv'),self.faults.get(name)),indent=2))
                except ValueError as e:(self.out/(name+'.partial.error')).write_text(str(e))
        try:self.export_all()
        except Exception as e:errors.append(str(e))
        (self.out/'diagnostic-errors.json').write_text(json.dumps(errors))
        final_code=1 if errors else code
        (self.out/'driver.exit-code').write_text(str(final_code)+'\n')
        if errors and code==0:raise ValueError('scenario assertions passed but required evidence capture failed')
