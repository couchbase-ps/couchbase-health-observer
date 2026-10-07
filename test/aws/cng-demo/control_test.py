#!/usr/bin/env python3
import importlib.util,json,pathlib,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[3]
p=ROOT/'deploy/aws/cng-demo/scripts/control.py'
spec=importlib.util.spec_from_file_location('control',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class ControlContracts(unittest.TestCase):
    def test_capacity_collection_includes_all_namespaces(self):
        kube=m.Kube('/tmp/test-kubeconfig');calls=[]
        def call(*args):
            calls.append(args)
            return type('Result',(),{'stdout':'{"items":[]}'})()
        kube.run=call;kube.get('pods');kube.get('nodes')
        self.assertIn('-A',calls[0]);self.assertNotIn('-A',calls[1])
    def test_owner_prevents_cross_account_and_stack(self):
        owner={'account':'111111111111','name':'cng-demo','region':'eu-west-1','profile':'sandbox'}
        m.assert_owner(owner,dict(owner))
        for key in ('account','name','region'):
            bad=dict(owner);bad[key]='different'
            with self.assertRaises(ValueError):m.assert_owner(owner,bad)
    def test_client_cannot_restart_or_move_connection_string(self):
        job=m.harness_job('s2',150,'run-1','example.com/harness:pin')
        self.assertEqual(job['spec']['backoffLimit'],0)
        pod=job['spec']['template']['spec'];self.assertEqual(pod['restartPolicy'],'Never')
        env={e['name']:e for e in pod['containers'][0]['env']}
        self.assertEqual(env['CB_CONN']['value'],'couchbase2://envoy.cng-demo.svc.cluster.local')
        self.assertEqual(env['RUN_ID']['value'],'run-1')
        self.assertIn('podAffinity',pod['affinity'])
    def test_any_gateway_restart_fails_even_with_other_healthy_replica(self):
        pods={'items':[{'metadata':{'name':'cng-a-1','uid':'one','labels':{'app':'cng-a'}},'status':{'containerStatuses':[{'name':'cng','restartCount':1,'state':{'running':{}},'lastState':{'terminated':{'reason':'Error','exitCode':2}}}]}},{'metadata':{'name':'cng-a-2','uid':'two','labels':{'app':'cng-a'}},'status':{'containerStatuses':[{'name':'cng','restartCount':0,'state':{'running':{}}}]}}]}
        with self.assertRaises(ValueError):m.assert_gateways(pods)
    def test_planned_termination_is_scoped_to_explicit_victim(self):
        pods={'items':[{'metadata':{'name':'victim'},'status':{'containerStatuses':[{'restartCount':0,'state':{'terminated':{'exitCode':143}}}]}}]}
        m.assert_gateways(pods,{'victim'})
        with self.assertRaises(ValueError):m.assert_gateways(pods,set())
    def test_replacement_not_silently_accepted(self):
        with self.assertRaises(ValueError):m.assert_gateway_identity({'cng-a-1':'old'},{'cng-a-1':'new'},set())
        m.assert_gateway_identity({'cng-a-1':'old'},{}, {'cng-a-1'})
    def test_gateway_fleet_requires_connections_to_every_ready_endpoint(self):
        with self.assertRaises(ValueError):m.assert_fleet_connections({'10.0.1.1':2,'10.0.1.2':0})
        m.assert_fleet_connections({'10.0.1.1':2,'10.0.1.2':1})
if __name__=='__main__':unittest.main()
