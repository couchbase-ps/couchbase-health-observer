#!/usr/bin/env python3
"""Exercise lifecycle control flow with all cloud/process methods replaced by fakes."""
import pathlib,sys,tempfile,types,unittest,contextlib,io
ROOT=pathlib.Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'deploy/aws/cng-demo/scripts'))
from lifecycle import Demo
class Lifecycle(unittest.TestCase):
    def test_partial_destroy_does_not_require_uninstalled_workloads(self):
        with tempfile.TemporaryDirectory() as folder:
            d=Demo.__new__(Demo);d.state=pathlib.Path(folder);d.owner={'account':'111111111111','name':'cng-demo','region':'eu-west-1'}
            d.owner_path=d.state/'owner.json';d.tfvars=d.state/'vars.json';d.args=types.SimpleNamespace(name='cng-demo',profile='sandbox',region='eu-west-1')
            calls=[];d.init=lambda:None;d.connect=lambda:None
            d.kube=types.SimpleNamespace(get=lambda kind:{'items':[]})
            d.helm=lambda *args,**kwargs:types.SimpleNamespace(stdout='[]')
            d.tf=lambda *args,**kwargs:calls.append(args)
            d.aws=lambda *args:{'ResourceTagMappingList':[]}
            with contextlib.redirect_stdout(io.StringIO()):d.destroy()
            self.assertIn('destroyed_at',d.owner)
            self.assertTrue(any(c[0]=='plan' and '-destroy' in c for c in calls))
            self.assertTrue(any(c[0]=='apply' for c in calls))
    def test_quota_failure_precedes_every_terraform_mutation(self):
        d=Demo.__new__(Demo);d.owner={'name':'cng-demo'};d.args=types.SimpleNamespace(name='cng-demo');calls=[]
        def aws(*args):
            if args[:2]==('ec2','describe-addresses'):return {'Addresses':[{}]*5}
            if args[0]=='service-quotas':return {'Quota':{'Value':5}}
            return {'NatGateways':[]}
        d.aws=aws;d.tf=lambda *args,**kwargs:calls.append(args)
        with self.assertRaisesRegex(ValueError,'Elastic IP quota exhausted'):d.provision()
        self.assertEqual(calls,[])
if __name__=='__main__':unittest.main()
