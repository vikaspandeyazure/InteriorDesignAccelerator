<!--
Thanks for sending a pull request! Please fill in the sections below.
Keep the PR small and focused: one concern per PR.
-->

## Summary

<!-- One or two sentences describing the change and why it is needed. -->

## Related issue

<!-- Link the issue this PR addresses, e.g. "Closes #123". Use "Refs #123" if it is partial. -->

Closes #

## Type of change

- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would change existing API / contract / deploy behavior)
- [ ] Documentation only
- [ ] Infra / CI only

## Component(s) touched

- [ ] `Orchestrator.Api`
- [ ] `Web.Ui` (Blazor Server)
- [ ] `Shared.Contracts`
- [ ] `CatalogExtractor`
- [ ] `infra/modules` (Bicep)
- [ ] `infra/scripts/deploy.ps1`
- [ ] `tests/Orchestrator.Tests`
- [ ] `docs/`
- [ ] `.github/` (workflows, templates)

## Checklist

- [ ] `dotnet build .\InteriorDesignAccelerator.slnx` passes locally
- [ ] `dotnet test .\tests\Orchestrator.Tests\Orchestrator.Tests.csproj` passes locally
- [ ] I added or updated tests where it made sense
- [ ] I updated [`CHANGELOG.md`](../blob/master/CHANGELOG.md) under `[Unreleased]`
- [ ] I updated relevant docs (`README.md` / `docs/*`) if behavior or deploy steps changed
- [ ] No secrets, keys, SAS tokens, or subscription IDs are included in this PR
- [ ] If `infra/` changed: I verified `deploy.ps1` is still idempotent (re-run is a no-op)
- [ ] I followed the conventions in [`CONTRIBUTING.md`](../blob/master/CONTRIBUTING.md)

## Screenshots / traces (UI or behavior changes)

<!-- Drop screenshots, GIFs, or agent-trace excerpts here. Redact secrets. -->

## Notes for reviewers

<!-- Anything tricky? Anything you specifically want feedback on? -->
