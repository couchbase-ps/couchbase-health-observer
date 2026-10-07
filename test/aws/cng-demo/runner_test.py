#!/usr/bin/env python3
import importlib.util,pathlib,sys,unittest
ROOT=pathlib.Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'deploy/aws/cng-demo/scripts'))
import runner
class RunnerContracts(unittest.TestCase):
    def test_query_transport_and_sql_errors_cannot_pass(self):
        for response in [{'status':'errors','results':[1],'errors':[{'code':5000}]},{'results':[1]},{'status':'success','results':[0]}]:
            with self.assertRaises(ValueError):runner.query_success(response,expected=[1])
        runner.query_success({'status':'success','results':[1]},expected=[1])
    def test_capacity_uses_allocatable_and_includes_system_pods(self):
        nodes={'items':[{'metadata':{'name':'node'},'status':{'allocatable':{'cpu':'1900m','memory':'7Gi'}}}]}
        pods={'items':[{'metadata':{'namespace':'kube-system'},'spec':{'nodeName':'node','containers':[{'resources':{'requests':{'cpu':'1500m','memory':'6Gi'}}}]}},{'metadata':{'namespace':'cng-demo'},'spec':{'nodeName':'node','containers':[{'resources':{'requests':{'cpu':'500m','memory':'2Gi'}}}]}}]}
        with self.assertRaises(ValueError):runner.capacity_report(nodes,pods)
    def test_wrong_ca_requires_certificate_error_not_transport_failure(self):
        with self.assertRaises(ValueError):runner.require_certificate_rejection({'transport_error':'connection refused'})
        runner.require_certificate_rejection({'certificate_error':True})
    def test_endpoint_metrics_are_attributed_to_each_gateway(self):
        text='cng_cluster::10.0.1.1:18098::cx_total::3\ncng_cluster::10.0.1.2:18098::cx_total::0\n'
        self.assertEqual(runner.connection_counts(text,['10.0.1.1','10.0.1.2']),{'10.0.1.1':3,'10.0.1.2':0})
if __name__=='__main__':unittest.main()
