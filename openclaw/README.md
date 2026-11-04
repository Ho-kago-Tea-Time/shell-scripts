# OpenClaw Windows installer

Chinese usage and maintenance guide: [README.zh-CN.md](./README.zh-CN.md).

[windows/upstream/install.ps1](./windows/upstream/install.ps1) is a byte-for-byte snapshot of the official installer, managed here independently of the OpenClaw source checkout. There are no local behavior changes and no installer download wrapper. Attribution, immutable source URLs, commits and SHA-256 hashes are recorded in [SOURCE.json](./windows/upstream/SOURCE.json). The upstream [MIT license](./windows/upstream/LICENSE) is preserved. Authors: OpenClaw project contributors; copyright: OpenClaw Foundation.

From this repository's root, first select and inspect your existing OpenClaw checkout, then install it:

```powershell
git -C 'C:\src\openclaw' switch YOUR_BRANCH
git -C 'C:\src\openclaw' status --short --branch
git -C 'C:\src\openclaw' rev-parse HEAD

# Actual installation: run after reviewing the effects described below.
& .\openclaw\windows\upstream\install.ps1 `
    -InstallMethod git -GitDir 'C:\src\openclaw' -NoGitUpdate -NoOnboard
```

Use Windows PowerShell 5.1 or PowerShell 7. Git and network access are required; Node and pnpm may be provisioned. The installer needs no sibling runtime files and can run outside the OpenClaw source directory. It still needs a complete target source checkout and downloaded build dependencies.

In this snapshot, `-Tag` does not select the Git revision, despite an upstream documentation example and a script hint mentioning `-Tag main`. `-NoGitUpdate` skips pulling only; a missing checkout may still be cloned. Verify that the directory already contains your intended branch and commit. `-NoOnboard` skips initial setup only.

Actual installation runs dependency lifecycle scripts and builds, permits lockfile changes with `--no-frozen-lockfile`, and can clear `node_modules` on retry. It publishes an `openclaw.cmd` wrapper, may change user PATH and Node, retires an existing npm installation after validating the replacement, refreshes/restarts a loaded Gateway service, and runs `doctor --fix --non-interactive` for Git installs. There is no switch here to skip Doctor or service refresh. This is an installer, with operational effects beyond building source.

Verified on 2026-11-04: the website and immutable source at `6210f1275c4f7b30bb72fbbc28ef59874ea444cf` match (104073 bytes, SHA-256 `39854b15b78039ae7d36d523ba57bb9f13c1b8900684d87371f79a277642f217`). The script's last-change commit is `6c4a948c3049f379007fc7702faf42f3cea8558f`. Equality establishes matching content, not the website deployment revision. This pins the installer, not the application or downloaded dependencies. Git attributes preserve the script and license bytes.

Offline validation, without executing the installer:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\openclaw\tests\Test-InstallerSnapshot.ps1
pwsh -NoProfile -File .\openclaw\tests\Test-InstallerSnapshot.ps1
```

The execution-policy override applies only to that validation process; it does not change persistent policy. Windows PowerShell 5.1.22621.6133 and PowerShell 7.6.5 passed hashes and parsing at import. Help was also checked in separate processes after reviewing its early return. No actual installation or service/migration commands were run. Real build/upgrade compatibility remains untested. `-DryRun` is only a parameter preview and still initializes process TEMP/TMP before returning.

For manual updates, download the website and source at a resolved full commit SHA to a temporary directory, compare hashes and review `git diff --no-index` before replacing the baseline. Keep separate candidates if they differ. Recheck licensing, runtime companion files, Git handling, downloads, Node/pnpm, lockfiles, PATH, Doctor and service behavior. Update provenance and documentation, then rerun offline checks; inspect help control flow before executing `-Help`. See the Chinese guide for the full procedure. If customization is later needed, create `windows/install.ps1` from the preserved upstream baseline and document the patch separately. No customization is needed for this task.
