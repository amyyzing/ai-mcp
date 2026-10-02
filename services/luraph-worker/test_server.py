import json
import base64
import hashlib
import pathlib
import tempfile
import unittest
from unittest import mock

import server


class WorkerTests(unittest.TestCase):
    def test_failed_engine_retains_partial_source_and_diagnostics(self):
        def fake_run(command, **kwargs):
            root = pathlib.Path(command[command.index("-o") + 1])
            root.mkdir()
            (root / "program.decompiled.luau").write_text("return 1")
            return mock.Mock(returncode=2, stdout="captured", stderr="finalization failed")
        with mock.patch("server.subprocess.run", side_effect=fake_run):
            result = server.run_devirtualizer({"source": "input"})
        self.assertTrue(result["ok"])
        self.assertEqual(result["recoveryStatus"], "partial")
        self.assertEqual(result["engineExitCode"], 2)
        self.assertEqual(result["source"], "return 1")
        self.assertEqual(result["diagnostics"][0]["code"], "engine-nonzero-exit")

    def test_zero_exit_does_not_hide_stage_failure(self):
        def fake_run(command, **kwargs):
            root = pathlib.Path(command[command.index("-o") + 1])
            root.mkdir()
            (root / "program.decompiled.luau").write_text("return 1")
            (root / "pipeline.json").write_text('{"capture":{"finalization_error":"failed"}}')
            return mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch("server.subprocess.run", side_effect=fake_run):
            result = server.run_devirtualizer({"source": "input"})
        self.assertEqual(result["recoveryStatus"], "partial")
        self.assertEqual(result["diagnostics"][0]["evidence"]["path"], ["capture", "finalization_error"])

    def test_failure_without_source_is_not_reported_as_recovery(self):
        with mock.patch("server.subprocess.run", return_value=mock.Mock(returncode=2, stdout="", stderr="unsupported")):
            with self.assertRaisesRegex(RuntimeError, "without recovered source"):
                server.run_devirtualizer({"source": "input"})

    def test_quality_evidence_preserves_conflicting_stages(self):
        evidence = server.quality_evidence({"first": {"compile_checked": True},
                                           "second": {"compile_checked": False, "finalization_error": "failed"}})
        self.assertEqual([e["value"] for e in evidence], [True, False, "failed"])
        self.assertEqual(evidence[1]["path"], ["second", "compile_checked"])

    def test_artifacts_preserve_all_bytes_and_representations(self):
        with tempfile.TemporaryDirectory() as name:
            root = pathlib.Path(name)
            raw = b"return '\xff'\r\n" + b"x" * 2000
            (root / "program.decompiled.luau").write_bytes(raw)
            (root / "pipeline.json").write_text('{"finalization_error":"failed"}')
            artifacts, omitted = server.collect_artifacts(root, "program.decompiled.luau")
            self.assertEqual(len(artifacts), 2)
            self.assertEqual(omitted, [])
            self.assertEqual(base64.b64decode(artifacts[0]["contentBase64"]), raw)
            self.assertEqual(artifacts[0]["sha256"], hashlib.sha256(raw).hexdigest())
            self.assertEqual(artifacts[0]["representation"], "structural-source")

    def test_artifact_quota_reports_omission_without_partial_file(self):
        with tempfile.TemporaryDirectory() as name:
            root = pathlib.Path(name)
            (root / "program.decompiled.luau").write_bytes(b"1234")
            (root / "other.bin").write_bytes(b"12345")
            with mock.patch.object(server, "MAX_ARTIFACT_BYTES", 4):
                artifacts, omitted = server.collect_artifacts(root, "program.decompiled.luau")
            self.assertEqual(len(artifacts), 1)
            self.assertEqual(omitted[0]["name"], "other.bin")
            self.assertEqual(omitted[0]["reason"], "byte-quota")

    def test_preview_does_not_truncate_retained_artifact(self):
        def fake_run(command, **kwargs):
            root = pathlib.Path(command[command.index("-o") + 1])
            root.mkdir()
            (root / "program.decompiled.luau").write_text("x" * 2000)
            return mock.Mock(returncode=0, stdout="", stderr="")
        with mock.patch("server.subprocess.run", side_effect=fake_run):
            result = server.run_devirtualizer({"source": "input", "maxResultChars": 1000})
        self.assertEqual(len(result["source"]), 1000)
        self.assertTrue(result["sourceTruncated"])
        self.assertEqual(len(base64.b64decode(result["artifacts"][0]["contentBase64"])), 2000)
        self.assertEqual(result["recoveryStatus"], "unverified")

    def test_quality_summary_finds_nested_metrics(self):
        quality = server.quality_summary(
            {
                "decompiler": {
                    "compile_checked": True,
                    "fallback_instructions": 0,
                },
                "capture": {
                    "final_payload_executed": False,
                    "capture_kind": "strict",
                },
            }
        )
        self.assertEqual(quality["compileChecked"], True)
        self.assertEqual(quality["fallbackInstructions"], 0)
        self.assertEqual(quality["finalPayloadExecuted"], False)
        self.assertEqual(quality["captureKind"], "strict")

    def test_recovered_output_prefers_embedded_source(self):
        with tempfile.TemporaryDirectory() as name:
            root = pathlib.Path(name)
            (root / "program.decompiled.luau").write_text("structural", encoding="utf-8")
            (root / "embedded_main.luau").write_text("exact", encoding="utf-8")
            filename, source, total, truncated = server.recovered_output(root, 100)
            self.assertEqual(filename, "embedded_main.luau")
            self.assertEqual(source, "exact")
            self.assertEqual(total, 5)
            self.assertFalse(truncated)

    def test_run_uses_fixed_arguments_and_does_not_inherit_worker_token(self):
        def fake_run(command, **kwargs):
            output_dir = pathlib.Path(command[command.index("-o") + 1])
            output_dir.mkdir()
            (output_dir / "embedded_main.luau").write_text("return true", encoding="utf-8")
            (output_dir / "pipeline.json").write_text(
                json.dumps({"compile_checked": True, "final_payload_executed": False}),
                encoding="utf-8",
            )
            self.assertIn("--no-lua-expert", command)
            self.assertEqual(kwargs["env"]["LUAUVMP_STRICT_CAPTURE"], "1")
            self.assertNotIn("LURAPH_WORKER_TOKEN", kwargs["env"])
            return mock.Mock(returncode=0, stdout="ok", stderr="")

        with mock.patch.dict("os.environ", {"LURAPH_WORKER_TOKEN": "secret"}, clear=False):
            with mock.patch("server.subprocess.run", side_effect=fake_run):
                result = server.run_devirtualizer(
                    {"source": "return true", "captureMode": "strict", "timeoutSeconds": 30}
                )
        self.assertTrue(result["ok"])
        self.assertEqual(result["outputFile"], "embedded_main.luau")
        self.assertEqual(result["source"], "return true")


if __name__ == "__main__":
    unittest.main()
