"""Hermes gateway hook that publishes completed StarForge jobs."""

from __future__ import annotations

import asyncio
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

TASK_PATTERN = re.compile(r"^SF-[A-Za-z0-9-]+$")
JOB_ROOT = Path("/home/hermes/starforge/jobs")
PUBLISHER = Path("/usr/local/bin/starforge-publish-result")
LOG_FILE = Path("/home/hermes/.hermes/logs/starforge-publish-hook.jsonl")
REQUIRED = (
    "input/task.json",
    "input/lease.json",
    "output/report.json",
    "output/change.patch",
    "checks/build.log",
    "checks/test.log",
)


def append_log(event: dict, log_file: Path = LOG_FILE) -> None:
    log_file.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=False) + "\n")


def publish_ready_jobs(
    job_root: Path = JOB_ROOT,
    publisher: Path = PUBLISHER,
    log_file: Path = LOG_FILE,
) -> list[dict]:
    outcomes: list[dict] = []
    if not job_root.is_dir() or not publisher.is_file():
        return outcomes

    for job in sorted(job_root.iterdir()):
        if not job.is_dir() or not TASK_PATTERN.fullmatch(job.name):
            continue

        marker = job / ".starforge-published"
        if marker.exists():
            continue
        if any(not (job / relative).is_file() for relative in REQUIRED):
            continue

        event = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "taskId": job.name,
        }
        try:
            result = subprocess.run(
                [
                    "sudo",
                    "-n",
                    str(publisher),
                    job.name,
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=120,
            )
            event["exitCode"] = result.returncode
            event["stdout"] = result.stdout.strip()
            event["stderr"] = result.stderr.strip()

            if result.returncode == 0:
                marker.write_text(result.stdout, encoding="utf-8")
                event["status"] = "published"
            elif "already exists" in result.stderr:
                marker.write_text(
                    json.dumps({"status": "already-published"}) + "\n",
                    encoding="utf-8",
                )
                event["status"] = "already-published"
            else:
                event["status"] = "failed"
        except Exception as exc:  # Hook failures must never break Hermes.
            event["status"] = "error"
            event["error"] = f"{type(exc).__name__}: {exc}"

        append_log(event, log_file)
        outcomes.append(event)

    return outcomes


async def handle(event_type: str, context: dict):
    """Run after a gateway agent turn; Hermes ignores the return value."""
    if event_type != "agent:end":
        return
    await asyncio.to_thread(publish_ready_jobs)
