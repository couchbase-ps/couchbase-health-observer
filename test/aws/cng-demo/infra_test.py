#!/usr/bin/env python3
"""Terraform contracts: validate syntax and approved pool capacity defaults."""
import json,pathlib,subprocess,unittest,os
ROOT=pathlib.Path(__file__).resolve().parents[3]
TF=ROOT/'deploy/aws/cng-demo/infra'
BIN=os.environ.get('TERRAFORM','terraform')
class Infra(unittest.TestCase):
    def test_configuration_validates(self):
        p=subprocess.run([BIN,f'-chdir={TF}','validate','-json'],capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertTrue(json.loads(p.stdout)['valid'])
    def test_approved_defaults(self):
        p=subprocess.run([BIN,f'-chdir={TF}','console'],input='jsonencode(var.node_groups)\n',text=True,capture_output=True,check=True)
        groups=json.loads(json.loads(p.stdout.strip()))
        self.assertEqual(groups,{'primary':2,'secondary':1,'apps':2})
        p=subprocess.run([BIN,f'-chdir={TF}','console'],input='var.instance_type\n',text=True,capture_output=True,check=True)
        self.assertEqual(json.loads(p.stdout),'m7g.large')
if __name__=='__main__':unittest.main()
