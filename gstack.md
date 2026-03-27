# gstack in This Repo

This project has `gstack` installed for Codex at:

- `.agents/skills/gstack`
- generated Codex skills: `.agents/skills/gstack-*`

## What is installed

Common skills available in this repo include:

- `gstack-office-hours`
- `gstack-plan-ceo-review`
- `gstack-plan-eng-review`
- `gstack-plan-design-review`
- `gstack-review`
- `gstack-qa`
- `gstack-browse`
- `gstack-ship`
- `gstack-retro`
- `gstack-cso`

## Notes

- The setup was run in repo-local Codex mode with `./setup --host codex`.
- The built browser binary is at `.agents/skills/gstack/browse/dist/browse.exe`.
- Regenerated skill docs live under `.agents/skills/gstack-*`.

## Rebuild or upgrade

From the repo root:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' -lc 'cd /d/project2026/bashclaw/.agents/skills/gstack && ./setup --host codex'
```

If you upgrade the vendored `gstack` source, rerun the same command to rebuild binaries and regenerate Codex skills.

## Quick usage ideas

- Use `gstack-office-hours` when scoping a feature from scratch.
- Use `gstack-plan-eng-review` before implementation when architecture matters.
- Use `gstack-review` for bug/risk-focused code review.
- Use `gstack-qa` or `gstack-browse` for browser-driven verification flows.
- Use `gstack-ship` after changes are ready to package and validate release steps.
