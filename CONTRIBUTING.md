# Contributing

Thanks for your interest in improving the Interior Design Accelerator! This repo is a reference implementation, so the bar for changes is:

- **Code stays minimal and readable** - this is a learning resource as much as it is a working system.
- **No new secrets / no new public surfaces** without justification.
- **Tests must keep passing.**

## Ways to contribute

| Kind | Where |
|---|---|
| Bug report | [Open an issue](../../issues/new/choose) using the **Bug report** template |
| Feature idea | [Open an issue](../../issues/new/choose) using the **Feature request** template |
| Documentation fix | PR straight against `main` |
| Code change | Fork + branch + PR |
| Security issue | **Do NOT open a public issue.** See [`SECURITY.md`](SECURITY.md) |

## Dev loop

```pwsh
git clone https://github.com/<you>/InteriorDesignAccelerator.git
cd InteriorDesignAccelerator
dotnet build .\InteriorDesignAccelerator.slnx
dotnet test  .\tests\Orchestrator.Tests\Orchestrator.Tests.csproj
```

Run the apps locally with two terminals (see [`README.md`](README.md) > Quick start).

## Coding conventions

- **C# 12, .NET 8**, nullable enabled, implicit usings on.
- Minimal APIs in `Orchestrator.Api`; Blazor Server in `Web.Ui`.
- Keep public surface small. New DTOs go in `Shared.Contracts`.
- Prefer `record` types for DTOs. Use `sealed` everywhere it's safe to.
- For async paths, use `CancellationToken` and pass it through.
- Log via `ILogger<T>`; never `Console.WriteLine` in production code.
- Comments explain **why**, not **what**. The existing files set the tone (see `OrchestratorAgent.cs` step 2.5 for the gold standard).

## Pull requests

1. Branch from `main`. Branch names: `fix/...`, `feat/...`, `docs/...`, `test/...`, `chore/...`.
2. Keep PRs **small and focused**. One concern per PR.
3. Update or add tests in `tests/Orchestrator.Tests/`.
4. Update [`CHANGELOG.md`](CHANGELOG.md) under `[Unreleased]`.
5. Make sure `dotnet build` and `dotnet test` both pass (CI will verify).
6. Fill in the PR template; reference any related issue.

## Infrastructure changes (`infra/` and `deploy.ps1`)

- All infra is **idempotent** by fingerprint. A change should keep that property.
- Each Bicep module lives in `infra/modules/<resource>.bicep` and is invoked from `deploy.ps1` via `Deploy-Module`.
- Don't bake secrets into Bicep parameters. Use Managed Identity + Key Vault references where strictly necessary.
- Test `deploy.ps1` from a clean RG (`-Reset`) AND as a re-run (idempotency) before sending the PR.

## Local catalog data

Catalog PDFs live OUTSIDE the repo (`C:\Bath Fittings Data\<brand>` on Windows). `deploy.ps1` copies them into `data/catalogs/` and uploads them to blob. **Never commit catalog PDFs** - `.gitignore` already excludes `data/` from tracking; please don't override it.

## Commit messages

Conventional Commits style is preferred:

```
feat(orchestrator): add per-brand search top-N override
fix(webui): proxy catalog page through Web.Ui to avoid APIM 401
docs(architecture): describe MAI vs Foundry IQ separation
test(orchestrator): cover hallucinated-id drop in re-ranker
```

## Code of Conduct

Participation in this project is governed by the [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Questions?

See [`SUPPORT.md`](SUPPORT.md) for where to ask.
