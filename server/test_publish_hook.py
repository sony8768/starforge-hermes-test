import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).parent / "hermes-hook" / "handler.py"
SPEC = importlib.util.spec_from_file_location("publish_hook", MODULE_PATH)
hook = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(hook)


class PublishHookTests(unittest.TestCase):
    def create_complete_job(self, root: Path, task_id: str = "SF-TEST-0001") -> Path:
        job = root / task_id
        for relative in hook.REQUIRED:
            path = job / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("{}\n", encoding="utf-8")
        return job

    def test_publishes_complete_job_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            job_root = root / "jobs"
            job_root.mkdir()
            job = self.create_complete_job(job_root)
            publisher = root / "publisher"
            publisher.write_text("#!/bin/sh\n", encoding="utf-8")
            log_file = root / "hook.jsonl"
            completed = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout='{"status":"published"}\n',
                stderr="",
            )

            with patch.object(hook.subprocess, "run", return_value=completed) as run:
                first = hook.publish_ready_jobs(job_root, publisher, log_file)
                second = hook.publish_ready_jobs(job_root, publisher, log_file)

            self.assertEqual("published", first[0]["status"])
            self.assertEqual([], second)
            self.assertTrue((job / ".starforge-published").is_file())
            run.assert_called_once()

    def test_skips_incomplete_job(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            job_root = root / "jobs"
            job = job_root / "SF-TEST-0002"
            job.mkdir(parents=True)
            publisher = root / "publisher"
            publisher.write_text("#!/bin/sh\n", encoding="utf-8")

            with patch.object(hook.subprocess, "run") as run:
                outcomes = hook.publish_ready_jobs(
                    job_root,
                    publisher,
                    root / "hook.jsonl",
                )

            self.assertEqual([], outcomes)
            run.assert_not_called()

    def test_records_failure_without_marker(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            job_root = root / "jobs"
            job_root.mkdir()
            job = self.create_complete_job(job_root)
            publisher = root / "publisher"
            publisher.write_text("#!/bin/sh\n", encoding="utf-8")
            log_file = root / "hook.jsonl"
            failed = subprocess.CompletedProcess(
                args=[],
                returncode=2,
                stdout="",
                stderr="validation failed",
            )

            with patch.object(hook.subprocess, "run", return_value=failed):
                outcomes = hook.publish_ready_jobs(job_root, publisher, log_file)

            self.assertEqual("failed", outcomes[0]["status"])
            self.assertFalse((job / ".starforge-published").exists())
            record = json.loads(log_file.read_text(encoding="utf-8"))
            self.assertEqual("validation failed", record["stderr"])


if __name__ == "__main__":
    unittest.main()
