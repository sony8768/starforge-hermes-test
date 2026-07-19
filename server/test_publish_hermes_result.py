import hashlib
import importlib.util
import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("publish_hermes_result.py")
SPEC = importlib.util.spec_from_file_location("publisher", MODULE_PATH)
publisher = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(publisher)


class PublisherTests(unittest.TestCase):
    def create_job(self, root: Path, task_id: str = "SF-TEST-0001") -> Path:
        job = root / "jobs" / task_id
        for relative in ("input", "output", "checks"):
            (job / relative).mkdir(parents=True, exist_ok=True)

        (job / "output/change.patch").write_text("diff --git a/a b/a\n", encoding="utf-8")
        (job / "checks/build.log").write_text("Build succeeded.\n", encoding="utf-8")
        (job / "checks/test.log").write_text("Passed: 1\n", encoding="utf-8")

        base = "a" * 40
        result = "b" * 40
        task = {"taskId": task_id, "repository": {"baseCommit": base}}
        lease = {"taskId": task_id, "leaseId": f"LEASE-{task_id}"}

        hashes = {}
        for relative in (
            "output/change.patch",
            "checks/build.log",
            "checks/test.log",
        ):
            hashes[relative] = hashlib.sha256((job / relative).read_bytes()).hexdigest()

        report = {
            "taskId": task_id,
            "leaseId": lease["leaseId"],
            "status": "completed",
            "revision": {"baseCommit": base, "resultCommit": result},
            "acceptanceResults": [{"criterion": "test", "passed": True}],
            "files": hashes,
            "errors": [],
        }

        (job / "input/task.json").write_text(json.dumps(task), encoding="utf-8")
        (job / "input/lease.json").write_text(json.dumps(lease), encoding="utf-8")
        (job / "output/report.json").write_text(json.dumps(report), encoding="utf-8")
        return job

    def test_publishes_complete_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            job = self.create_job(root)
            results = root / "results"
            results.mkdir()

            outcome = publisher.publish("SF-TEST-0001", job.parent, results, None)
            archive_path = Path(outcome["archive"])

            self.assertTrue(archive_path.is_file())
            if os.name != "nt":
                self.assertEqual(0o640, archive_path.stat().st_mode & 0o777)
            with tarfile.open(archive_path, "r:gz") as archive:
                names = set(archive.getnames())
            self.assertIn("input/task.json", names)
            self.assertIn("input/lease.json", names)
            self.assertIn("output/report.json", names)
            self.assertIn("checks/test.log", names)

    def test_rejects_hash_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            job = self.create_job(root)
            results = root / "results"
            results.mkdir()
            (job / "checks/test.log").write_text("tampered\n", encoding="utf-8")

            with self.assertRaisesRegex(publisher.PublishError, "SHA-256 mismatch"):
                publisher.publish("SF-TEST-0001", job.parent, results, None)

    def test_rejects_symbolic_link(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            job = self.create_job(root)
            results = root / "results"
            results.mkdir()
            target = job / "checks/build.log"
            link = job / "checks/linked.log"
            try:
                link.symlink_to(target)
            except OSError:
                self.skipTest("Symbolic links are unavailable on this platform")

            with self.assertRaisesRegex(publisher.PublishError, "Symbolic links"):
                publisher.publish("SF-TEST-0001", job.parent, results, None)


if __name__ == "__main__":
    unittest.main()
