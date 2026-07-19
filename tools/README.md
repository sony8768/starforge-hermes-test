# StarForge North Star tools

## Import a Hermes result

`Import-HermesResult.ps1` converts a Hermes result archive into a locally
validated Git branch. With `-Publish`, it also pushes the branch and creates a
draft pull request.

The importer keeps GitHub write credentials on the North Star computer. Hermes
only needs read access to the repository and never receives permission to push
or merge code.

### Prerequisites

- Windows PowerShell 5.1 or PowerShell 7
- Git
- .NET 8 SDK
- GitHub CLI (`gh`) when using `-Publish`
- A clean local checkout of the target repository

### Validate, import, and commit locally

```powershell
.\tools\Import-HermesResult.ps1 `
  -ArchivePath "C:\Users\admin\Desktop\SF-20260719-0001-result.tar.gz" `
  -RepoPath "C:\Users\admin\Desktop\starforge-hermes-test"
```

### Validate, import, push, and create a draft PR

```powershell
.\tools\Import-HermesResult.ps1 `
  -ArchivePath "C:\Users\admin\Desktop\SF-20260719-0001-result.tar.gz" `
  -RepoPath "C:\Users\admin\Desktop\starforge-hermes-test" `
  -Publish
```

Before changing the repository, the importer checks:

- the archive contains only approved result paths;
- task, lease, and report IDs agree;
- the report status is `completed`;
- all acceptance criteria passed;
- the task and report use the same base Commit;
- every reported SHA-256 hash matches;
- the base Commit belongs to the remote base branch;
- the repository is clean;
- the result branch does not already exist.

It then replays the patch, runs a Release build and test, and creates a local
commit. Publishing is optional and always creates a draft pull request.

### Required result archive layout

```text
output/
  report.json
  change.patch
checks/
  build.log
  test.log
input/
  task.json
  lease.json
```

The Tencent Cloud packaging step must include the original task and lease:

```bash
sudo tar -czf /home/ubuntu/SF-TASK-result.tar.gz \
  -C /home/hermes/starforge/jobs/SF-TASK \
  output checks input/task.json input/lease.json
```

The importer rejects incomplete archives instead of trying to infer missing
task authority from the patch.
