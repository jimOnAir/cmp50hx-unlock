# AGENTS.md

## Agent skills

### Issue tracker

Local markdown under `.scratch/<feature-slug>/issues/` — this repo's `origin` is a third-party public upstream; never publish there without explicit approval. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), recorded as a `Status:` line per issue file. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` + `docs/adr/` at the repo root (created lazily by `/domain-modeling`). See `docs/agents/domain.md`.
