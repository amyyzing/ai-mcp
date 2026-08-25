import json
import pathlib
import tempfile
import unittest
from unittest import mock

import server


class WorkerTests(unittest.TestCase):
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
