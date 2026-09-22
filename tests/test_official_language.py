"""Actual official Luau 0.739 integration tests; no Lua 5.x emulation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from native_luau import check
from modern_luau import run, inspect_source

ROOT=Path(__file__).resolve().parents[1]

class OfficialLanguageTests(unittest.TestCase):
    def setUp(self):
        for name in ('luau','luau-compile','luau-ast'):
            self.assertIsNotNone(shutil.which(name), 'Required native tool missing: '+name)
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)

    def trace(self,source):
        path=self.root/'test.luau';path.write_text(source)
        report=check(path,'trace',self.root,timeout=3)
        self.assertTrue(report.get('ok'),report)
        self.assertEqual(report['runtimeVersion'],'0.739')
        return report

    def test_modern_syntax_native_execution(self):
        report=self.trace('type Row={value:number}; local r:Row={value=0}; r.value+=3; local sum=0; for _,n in {1,2,3} do if n==2 then continue end sum+=n end; print(`native {r.value} sum {sum}`); return if sum==4 then "ok" else "bad"')
        self.assertEqual(bytes.fromhex(report['events'][0]['arguments'][0]['hex']),b'native 3 sum 4')
        self.assertEqual(bytes.fromhex(report['returns'][0]['hex']),b'ok')

    def test_compound_lhs_evaluated_once(self):
        report=self.trace('local calls=0; local t={10}; local function key() calls+=1; return 1 end; t[key()]+=5; return calls,t[1]')
        self.assertEqual([float(v['text']) for v in report['returns']],[1,15])

    def test_nil_values_preserve_arity(self):
        report=self.trace('print("a",nil,false,3); return nil,4,nil')
        self.assertEqual(len(report['events'][0]['arguments']),4)
        self.assertEqual(len(report['returns']),3)
        self.assertEqual(report['returns'][2]['type'],'nil')

    def test_mutable_capture(self):
        report=self.trace('local n=0; local function step() n+=1; return n end; return step(),step(),step()')
        self.assertEqual([float(v['text']) for v in report['returns']],[1,2,3])

    def test_short_circuit_preserves_effects(self):
        report=self.trace('local n=0; local function f() n+=1; return false end; local a=false and f(); local b=true or f(); local c=f() or f(); return n')
        self.assertEqual(float(report['returns'][0]['text']),2)

    def test_compile_only_never_runs_infinite_loop(self):
        path=self.root/'loop.luau';path.write_text('while true do end')
        self.assertTrue(check(path,'compile',self.root,timeout=3)['ok'])

    def test_invalid_native_syntax(self):
        path=self.root/'bad.luau';path.write_text('local = if ???')
        self.assertFalse(check(path,'compile',self.root,timeout=3)['ok'])

    def test_ast_includes_uncalled_function(self):
        path=self.root/'ast.luau';path.write_text('type T={x:number}; local function neverCalled(a:number):number return a+42 end; local x:T={x=1}')
        info=inspect_source(path,self.root)
        self.assertTrue(info['complete'],info)
        self.assertIn('neverCalled',[f['name'] for f in info['functions']])
        self.assertFalse(info['executed'])

    def test_strict_fallback_retains_complete_modern_source(self):
        source='type N=number; local n:N=0; while true do n+=1 end'
        path=self.root/'source.luau';path.write_text(source)
        with patch.dict(os.environ,{'LUAUVMP_STRICT_CAPTURE':'1'}):
            report=run(path,self.root/'result',20)
        self.assertTrue(report['decompiler']['compile_checked'])
        self.assertFalse(report['final_payload_executed'])
        self.assertFalse(report['complete_devirtualization'])
        self.assertEqual((self.root/'result/program.source.luau').read_text(),source)
        self.assertFalse((self.root/'result/native-observation.json').exists())

    def test_actual_router_accepts_type_annotations(self):
        path=self.root/'source.luau';path.write_text('type N=number; local n:N=3; return n')
        result=subprocess.run([sys.executable,str(ROOT/'engine_runner.py'),str(path),str(self.root/'routed'),'20'],capture_output=True,timeout=25,env={**os.environ,'LUAUVMP_STRICT_CAPTURE':'1'})
        self.assertEqual(result.returncode,0,result.stdout.decode()+result.stderr.decode())
        report=json.loads((self.root/'routed/pipeline.json').read_text())
        self.assertEqual(report['family'],'luau-source')
        self.assertEqual(report['adapter'],'native-recovery-2.0.0')
        self.assertFalse(report['final_payload_executed'])

    def test_fallback_observation_remains_distinct(self):
        path=self.root/'source.luau';path.write_text('local value:number=7; print(`value {value}`)')
        with patch.dict(os.environ,{'LUAUVMP_STRICT_CAPTURE':'0'}):
            report=run(path,self.root/'result',20)
        self.assertTrue(report['observation_completed'])
        self.assertEqual(report['primary'],'program.source.luau')
        self.assertTrue(report['partial'])
        self.assertFalse(report['complete_devirtualization'])

if __name__=='__main__':unittest.main()
