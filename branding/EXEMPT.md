# EXEMPT — brand references deliberately left as-is

Every entry here is a place where "Hermes" or "Nous Research" still appears in the
CASTABOT tree. Each is intentional. Do not "fix" one without reading its row.

## Protected by rule

| Reference | Where | Why it stays |
|---|---|---|
| `Copyright (c) 2025 Nous Research` | `LICENSE` | MIT requires the original notice. `LICENSE` is excluded from every rule set; the rebrand notice is appended *below* the grant. |
| `Copyright … Nous Research` in vendored sources | third-party Apache headers | Not ours to rebrand. Caught by a regex protect entry. |
| `security@nousresearch.com`, upstream advisory URL | `SECURITY.md`, `AGENTS.md` | The correct destination for a vulnerability report. `SECURITY.md` is excluded from all rules; the README and NOTICE say the same. |
| `NousResearch/Hermes-3-*`, `NousResearch/Hermes-4-*` | docs, provider catalogs | Hugging Face model repo ids belonging to Nous. A `Hermes <digit>` guard also keeps these intact in prose. |
| `NousResearch.HermesBundled_*`, `NousResearch.HermesChannel*` | Windows bootstrap installer | Functional installer staging paths. Rewriting them breaks staging. |
| `@NousResearch/hermes-agent-core` | `.github/CODEOWNERS` | Upstream team handle. `.github/` is excluded wholesale. |
| `https://hermes-agent.nousresearch.com/install.sh` / `.ps1` | docs, `README*` | Nous owns that host and it is the supported installer. A fork cannot serve it from GitHub Pages. |
| `https://portal.nousresearch.com` | docs, provider UI | A live third-party service, not branding. |
| `inference-api.nousresearch.com`, `welcome-api.nousresearch.com` | Python, config | Live API base URLs. A rewrite here breaks every model call. |
| `HTTP-Referer: https://hermes-agent.nousresearch.com` | provider adapters | A provider header contract. Left exactly as upstream sends it. |
| `org: "Nous Research"` / `displayName: 'Nous Research'` | i18n catalogs, test fixtures | Labels the **Nous Portal provider**, a third party. Branding it "CastaSo" would misrepresent someone else's service. |
| `github.com/NousResearch/hermes-agent` | `.github/**` | Workflows key on the upstream repository name and its secrets. |

## Preserved by design

| Reference | Where | Why it stays |
|---|---|---|
| `hermes` command, `hermes_cli/` | everywhere | Renaming the executable breaks every script, alias and habit. |
| `HERMES_*` env vars | everywhere | Renaming silently ignores existing user configuration. |
| `~/.hermes`, `HERMES_HOME` | everywhere | Renaming orphans existing profiles, sessions and credentials. |
| `hermes_state.py`, `hermes_constants.py`, … | module names | Import-graph rewrite, no user-visible benefit. |
| `hermes-agent` in `package.json` / `pyproject.toml` `name` | root manifests | Renaming desyncs `package-lock.json` / `uv.lock` and breaks `npm ci` / `uv sync`. |
| `appId`, `msixAppIdWithOrg`, publisher/signer | `apps/desktop/product-identity.cjs`, `electron-builder.config.cjs` | Release-engineering state. Rebranding requires our own signed builds and a Partner Center account. |
| `Hermes.app`, `/Applications/Hermes` | `apps/desktop/electron/app-icon.ts` tests | Fixtures for bundle-path detection. Must match the packaging identity above. |
| `hermes` in `@hermes/ink`, `@hermes/shared` | `ui-tui` imports | npm workspace scope names. |
| ASCII banner glyph art | `ui-tui/src/banner.ts` | Block-drawing art, not text. Unchanged until a new vector master exists. |

## Known cosmetic leftovers

| Reference | Where | Note |
|---|---|---|
| `Nous%20Research` shields badge label | `README.es.md`, `README.zh-CN.md`, `README.ur-pk.md` | Rewritten. The *translated* READMEs are otherwise upstream's text, left untranslated by decision. Upstream's README is replaced wholesale by `branding/templates/README.castabot.md`. |
| `Hermes` standalone in code comments and docstrings | `.py`, `.ts`, `*.test.ts` | Comments only, never user-visible. Renaming them would inflate the diff against upstream for no benefit. |
| Raster brand assets | `assets/*.png`, `website/static/img/*`, `apps/desktop/assets/**` | Still upstream's pixels. Vector masters and brand components are rebranded; rasters need new source artwork. |

## When you add an exemption

Add it to `brand-map.json` (`protect` for a literal, `{"pattern": …}` for a
shape), or to a rule set's `exclude` for a whole file. Then add a row here
explaining why — an unexplained exemption is indistinguishable from an oversight,
and the next person will "fix" it.
