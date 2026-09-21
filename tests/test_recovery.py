import json,os,shutil,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
sys.path.insert(0,str(Path(__file__).resolve().parent))
from lua_tokens import lex,decode_string,SyntaxFailure
from lua_parse import Parser
from lua_eval import Evaluator,Halt
from lua_emit import Emitter
from recovery import prefix_information,replacements,run_local,native,equivalent,snapshot
from fixture_shapes import protected_literal
from native_luau import available

class RecoveryTests(unittest.TestCase):
    def evaluate(self,src,**kwargs):
        e=Evaluator(**kwargs);r=e.run(Parser(src).parse());return e,r
    def test_multiple_different_messages_not_hardcoded(self):
        for text in (b'hello',b'not the expected output',b'other words',b'line1\nline2',b'\x00\xffbinary'):
            e,r=self.evaluate(protected_literal(text))
            self.assertEqual(e.calls[0]['arguments'],(text,));self.assertEqual(r,[])
    def test_accessor_and_constant_decoding(self):
        root=Parser(protected_literal(b'new message')).parse();info=prefix_information(root)
        self.assertEqual(info['table'].raw(1),b'new message')
        repl=replacements(root,info);self.assertEqual(set(repl.values()),{b'print',b'new message'})
        normalized=Emitter(repl).block(root);self.assertIn('"new message"',normalized)
        original,_=self.evaluate(protected_literal(b'new message'));new,_=self.evaluate(normalized)
        self.assertEqual(original.calls,new.calls)
    def test_lexical_redeclaration_does_not_rebind_captured_local(self):
        e,r=self.evaluate('local x=1; local f=function()return x end; local x=2; print(f(),x)')
        self.assertEqual(e.calls[0]['arguments'],(1.,2.))
    def test_mutable_capture(self):
        e,r=self.evaluate('local x=1; local f=function()x=x+1;return x end;print(f(),f(),x)')
        self.assertEqual(e.calls[0]['arguments'],(2.,3.,3.))
    def test_nil_return_arity(self):
        e,r=self.evaluate('local function f()return 1,nil,3 end;print(f());return f()')
        self.assertEqual(e.calls[0]['arguments'],(1.,None,3.));self.assertEqual(r,[1.,None,3.])
    def test_loop_and_repeat_scope(self):
        e,r=self.evaluate('local x=0;repeat local done=x==3;x+=1 until done;for i=1,3 do x+=i end;print(x)')
        self.assertEqual(e.calls[0]['arguments'],(10.,))
    def test_unknown_globals_abort_even_through_pcall(self):
        with self.assertRaises(Halt):self.evaluate('pcall(function()return os.execute("no")end)')
        with self.assertRaises(Halt):self.evaluate('print(getfenv().secret)')
    def test_unknown_branch_never_assumed_false(self):
        with self.assertRaises(Halt):self.evaluate('if unknown then print("a")else print("b")end')
    def test_budget_cannot_be_caught_by_submission(self):
        with self.assertRaises(Halt):self.evaluate('pcall(function()while true do end end)',max_steps=1000)
    def test_error_level_zero_and_protected_returns(self):
        e,r=self.evaluate('local ok,msg=pcall(function()error("test",0)end);print(ok,msg)')
        self.assertEqual(e.calls[0]['arguments'],(False,b'test'))
    def test_decoder_strings(self):
        self.assertEqual(decode_string(r'"\104\101\108\108\111"'),b'hello')
        self.assertEqual(decode_string('[=[\nhello]=]'),b'hello')
    def test_bool_and_numeric_table_keys_distinct(self):
        e,r=self.evaluate('local t={[true]=1,[1]=2};print(t[true],t[1])')
        self.assertEqual(e.calls[0]['arguments'],(1.,2.))
    def test_accessor_shadow_not_inlined(self):
        src=protected_literal(b'outer').replace('local f,v','local f,v;do local at=function()return "inner" end; print(at(-6))end')
        root=Parser(src).parse();reps=replacements(root,prefix_information(root));out=Emitter(reps).block(root)
        e,_=self.evaluate(out);self.assertEqual([c['arguments'] for c in e.calls],[(b'inner',),(b'outer',)])
    def test_empty_source_and_broken_syntax(self):
        for src in ('local = 1','if then end','foo('):
            with self.assertRaises((SyntaxFailure,IndexError)):Parser(src).parse()
    def test_strict_skips_application(self):
        with tempfile.TemporaryDirectory() as d,patch.dict(os.environ,{'LUAUVMP_STRICT_CAPTURE':'1'}):
            p=Path(d);src=p/'input.luau';src.write_text(protected_literal(b'example'))
            result=run_local(src,p/'out',30);report=json.loads((p/'out/recovery-report.json').read_text())
            self.assertEqual(report['modelRuns'],[]);self.assertEqual(result['primary'],'program.analysis.luau');self.assertTrue(result['partial'])
    @unittest.skipUnless(available(),'Official Luau unavailable')
    def test_native_multiple_owned_shapes(self):
        with tempfile.TemporaryDirectory() as d,patch.dict(os.environ,{'LUAUVMP_STRICT_CAPTURE':'0'}):
            root=Path(d)
            for i,text in enumerate((b'hello',b'second distinct message',b'utf8:\xe2\x98\x83',b'\x00\xffbinary')):
                src=root/f'input{i}.luau';src.write_text(protected_literal(text))
                result=run_local(src,root/f'out{i}',45)
                self.assertEqual(result['primary'],'program.application.luau',json.dumps(result))
                self.assertEqual(result['native_comparisons_passed'],3)
                self.assertTrue(result['partial']);self.assertTrue(result['decompiler']['compile_checked'])
    @unittest.skipUnless(available(),'Official Luau unavailable')
    def test_native_unknown_global_keeps_analysis(self):
        with tempfile.TemporaryDirectory() as d,patch.dict(os.environ,{'LUAUVMP_STRICT_CAPTURE':'0'}):
            root=Path(d);src=root/'input.luau';src.write_text(protected_literal(b'hello').replace('f(v)','f(workspace.Name)'))
            result=run_local(src,root/'out',30)
            self.assertEqual(result['primary'],'program.analysis.luau');self.assertTrue(result['partial'])
    @unittest.skipUnless(available(),'Official Luau unavailable')
    def test_plain_source_is_compiled_not_executed(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);src=root/'input.luau';src.write_text('print("not executed")')
            result=run_local(src,root/'out',30)
            self.assertEqual(result['primary'],'program.source.luau');self.assertFalse(result['final_payload_executed']);self.assertFalse(result['partial'])
    @unittest.skipUnless(available(),'Official Luau unavailable')
    def test_native_harness_no_host_access_and_deadline(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);src=root/'input.luau'
            src.write_text('print(require,loadfile,io,os,debug,loadstring)')
            result=native(src,'trace',root);self.assertTrue(result['ok'],result)
            self.assertEqual(result['events'][0]['arguments'],[{'type':'nil'}]*6)
            src.write_text('while true do end');result=native(src,'trace',root,timeout=.2)
            self.assertFalse(result['ok']);self.assertIn('timed out',result['error'])

if __name__=='__main__':unittest.main()
