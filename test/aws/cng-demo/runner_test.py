#!/usr/bin/env python3
import importlib.util,pathlib,sys,unittest
ROOT=pathlib.Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'deploy/aws/cng-demo/scripts'))
import runner
class RunnerContracts(unittest.TestCase):
    def test_query_transport_and_sql_errors_cannot_pass(self):
        for response in [{'status':'errors','results':[1],'errors':[{'code':5000}]},{'results':[1]},{'status':'success','results':[0]},{'status':'success','results':[True]}]:
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
    def test_envoy_admin_is_read_inside_the_envoy_pod(self):
        args=runner.envoy_admin_args('/clusters')
        self.assertEqual(args[:6],['exec','-n','cng-demo','deployment/envoy','-c','envoy'])
        self.assertEqual(args[-2:],['/clusters','9901'])
    def test_envoy_admin_script_returns_decoded_body_only_for_200(self):
        # Behaves like Envoy admin: rejects HTTP/1.0, answers HTTP/1.1 chunked.
        import http.server,subprocess,threading
        class H(http.server.BaseHTTPRequestHandler):
            protocol_version='HTTP/1.1'
            def do_GET(self):
                if self.request_version!='HTTP/1.1':self.send_response(426);self.send_header('Content-Length','0');self.end_headers();return
                self.send_response(200 if self.path=='/clusters' else 503);self.send_header('Transfer-Encoding','chunked');self.end_headers()
                for part in (b'cng_cluster::10.0.1.1:18098::health_fl',b'ags::healthy\n'):self.wfile.write(b'%x\r\n%s\r\n'%(len(part),part))
                self.wfile.write(b'0\r\n\r\n')
            def log_message(self,*a):pass
        server=http.server.HTTPServer(('127.0.0.1',0),H);threading.Thread(target=server.serve_forever,daemon=True).start()
        port=str(server.server_port)
        try:
            ok=subprocess.run(['bash','-c',runner.ENVOY_ADMIN_GET,'envoy-admin','/clusters',port],capture_output=True,timeout=10)
            self.assertEqual(ok.returncode,0)
            self.assertEqual(runner.envoy_admin_body(ok.stdout),'cng_cluster::10.0.1.1:18098::health_flags::healthy\n')
            bad=subprocess.run(['bash','-c',runner.ENVOY_ADMIN_GET,'envoy-admin','/ready',port],capture_output=True,timeout=10)
            self.assertNotEqual(bad.returncode,0);self.assertEqual(bad.stdout,b'')
        finally:server.shutdown()
    def test_service_selection_uses_operator_labels(self):
        # Labels as Operator 2.9 sets them on a live EKS install.
        def pod(name,conf,*services):
            labels={'app':'couchbase','couchbase_cluster':'cb-a','couchbase_node':name,'couchbase_node_conf':conf,'couchbase_server':'true'}
            labels.update({'couchbase_service_'+s:'enabled' for s in services})
            return {'metadata':{'name':name,'labels':labels},'status':{'podIP':'10.0.0.'+name[-1]}}
        pods=[pod('cb-a-0001','data','data'),pod('cb-a-0000','data','data'),pod('cb-a-0003','query','index','query')]
        self.assertEqual([p['metadata']['name'] for p in runner.pods_with_service(pods,'data')],['cb-a-0000','cb-a-0001'])
        self.assertEqual([p['metadata']['name'] for p in runner.pods_with_service(pods,'query')],['cb-a-0003'])
        self.assertEqual(runner.pods_with_service([pod('cb-b-0000','all','data','index','query')],'query')[0]['metadata']['name'],'cb-b-0000')
if __name__=='__main__':unittest.main()
