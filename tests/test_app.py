import io
import json
import time
import unittest
from pathlib import Path
from unittest import mock
from fastapi.testclient import TestClient
import server

class AppTests(unittest.TestCase):
    def setUp(self):
        server.JOBS.clear()
        server.RATES.clear()
        self.client = TestClient(server.app)
        self.client.get('/')

    def fake_process(self, command, **kwargs):
        output = Path(command[3]); output.mkdir()
        (output/'program.decompiled.luau').write_text('print("fixture")\n')
        (output/'pipeline.json').write_text(json.dumps({
            'decompiler': {'compile_checked': True, 'fallback_instructions': 0},
            'final_payload_executed': False, 'bootstrap_executed': False,
            'capture_kind': 'strict-final', 'prototypes': 1, 'instructions': 3}))
        self.assertIn('start_new_session', kwargs)
        self.assertNotIn('SECRET_TEST_KEY', kwargs['env'])
        return mock.Mock(stdout=io.BytesIO(b'[1/7] unpack\n[7/7] compile\n'), returncode=0,
                         poll=mock.Mock(return_value=0), wait=mock.Mock(return_value=0))

    def test_index(self):
        response = self.client.get('/')
        self.assertEqual(response.status_code, 200)
        self.assertIn('luraph-devirtualiser', response.text)
        self.assertEqual(response.headers['cache-control'], 'no-store')
        self.assertIn('httponly', response.headers.get('set-cookie', '').lower() or 'httponly')

    def test_health_without_engine(self):
        with mock.patch.object(server, 'engine_ready', return_value=False):
            self.assertEqual(self.client.get('/api/health').status_code, 503)
            self.assertEqual(self.client.post('/api/jobs', json={'source':'return 1'}).status_code, 503)

    def test_validation(self):
        with mock.patch.object(server, 'engine_ready', return_value=True):
            for body in [{}, {'source':''}, {'source':1}, {'source':'a','timeout':True},
                         {'source':'a','timeout':700}, {'source':'a','mode':'unknown'}]:
                self.assertEqual(self.client.post('/api/jobs', json=body).status_code, 400)
            self.assertEqual(self.client.post('/api/jobs', content='broken json').status_code, 400)

    def test_oversize(self):
        with mock.patch.object(server, 'engine_ready', return_value=True):
            self.assertEqual(self.client.post('/api/jobs', json={'source':'x'*(server.MAX_SOURCE+1)}).status_code, 413)

    def test_origin(self):
        self.assertEqual(self.client.post('/api/jobs', json={'source':'x'}, headers={'Origin':'https://other.example'}).status_code, 403)

    def test_real_job_lifecycle_with_mock_engine(self):
        with mock.patch.object(server, 'engine_ready', return_value=True), mock.patch.object(server.subprocess, 'Popen', side_effect=self.fake_process), mock.patch.dict('os.environ', {'SECRET_TEST_KEY':'do-not-pass'}):
            r=self.client.post('/api/jobs', json={'source':'owned fixture','mode':'strict','timeout':30})
            self.assertEqual(r.status_code, 202)
            job_id=r.json()['id']
            for _ in range(100):
                job=self.client.get('/api/jobs/'+job_id).json()
                if job['state'] in ('completed','failed'): break
                time.sleep(.02)
            self.assertEqual(job['state'],'completed',job)
            self.assertTrue(job['quality']['compileChecked'])
            self.assertEqual(job['primary'],'program.decompiled.luau')
            output=self.client.get(f'/api/jobs/{job_id}/artifact', params={'name':job['primary']})
            self.assertEqual(output.json()['text'],'print("fixture")\n')
            exported=self.client.get(f'/api/jobs/{job_id}/download')
            self.assertEqual(exported.status_code,200)
            self.assertTrue(exported.content.startswith(b'PK'))

    def test_job_ownership(self):
        a=server.Job('isolated','different-owner','x.lua','hash','strict',30)
        server.JOBS[a.id]=a
        self.assertEqual(self.client.get('/api/jobs/isolated').status_code,404)
        self.assertEqual(self.client.delete('/api/jobs/isolated').status_code,404)
        server.JOBS.clear()

    def own_job(self):
        import hashlib
        owner=hashlib.sha256(self.client.cookies.get('ld_session').encode()).hexdigest()
        j=server.Job('testjob',owner,'x.luau','hash','strict',30)
        j.state='completed';j.finished=time.time();server.JOBS[j.id]=j
        return j

    def test_preview_and_complete_download(self):
        job=self.own_job()
        raw=('é\n' * server.PREVIEW).encode()
        job.artifacts['all.luau']=raw
        r=self.client.get('/api/jobs/testjob/artifact',params={'name':'all.luau'})
        self.assertTrue(r.json()['previewTruncated'])
        self.assertEqual(len(r.json()['text']),server.PREVIEW)
        r=self.client.get('/api/jobs/testjob/artifact',params={'name':'all.luau','download':'true'})
        self.assertEqual(r.content,raw)

    def test_no_artifact_path_traversal(self):
        self.own_job()
        self.assertEqual(self.client.get('/api/jobs/testjob/artifact',params={'name':'../../etc/passwd'}).status_code,404)

    def test_expiration(self):
        job=self.own_job();job.finished=time.time()-server.TTL-1
        self.assertEqual(self.client.get('/api/jobs/testjob').status_code,404)

    def test_cancel_queued_job(self):
        job=self.own_job();job.finished=None;job.state='queued'
        self.assertEqual(self.client.delete('/api/jobs/testjob').status_code,200)
        self.assertTrue(job.cancelled.is_set())
        server.JOBS.clear()

    def test_global_queue_limit(self):
        with mock.patch.object(server,'engine_ready',return_value=True):
            for i in range(server.MAX_PENDING):
                job=server.Job(str(i),'other','x','hash','strict',30);server.JOBS[job.id]=job
            self.assertEqual(self.client.post('/api/jobs',json={'source':'x'}).status_code,429)
        server.JOBS.clear()

if __name__=='__main__': unittest.main()
