<p align="center">
  <strong>CASTABOT</strong>
</p>

# CASTABOT

**An independently branded distribution of [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research.**

CASTABOT is a self-improving AI agent: it learns across sessions, curates its own
memory, writes and refines skills from experience, delegates to subagents, runs
scheduled jobs, and drives a real terminal and browser. Everything you get here
is upstream Hermes Agent with the visible branding changed. The code is
otherwise unmodified.

> **Not affiliated with Nous Research.** CASTABOT is a community fork. See
> [`NOTICE`](./NOTICE) for provenance and [`LICENSE`](./LICENSE) for terms.
> Vulnerabilities in this code should be [reported upstream](https://github.com/NousResearch/hermes-agent/security/advisories/new) —
> see [`SECURITY.md`](./SECURITY.md).

## Why a fork

Upstream [Hermes Agent](https://github.com/nousresearch/hermes-agent) is MIT
licensed and actively developed. CASTABOT exists to carry local branding while
staying continuously mergeable with upstream:

- **`main` is a pristine mirror** of `NousResearch/hermes-agent` — byte-for-byte, no
  local commits, ever. GitHub's *Sync fork* button works on it directly.
- **`rebrand/CASTABOT` is generated**, never merged. It is rebuilt from scratch on
  every sync, which is why an upstream update can never produce a merge conflict.
- Every substitution is declared in one file,
  [`branding/brand-map.json`](./branding/brand-map.json), and applied
  mechanically. Nothing is hand-edited, so a re-sync reproduces the tree exactly.

## What is renamed, and what is deliberately not

Renaming a product's branding is cheap. Renaming its *interface* is a rewrite of
the product. CASTABOT changes only the former.

**Renamed** — everything a person reads: the CLI and TUI banners, the web
dashboard, the desktop app, the documentation site, the Markdown docs, the
translation catalogs, and the display metadata.

**Preserved on purpose:**

| Kept as-is | Why |
|---|---|
| The `hermes` command | Renaming the executable breaks every script, alias and habit people have |
| `HERMES_*` environment variables | Renaming them silently ignores configuration that already exists |
| `~/.hermes` config directory, `HERMES_HOME` | Renaming it orphans existing profiles, sessions and credentials |
| Internal module names (`hermes_state.py`, …) | An import-graph rewrite with no user-visible payoff |
| `package.json` / `pyproject.toml` `name` | Renaming desyncs `package-lock.json` and `uv.lock`, breaking `npm ci` and `uv sync` |
| Desktop packaging identity | `appId`, MSIX identity and the publisher/signing identity are release state, and cannot be rebranded without our own signed builds |
| Upstream inference endpoints | `inference-api.nousresearch.com` and friends are live service contracts |

The full list, with reasons, is in [`NOTICE`](./NOTICE). Practical upshot: a
CASTABOT install and a Hermes Agent install share a config directory, a command
name and a data format, and can be swapped between without migration.

## Install

Use upstream's installer — it is the supported path and this fork does not
republish it:

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

```powershell
iex (irm https://hermes-agent.nousresearch.com/install.ps1)
```

Then start the agent:

```bash
hermes
```

Full installation, gateway and platform guides are in the [documentation
site](https://castaso.github.io/CASTABOT/docs/).

## Keeping in sync with upstream

```bash
git checkout main
git fetch upstream main
git merge --ff-only upstream/main
git push origin main

git checkout -B rebrand/CASTABOT main
git checkout brand-tooling -- branding tools
python branding/apply.py --apply
python branding/apply.py --check      # gates: idempotent, templates in place
git commit -am "brand: CASTABOT overlay"
git push --force-with-lease origin rebrand/CASTABOT
```

`tools/sync-upstream.ps1` (or `.sh`) does all of the above in one command. The
runbook — including how to add a brand token and how the verification gates
work — is in [`branding/README.md`](./branding/README.md).

## Branches

| Branch | Contents |
|---|---|
| `main` | Pristine mirror of `NousResearch/hermes-agent`. Do not commit here. |
| `rebrand/CASTABOT` | Generated overlay. Rebuilt from `main`, force-pushed. |
| `brand-tooling` | `branding/` + `tools/`: the source of truth for the overlay. |

## Contributing

Bug reports and pull requests for the **branded product** belong here. Changes
to the **agent itself** belong [upstream](https://github.com/NousResearch/hermes-agent) —
the fork exists to consume upstream, not to fork the roadmap. If you find a
defect in the agent, please report it upstream so every Hermes user benefits.

Read [`CONTRIBUTING.md`](./CONTRIBUTING.md) (upstream's, unmodified) for the
development workflow, and [`AGENTS.md`](./AGENTS.md) for the architecture and
the rules that govern changes.

## License

MIT. The original copyright and permission notice are retained verbatim; the
appended rebrand notice and [`NOTICE`](./NOTICE) record this fork's
modifications.

Copyright (c) 2025 Nous Research · Modifications copyright (c) 2026 CastaSo
