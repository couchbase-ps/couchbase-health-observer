#!/usr/bin/env python3
"""Create, inspect, park and remove only this Terraform-owned AWS demo."""
import argparse,base64,hashlib,ipaddress,json,os,pathlib,secrets,shutil,subprocess,sys,time,urllib.request
from control import Kube,assert_owner
ROOT=pathlib.Path(__file__).resolve().parents[4]
INFRA=ROOT/'deploy/aws/cng-demo/infra'
CHART=ROOT/'deploy/aws/cng-demo/chart'
TF=os.environ.get('TERRAFORM','terraform')

def run(args, log=None, input=None, timeout=None, check=True):
    p=subprocess.run([str(x) for x in args],input=input,text=True,capture_output=True,timeout=timeout)
    if log: pathlib.Path(log).write_text(p.stdout+p.stderr)
    if check and p.returncode: raise RuntimeError(str(args[0])+' failed; '+(str(log) if log else p.stderr.strip()))
    return p

class Demo:
    def __init__(self,args):
        self.args=args
        self.state=ROOT/'.demo-aws'/args.name
        self.state.mkdir(parents=True,exist_ok=True);self.state.chmod(0o700)
        self.owner_path=self.state/'owner.json';self.kubeconfig=self.state/'kubeconfig'
        self.tfvars=self.state/'infra.auto.tfvars.json'
        os.environ['AWS_PROFILE']=args.profile;os.environ['AWS_REGION']=args.region
        os.environ['TF_DATA_DIR']=str(self.state/'tf-data')
        self.account=self.aws('sts','get-caller-identity')['Account']
        self.identity={'account':self.account,'name':args.name,'region':args.region,'profile':args.profile}
        self.owner=json.loads(self.owner_path.read_text()) if self.owner_path.exists() else None
        if self.owner:assert_owner(self.owner,self.identity)
        self.kube=Kube(self.kubeconfig)
    def aws(self,*args):
        return json.loads(run(['aws','--profile',self.args.profile,'--region',self.args.region,*args,'--output','json']).stdout or '{}')
    def tf(self,*args,log=None):
        return run([TF,f'-chdir={INFRA}',*args],log=log,timeout=3600)
    def init(self):
        self.tf('init','-reconfigure',f'-backend-config=path={self.state}/terraform.tfstate',log=self.state/'init.log')
    def save_owner(self):self.owner_path.write_text(json.dumps(self.owner,indent=2)+'\n')
    def outputs(self):
        return {k:v['value'] for k,v in json.loads(self.tf('output','-json').stdout).items()}
    def connect(self):
        if not self.owner:raise ValueError('No owned deployment; run --up first')
        actual=self.aws('eks','describe-cluster','--name',self.args.name)['cluster']
        if actual['tags'].get('Project')!='cng-demo' or actual['tags'].get('DemoId')!=self.args.name:
            raise ValueError('EKS ownership tags do not match')
        if self.owner.get('cluster_arn') and actual['arn']!=self.owner['cluster_arn']:
            raise ValueError('EKS ARN differs from owned deployment')
        run(['aws','eks','update-kubeconfig','--name',self.args.name,'--region',self.args.region,'--profile',self.args.profile,'--kubeconfig',self.kubeconfig,'--alias',self.args.name],log=self.state/'kubeconfig.log')
    def provision(self, infra_only=False):
        if not self.owner:
            check=run(['aws','eks','describe-cluster','--name',self.args.name,'--profile',self.args.profile,'--region',self.args.region],check=False)
            if check.returncode==0:raise ValueError('Existing cluster has no local ownership record; refusing adoption')
            if 'ResourceNotFoundException' not in check.stderr:raise RuntimeError('Cannot establish that demo name is unused')
            self.owner=dict(self.identity,source_commit=run(['git','-C',ROOT,'rev-parse','HEAD']).stdout.strip(),created_at=int(time.time()))
            self.save_owner()
        address=urllib.request.urlopen('https://checkip.amazonaws.com',timeout=10).read().decode().strip()
        ipaddress.IPv4Address(address)
        self.tfvars.write_text(json.dumps({'name':self.args.name,'region':self.args.region,'admin_cidrs':[address+'/32']}))
        self.init()
        self.tf('plan',f'-var-file={self.tfvars}',f'-out={self.state}/apply.tfplan',log=self.state/'plan.log')
        plan=json.loads(self.tf('show','-json',str(self.state/'apply.tfplan')).stdout)
        changes=[c for c in plan.get('resource_changes',[]) if c['change']['actions']!=['no-op']]
        (self.state/'plan-summary.json').write_text(json.dumps([{'address':c['address'],'actions':c['change']['actions']} for c in changes],indent=2))
        if any('delete' in c['change']['actions'] for c in changes):raise ValueError('Up plan would delete/replace infrastructure; explicit reset or destroy required')
        print('Applying owned EKS demo: primary2 / secondary1 / apps2, m7g.large',flush=True)
        self.tf('apply','-input=false',str(self.state/'apply.tfplan'),log=self.state/'apply.log')
        outputs=self.outputs();self.owner.update(cluster_arn=outputs['cluster_arn'],vpc_id=outputs['vpc_id']);self.save_owner()
        self.connect();self.resize(True)
        if infra_only:
            print("Infrastructure ready; workload install not yet requested.", flush=True)
            return
        self.build_images(outputs)
        self.install()
    def resize(self,resume):
        expected={'primary':2,'secondary':1,'apps':2}
        for name in self.aws('eks','list-nodegroups','--cluster-name',self.args.name)['nodegroups']:
            g=self.aws('eks','describe-nodegroup','--cluster-name',self.args.name,'--nodegroup-name',name)['nodegroup']
            pool=g['labels'].get('demo.couchbase.com/pool')
            if pool not in expected:raise ValueError('Unexpected node group; refusing resize')
            desired=expected[pool] if resume else 0
            if g['scalingConfig']['desiredSize']!=desired:
                result=self.aws('eks','update-nodegroup-config','--cluster-name',self.args.name,'--nodegroup-name',name,'--scaling-config',json.dumps({'minSize':0,'maxSize':expected[pool],'desiredSize':desired}))
                update=result['update']['id'];deadline=time.monotonic()+900
                while time.monotonic()<deadline:
                    status=self.aws('eks','describe-update','--name',self.args.name,'--nodegroup-name',name,'--update-id',update)['update']['status']
                    if status=='Successful':break
                    if status=='Failed':raise RuntimeError('Node group resize failed')
                    time.sleep(10)
                else:raise TimeoutError('Node group resize exceeded15min')
        if resume:
            deadline=time.monotonic()+600
            while time.monotonic()<deadline:
                nodes=self.kube.get('nodes')['items']
                counts={p:sum(n['metadata']['labels'].get('demo.couchbase.com/pool')==p and any(c['type']=='Ready' and c['status']=='True' for c in n['status']['conditions']) for n in nodes) for p in expected}
                if counts==expected:break
                time.sleep(5)
            else:raise TimeoutError('Approved worker pools did not become Ready')
            self.kube.run('get','nodes','-o','json');self.kube.run('rollout','status','deployment/ebs-csi-controller','-n','kube-system','--timeout=300s',timeout=330)
    def build_images(self,outputs):
        tag=run(['git','-C',ROOT,'rev-parse','HEAD']).stdout.strip()
        registry=outputs['observer_repository'].split('/')[0]
        password=run(['aws','ecr','get-login-password','--profile',self.args.profile,'--region',self.args.region]).stdout
        run(['docker','login','--username','AWS','--password-stdin',registry],input=password,log=self.state/'registry-login.log')
        values={'envoy':{'enabled':False},'cngReplicas':2}
        for kind,context in [('observer',ROOT),('harness',ROOT/'harness')]:
            repo=outputs[kind+'_repository']; image=repo+':'+tag
            exists=run(['aws','ecr','describe-images','--repository-name',self.args.name+'/'+kind,'--image-ids','imageTag='+tag,'--profile',self.args.profile,'--region',self.args.region,'--output','json'],check=False)
            if exists.returncode:
                run(['docker','build','--platform','linux/arm64','-t',image,context],log=self.state/(kind+'-build.log'),timeout=1800)
                run(['docker','push',image],log=self.state/(kind+'-push.log'),timeout=900)
            info=self.aws('ecr','describe-images','--repository-name',self.args.name+'/'+kind,'--image-ids','imageTag='+tag)
            values[kind+'Image']=repo+'@'+info['imageDetails'][0]['imageDigest']
        (self.state/'image-values.json').write_text(json.dumps(values))
    def secrets(self):
        path=self.state/'credentials.json'
        if not path.exists():path.write_text(json.dumps({'username':'Administrator','password':secrets.token_urlsafe(24)}));path.chmod(0o600)
        credentials=json.loads(path.read_text())
        certs=self.state/'certs';certs.mkdir(exist_ok=True)
        if not (certs/'server.crt').exists():
            san='DNS:envoy,DNS:envoy.cng-demo,DNS:envoy.cng-demo.svc,DNS:envoy.cng-demo.svc.cluster.local'
            run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',certs/'ca.key','-out',certs/'ca.crt','-days','30','-subj','/CN=cng-demo-ca'])
            run(['openssl','req','-newkey','rsa:2048','-nodes','-keyout',certs/'server.key','-out',certs/'server.csr','-subj','/CN=envoy.cng-demo.svc.cluster.local','-addext','subjectAltName='+san])
            (certs/'extensions').write_text('subjectAltName='+san+'\n')
            run(['openssl','x509','-req','-in',certs/'server.csr','-CA',certs/'ca.crt','-CAkey',certs/'ca.key','-CAcreateserial','-out',certs/'server.crt','-days','30','-extfile',certs/'extensions'])
            run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',certs/'bad.key','-out',certs/'bad.crt','-days','30','-subj','/CN=not-demo-ca'])
            for p in certs.glob('*.key'):p.chmod(0o600)
        for ns in ('cb-a','cb-b','cng-demo'):
            self.kube.apply({'apiVersion':'v1','kind':'Namespace','metadata':{'name':ns,'labels':{'demo.couchbase.com/stack':'cng-demo'}}})
            self.kube.apply({'apiVersion':'v1','kind':'Secret','metadata':{'name':'cb-admin','namespace':ns},'type':'Opaque','stringData':credentials})
        for name,files in [('cng-tls',{'ca.crt':'ca.crt','server.crt':'server.crt','server.key':'server.key'}),('bad-ca',{'ca.crt':'bad.crt'})]:
            self.kube.apply({'apiVersion':'v1','kind':'Secret','metadata':{'name':name,'namespace':'cng-demo'},'type':'Opaque','data':{key:base64.b64encode((certs/file).read_bytes()).decode() for key,file in files.items()}})
    def helm(self,*args,log=None):
        return run(['helm','--kubeconfig',self.kubeconfig,*args],log=log,timeout=1800)
    def install(self):
        self.secrets()
        operator={'install':{'couchbaseOperator':True,'admissionController':True,'couchbaseCluster':False,'syncGateway':False},
                  'couchbaseOperator':{'scope':'Role','nodeSelector':{'demo.couchbase.com/pool':'apps'},'resources':{'requests':{'cpu':'100m','memory':'128Mi'},'limits':{'memory':'512Mi'}}},
                  'admissionController':{'nodeSelector':{'demo.couchbase.com/pool':'apps'},'resources':{'requests':{'cpu':'50m','memory':'64Mi'},'limits':{'memory':'256Mi'}}}}
        op_values=self.state/'operator-values.json';op_values.write_text(json.dumps(operator))
        self.helm('repo','add','couchbase-demo','https://couchbase-partners.github.io/helm-charts/',log=self.state/'helm-repo.log')
        self.helm('repo','update','couchbase-demo',log=self.state/'helm-repo-update.log')
        for ns in ('cb-a','cb-b'):
            self.helm('upgrade','--install','operator-'+ns,'couchbase-demo/couchbase-operator','--version','2.93.0','--namespace',ns,'--values',op_values,'--wait','--timeout','10m',log=self.state/(ns+'-operator.log'))
        self.helm('upgrade','--install','cng-demo',CHART,'--namespace','cng-demo','--values',self.state/'image-values.json','--set','envoy.enabled=false',log=self.state/'workloads-bootstrap.log')
        for ns in ('cb-a','cb-b'):
            self.kube.run('patch','couchbasecluster',ns,'-n',ns,'--type=merge','-p',json.dumps({'spec':{'paused':False,'hibernate':False}}))
            self.kube.run('wait','--for=condition=Available','couchbasecluster/'+ns,'-n',ns,'--timeout=1200s',timeout=1230)
        self.kube.run('rollout','status','deployment/cng-demo-tools','-n','cng-demo','--timeout=300s',timeout=330)
        from runner import Runner
        r=Runner(self.state);r.seed();r.assert_topology()
        services=self.kube.get('services','cng-demo')['items']
        addresses={s['metadata']['name'][-1]:s['spec']['clusterIP'] for s in services if s['metadata']['name'].startswith('observer-')}
        values=json.loads((self.state/'image-values.json').read_text());values['observerAddresses']=addresses;values['envoy']={'enabled':True}
        (self.state/'runtime-values.json').write_text(json.dumps(values))
        self.helm('upgrade','cng-demo',CHART,'--namespace','cng-demo','--values',self.state/'runtime-values.json',log=self.state/'workloads.log')
        for d in ('cng-a','cng-b','observer-a','observer-b','envoy'):
            self.kube.run('rollout','status','deployment/'+d,'-n','cng-demo','--timeout=300s',timeout=330)
        r.wait_baseline();r.assert_no_crash()
        self.kube.apply({'apiVersion':'v1','kind':'ConfigMap','metadata':{'name':'cng-demo-owner','namespace':'cng-demo'},'data':{k:str(v) for k,v in self.identity.items()}})
        self.owner['ready_at']=int(time.time());self.save_owner()
        print('Demo baseline ready. Use --validate or --scenario.',flush=True)
    def park(self):
        self.connect()
        from runner import Runner
        r=Runner(self.state);r.capture('before-park')
        self.kube.run('delete','jobs','-n','cng-demo','-l','demo.couchbase.com/stack=cng-demo','--ignore-not-found')
        for ns in ('cb-a','cb-b'):
            self.kube.run('patch','couchbasecluster',ns,'-n',ns,'--type=merge','-p',json.dumps({'spec':{'paused':False,'hibernate':True}}))
        deadline=time.monotonic()+300
        while time.monotonic()<deadline:
            if all(not self.kube.get('pods',ns,'couchbase_cluster='+ns)['items'] for ns in ('cb-a','cb-b')):break
            time.sleep(5)
        else:raise TimeoutError('Backend hibernation did not finish; workers left running')
        self.resize(False);print('Workers parked. EKS, NAT and storage still bill.',flush=True)
    def destroy(self):
        if not self.owner:raise ValueError('No owned Terraform state; refusing destroy')
        self.init()
        try:self.connect()
        except RuntimeError as error:
            if 'ResourceNotFoundException' not in str(error):raise
        else:
            from runner import Runner
            r=Runner(self.state);r.capture('before-destroy');r.export_all()
            self.kube.run('delete','jobs','-n','cng-demo','-l','demo.couchbase.com/stack=cng-demo','--ignore-not-found')
            volumes=[pv['spec']['csi']['volumeHandle'] for pv in self.kube.get('pv')['items'] if pv['spec'].get('claimRef',{}).get('namespace') in ('cb-a','cb-b','cng-demo') and 'csi' in pv['spec']]
            (self.state/'owned-volumes.json').write_text(json.dumps(volumes))
            for ns in ('cb-a','cb-b'):
                self.kube.run('delete','couchbasecluster',ns,'-n',ns,'--ignore-not-found','--wait=true','--timeout=300s',timeout=330)
            self.helm('uninstall','cng-demo','-n','cng-demo','--wait','--timeout','5m',log=self.state/'helm-uninstall.log')
            for ns in ('cb-a','cb-b'):
                self.kube.run('delete','pvc','--all','-n',ns,'--wait=true','--timeout=180s',timeout=210)
                self.helm('uninstall','operator-'+ns,'-n',ns,'--wait','--timeout','5m',log=self.state/(ns+'-uninstall.log'))
            for ns in ('cb-a','cb-b','cng-demo'):self.kube.run('delete','namespace',ns,'--ignore-not-found','--wait=true','--timeout=180s',timeout=210)
            deadline=time.monotonic()+300
            while time.monotonic()<deadline:
                remaining=[]
                for volume in volumes:
                    p=run(['aws','ec2','describe-volumes','--volume-ids',volume,'--profile',self.args.profile,'--region',self.args.region,'--output','json'],check=False)
                    if p.returncode and 'InvalidVolume.NotFound' in p.stderr:continue
                    if p.returncode:raise RuntimeError('Could not verify owned PVC volume deletion')
                    remaining.append(volume)
                if not remaining:break
                time.sleep(5)
            else:raise RuntimeError('Owned PVC volumes remain; infrastructure retained for cleanup')
        self.tf('plan','-destroy',f'-var-file={self.tfvars}',f'-out={self.state}/destroy.tfplan',log=self.state/'destroy-plan.log')
        self.tf('apply','-input=false',str(self.state/'destroy.tfplan'),log=self.state/'destroy.log')
        resources=self.aws('resourcegroupstaggingapi','get-resources','--tag-filters',json.dumps([{'Key':'Project','Values':['cng-demo']},{'Key':'DemoId','Values':[self.args.name]}]))
        if resources.get('ResourceTagMappingList'):raise RuntimeError('Tagged demo resources remain after destroy')
        self.owner['destroyed_at']=int(time.time());self.save_owner();print('Demo AWS resources destroyed; local evidence retained.',flush=True)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    actions=p.add_mutually_exclusive_group(required=True)
    for action in ('up','infra-only','validate','reset','park','destroy','status'):actions.add_argument('--'+action,action='store_true')
    actions.add_argument('--scenario')
    p.add_argument('--profile',default=os.environ.get('AWS_PROFILE'))
    p.add_argument('--region',default='eu-west-1');p.add_argument('--name',default='cng-demo')
    p.add_argument('--gateway-replicas',type=int,choices=(1,2),default=2)
    args=p.parse_args()
    if not args.profile:p.error('--profile or AWS_PROFILE required')
    if not __import__('re').fullmatch(r'cng-demo(?:-[a-z0-9-]+)?',args.name):p.error('invalid demo name')
    d=Demo(args)
    if args.up or args.infra_only:d.provision(args.infra_only)
    elif args.destroy:d.destroy()
    elif args.park:d.park()
    elif args.status:
        d.connect();print(d.kube.run('get','pods','-A','-o','wide').stdout)
    else:
        d.connect()
        from runner import Runner
        r=Runner(d.state)
        if args.reset:r.reset()
        elif args.validate:r.validate(args.gateway_replicas)
        else:r.scenario(args.scenario)
if __name__=='__main__':
    try:main()
    except Exception as error:print('FAIL:',error,file=sys.stderr);sys.exit(1)
