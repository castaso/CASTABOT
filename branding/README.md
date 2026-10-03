# `branding/` — the CASTABOT overlay

`rebrand/CASTABOT` is **generated output**. Nothing in it is hand-edited, because
a rebrand that is maintained by hand is a rebrand that accumulates merge
conflicts. Everything here exists to make the branded tree a pure function of
the upstream tree.

```
main              = upstream mirror, byte-for-byte, never committed to
rebrand/CASTABOT  = main + overlay, rebuilt from scratch on every sync
brand-tooling     = main + branding/ + tools/  (this is the source of truth)
```

Run `tools/sync-upstream.ps1` (or `.sh`) to sync and rebuild. `apply.py` on its
own just stamps the tree.

## Files

| Path | Role |
|---|---|
| `brand-map.json` | The authoritative list of substitutions, protects and templates. **Edit this, not the tree.** |
| `apply.py` | Applies the map. `--apply`, `--check`, `--report`, `--list-changed`, `--changed-py`. |
| `templates/README.castabot.md` | Installed verbatim as `README.md` |
| `templates/NOTICE` | Installed verbatim as `NOTICE` |
| `templates/LICENSE.append.md` | **Appended** to `LICENSE`; the MIT grant above it is never touched |
| `EXEMPT.md` | Known references that are deliberately left as-is, and why |

## One-time remote setup

GitHub exposes the **entire fork network** through the fork's ref namespace:
`git ls-remote origin` on this fork returns upstream's 2,300+ branches alongside our
three. A default fetch materialises all of them, and the first clone of this repo
took 13 minutes because of it. Pin both remotes:

```bash
git config --unset-all remote.origin.fetch
git config --add remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git config --add remote.origin.fetch '+refs/heads/brand-tooling:refs/remotes/origin/brand-tooling'
git config --add remote.origin.fetch '+refs/heads/rebrand/CASTABOT:refs/remotes/origin/rebrand/CASTABOT'

git config --unset-all remote.upstream.fetch
git config --add remote.upstream.fetch '+refs/heads/main:refs/remotes/upstream/main'
```

`sync-upstream.ps1` / `.sh` repair both automatically, so a fresh clone only needs
this once.

## Why rebuild instead of merge

A merge-based fork has to resolve conflicts every time upstream edits a line you
also edited. `README.md`, `package.json` and `LICENSE` are among the most
frequently edited files upstream, so they are exactly where that pain lands.

Rebuilding removes the merge from the pipeline entirely: the branded branch is
recreated from `main` and the overlay is re-stamped. The only inputs are the
upstream tree and `brand-map.json`, so the same upstream commit always produces
the same branded tree. `--force-with-lease` replaces the branch tip.

The cost is that the branded branch's history is a series of whole-tree
replacements rather than incremental commits. That is the right trade: an
`upstream-sync/YYYYMMDD` tag records each sync point.

## Changing the brand

Add or reorder rules in `brand-map.json`, then dry-run before applying:

```bash
python branding/apply.py --report --limit 20   # what would change, with before/after
python branding/apply.py --apply
python branding/apply.py --check               # must now be clean
```

Rule sets run in array order, so put the most specific token first.

## The three traps

**1. `nousresearch.com` is not only branding.** A global rewrite turned
`https://inference-api.nousresearch.com/v1` into
`https://inference-api.github.com/castaso/v1`, which is not a URL that resolves —
it silently breaks every model call. The same applies to
`welcome-api.nousresearch.com`, `portal.nousresearch.com`,
`TOOL_GATEWAY_DOMAIN`, and the `HTTP-Referer` header value. URL rewriting is
therefore confined to the `doc_urls` rule set, which only matches Markdown and
the docs site. **Never move a URL rule out of `doc_urls`.**

**2. `NousResearch` without a space is not the vendor.** It is the Hugging Face
org holding the Hermes-3/Hermes-4 model repos
(`NousResearch/Hermes-3-Llama-3.1-70B`), the Windows installer's staging prefix
(`NousResearch.HermesBundled_*`), and GitHub team handles
(`@NousResearch/hermes-agent-core`). Only the spaced `Nous Research` is rewritten.

**3. A copyright notice is not a brand token.** A regex protect entry masks any
`Copyright … Nous Research` line, including vendored third-party Apache headers.
Rewriting one is the single edit that turns a lawful rebrand into a licence
violation. `LICENSE` is also excluded from every rule set, and its rebrand
notice is *appended* below the untouched MIT grant.

## Verification gates

`apply.py --check` is the primary gate and must be clean before pushing. It fails
if any rule could still fire, or if a template-managed file has drifted. The sync
script adds two more:

- every touched `.py` file is `compile()`d — a branding rule cannot produce a
  syntax error, so this proves the rules never touched code structure;
- `LICENSE`, `SECURITY.md`, `pyproject.toml`, the lockfiles, `.github/` and the
  desktop packaging identity are asserted unmodified.

## Adding a file to the branded surface

1. Add its path to a rule set's `include`.
2. Run `--report` and read the before/after for that file.
3. Check it has no paired counterpart elsewhere — a test asserting the string you
   just changed must change too, or the suite goes red. Both sides move together
   when the token is identical, which is why the rules are literal-for-literal.
4. If it is display text, prefer adding it to `brand_code_strings` (curated)
   rather than widening a rule set to an extension. A blanket sweep over `.py`
   eventually hits an identifier or a dict key.

## Requirements

Python 3.13+ (for the glob handling) and git. Standard library only — the
branding pipeline must never depend on the target project's virtualenv, or it
would break exactly when the project is broken.
