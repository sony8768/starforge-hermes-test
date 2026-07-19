#!/usr/bin/env python3
"""Validate and atomically publish one Hermes result archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import tarfile
import tempfile
from pathlib import Path

try:
    import fcntl
except ImportError:  # pragma: no cover - Windows validation uses no process lock.
    fcntl = None

try:
    import grp
except ImportError:  # pragma: no cover - Publisher CLI runs on Linux.
    grp = None

TASK_PATTERN = re.compile(r"^SF-[A-Za-z0-9-]+$")
JOB_ROOT = Path("/home/hermes/starforge/jobs")
RESULT_ROOT = Path("/srv/starforge-sftp/results")
RESULT_GROUP = "starforgepull"

REQUIRED_FILES = (
    "input/task.json",
    "input/lease.json",
    "output/report.json",
    "output/change.patch",
    "checks/build.log",
    "checks/test.log",
)


class PublishError(RuntimeError):
    """Raised when a result cannot be safely published."""


def read_json(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise PublishError(f"Unable to read JSON file {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise PublishError(f"JSON root must be an object: {path}")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_job_path(job: Path, relative: str) -> Path:
    candidate = (job / relative).resolve(strict=True)
    job_root = job.resolve(strict=True)
    if candidate != job_root and job_root not in candidate.parents:
        raise PublishError(f"Path escapes the task directory: {relative}")
    return candidate


def require_regular_file(job: Path, relative: str) -> Path:
    path = resolve_job_path(job, relative)
    mode = path.lstat().st_mode
    if not stat.S_ISREG(mode):
        raise PublishError(f"Required path is not a regular file: {relative}")
    return path


def validate_tree(root: Path) -> None:
    if not root.is_dir() or root.is_symlink():
        raise PublishError(f"Expected a real directory: {root}")
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        for name in directories:
            path = current_path / name
            if path.is_symlink():
                raise PublishError(f"Symbolic links are not allowed: {path}")
        for name in files:
            path = current_path / name
            if path.is_symlink() or not path.is_file():
                raise PublishError(f"Only regular files are allowed: {path}")


def validate_result(job: Path, task_id: str) -> dict:
    for relative in REQUIRED_FILES:
        require_regular_file(job, relative)

    validate_tree(job / "output")
    validate_tree(job / "checks")

    task = read_json(job / "input/task.json")
    lease = read_json(job / "input/lease.json")
    report = read_json(job / "output/report.json")

    identities = (task.get("taskId"), lease.get("taskId"), report.get("taskId"))
    if identities != (task_id, task_id, task_id):
        raise PublishError("Task IDs do not match the requested task.")
    if report.get("status") != "completed":
        raise PublishError("Report status must be completed.")
    if report.get("leaseId") != lease.get("leaseId"):
        raise PublishError("Lease ID does not match between lease and report.")
    if report.get("errors"):
        raise PublishError("Report contains execution errors.")

    acceptance = report.get("acceptanceResults")
    if not isinstance(acceptance, list) or not acceptance:
        raise PublishError("Report has no acceptance results.")
    if any(not item.get("passed") for item in acceptance if isinstance(item, dict)):
        raise PublishError("One or more acceptance criteria failed.")
    if any(not isinstance(item, dict) for item in acceptance):
        raise PublishError("Acceptance results contain an invalid entry.")

    task_revision = task.get("repository", {}).get("baseCommit")
    report_revision = report.get("revision", {}).get("baseCommit")
    if not task_revision or task_revision != report_revision:
        raise PublishError("Base Commit does not match between task and report.")
    if not report.get("revision", {}).get("resultCommit"):
        raise PublishError("Report result Commit is missing.")

    reported_files = report.get("files")
    if not isinstance(reported_files, dict) or not reported_files:
        raise PublishError("Report file hash map is missing.")
    for relative, expected in reported_files.items():
        if not isinstance(relative, str) or not isinstance(expected, str):
            raise PublishError("Report file hash entry is invalid.")
        path = require_regular_file(job, relative)
        if sha256_file(path) != expected.lower():
            raise PublishError(f"SHA-256 mismatch: {relative}")

    return report


def add_tree(archive: tarfile.TarFile, job: Path, relative_root: str) -> None:
    root = job / relative_root
    archive.add(root, arcname=relative_root, recursive=False)
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise PublishError(f"Symbolic links are not allowed: {path}")
        if not (path.is_dir() or path.is_file()):
            raise PublishError(f"Unsupported filesystem entry: {path}")
        archive.add(path, arcname=path.relative_to(job).as_posix(), recursive=False)


def publish(
    task_id: str,
    job_root: Path,
    result_root: Path,
    result_gid: int | None,
) -> dict:
    if not TASK_PATTERN.fullmatch(task_id):
        raise PublishError("Invalid StarForge task ID.")

    job_root = job_root.resolve(strict=True)
    job = (job_root / task_id).resolve(strict=True)
    if job_root not in job.parents:
        raise PublishError("Task directory escapes the configured job root.")

    result_root = result_root.resolve(strict=True)
    report = validate_result(job, task_id)
    destination = result_root / f"{task_id}-result.tar.gz"
    if destination.exists():
        raise PublishError(f"Published result already exists: {destination}")

    lock_path = Path("/tmp") / f"starforge-publish-{task_id}.lock"
    with lock_path.open("w", encoding="utf-8") as lock:
        if fcntl is not None:
            fcntl.flock(lock, fcntl.LOCK_EX)
        if destination.exists():
            raise PublishError(f"Published result already exists: {destination}")

        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{task_id}-",
            suffix=".tar.gz.partial",
            dir=result_root,
        )
        os.close(descriptor)
        temporary = Path(temporary_name)

        try:
            with tarfile.open(temporary, "w:gz", format=tarfile.PAX_FORMAT) as archive:
                add_tree(archive, job, "output")
                add_tree(archive, job, "checks")
                archive.add(
                    job / "input/task.json",
                    arcname="input/task.json",
                    recursive=False,
                )
                archive.add(
                    job / "input/lease.json",
                    arcname="input/lease.json",
                    recursive=False,
                )

            os.chmod(temporary, 0o640)
            if result_gid is not None:
                os.chown(temporary, 0, result_gid)
            archive_hash = sha256_file(temporary)
            os.replace(temporary, destination)
        finally:
            if temporary.exists():
                temporary.unlink()

    return {
        "taskId": task_id,
        "status": "published",
        "archive": str(destination),
        "archiveSha256": archive_hash,
        "baseCommit": report["revision"]["baseCommit"],
        "resultCommit": report["revision"]["resultCommit"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("task_id")
    args = parser.parse_args()

    try:
        if grp is None:
            raise PublishError("The publisher CLI must run on Linux.")
        group_id = grp.getgrnam(RESULT_GROUP).gr_gid
        result = publish(args.task_id, JOB_ROOT, RESULT_ROOT, group_id)
    except (PublishError, KeyError, OSError) as exc:
        parser.error(str(exc))

    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
