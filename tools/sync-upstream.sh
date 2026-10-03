#!/usr/bin/env bash
# Sync the CASTABOT fork with upstream and rebuild the branded branch.
#
# Three steps, in order, and the order matters:
#
#   1. main is fast-forwarded to upstream/main. It is a mirror and is never
#      committed to, so --ff-only is the whole correctness argument.
#   2. rebrand/CASTABOT is REBUILT from main rather than merged into. This is
#      what makes the fork conflict-free: there is no merge, so there is nothing
#      to conflict. The previous branded tip is replaced.
#   3. The overlay is applied and gated before anything is pushed.
#
# brand-tooling is the single source of truth for branding/ and tools/ --
# including this script. Step 2 checks it out over the working tree, so edit
# tooling on brand-tooling and COMMIT it before running a sync.
#
# Usage: tools/sync-upstream.sh [--dry-run] [--skip-push]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM=upstream
MIRROR=main
BRANDED=rebrand/CASTABOT
TOOLING=brand-tooling

DRY_RUN=0
SKIP_PUSH=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-push) SKIP_PUSH=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

git_at() { git -C "$REPO_ROOT" "$@"; }

step() { printf '\n==> %s\n' "$1"; }

cd "$REPO_ROOT"

step 'Checking branch roles'
git_at config rerere.enabled true
git_at config rerere.autoupdate true

# Upstream has 2000+ branches; a default fetch would create a remote-tracking ref
# for each. Only main is ever synced.
expected="+refs/heads/main:refs/remotes/$UPSTREAM/main"
actual="$(git_at config --get "remote.$UPSTREAM.fetch" || true)"
if [ "$actual" != "$expected" ]; then
  echo "remote.$UPSTREAM.fetch is '$actual', expected '$expected'." >&2
  echo "Upstream has 2000+ branches; a wide refspec is a footgun." >&2
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  step 'Dry run'
  echo "Would: fetch $UPSTREAM main; ff-merge into $MIRROR;"
  echo "       rebuild $BRANDED from $MIRROR; apply the overlay; gate; push."
  exit 0
fi

step "Step 1/3  Fast-forwarding $MIRROR from $UPSTREAM/main"

# main, rebrand/CASTABOT and brand-tooling are all GENERATED. A dirty tree there is
# leftover from an interrupted run, and it makes `git merge --ff-only` fail outright,
# so it is discarded. Any other branch is a developer's work and is never touched.
current="$(git_at rev-parse --abbrev-ref HEAD)"
dirty="$(git_at status --porcelain || true)"
if [ -n "$dirty" ]; then
  case "$current" in
    "$MIRROR"|"$BRANDED"|"$TOOLING")
      step "Discarding leftover changes on generated branch '$current'"
      git_at reset --hard HEAD
      # no -x: .git/info/exclude holds the local .planning/ directory
      git_at clean -fd
      ;;
    *)
      echo "on '$current' with uncommitted changes; commit or stash before syncing" >&2
      exit 1
      ;;
  esac
fi

git_at checkout "$MIRROR"
git_at fetch "$UPSTREAM" main
git_at merge --ff-only "$UPSTREAM/main"

step "Step 2/3  Rebuilding $BRANDED from $MIRROR"
git_at checkout -B "$BRANDED" "$MIRROR"
# checkout -B carries the working tree along; without this the rebuild would inherit
# whatever was dirty and would not actually be "main + overlay".
git_at reset --hard HEAD
git_at checkout "$TOOLING" -- branding tools

step 'Step 3/3  Applying the branding overlay'
python3 branding/apply.py --apply

step 'Gate 1  Overlay is idempotent and templates are installed'
python3 branding/apply.py --check

step 'Gate 2  Touched Python files still compile'
mapfile -t pys < <(git_at diff --name-only -- '*.py')
if [ "${#pys[@]}" -gt 0 ]; then
  python3 - "${pys[@]}" <<'PY'
import sys
bad = []
for f in sys.argv[1:]:
    try:
        compile(open(f, encoding="utf-8").read(), f, "exec")
    except Exception as exc:
        bad.append((f, exc))
for f, exc in bad:
    print("FAIL", f, exc)
sys.exit(1 if bad else 0)
PY
  echo "  ${#pys[@]} file(s) compile"
fi

step 'Gate 3  Nothing protected was modified'
# LICENSE legitimately gains an APPENDED notice; the MIT grant above it must be
# untouched. Everything else on this list must be byte-identical to upstream.
leaked="$(git_at diff --name-only -- SECURITY.md SECURITY.es.md pyproject.toml uv.lock package-lock.json .github apps/desktop/product-identity.cjs apps/desktop/electron-builder.config.cjs || true)"
if [ -n "$leaked" ]; then
  echo "protected files were modified: $leaked" >&2
  exit 1
fi
echo '  no protected file modified'

if git_at diff --unified=0 -- LICENSE | grep -q '^-[^-]'; then
  echo 'LICENSE has removed lines; the append must be additive only' >&2
  git_at diff --unified=0 -- LICENSE | grep '^-[^-]' >&2
  exit 1
fi
echo '  LICENSE is append-only (MIT grant intact)'

sha="$(git_at rev-parse --short "$UPSTREAM/main")"
tag="upstream-sync/$(date +%Y%m%d)"

step "Committing and tagging ($tag @ $sha)"
git_at add -A
git_at commit -m "brand: CASTABOT overlay on upstream $sha"
git_at tag -f "$tag"

if [ "$SKIP_PUSH" -eq 1 ]; then
  step 'Done (--skip-push: nothing pushed)'
  exit 0
fi

step 'Pushing'
git_at push origin "$MIRROR"
git_at push --force-with-lease origin "$BRANDED"
git_at push origin "$TOOLING"
git_at push origin "refs/tags/$tag"

step "Done. $BRANDED rebuilt on upstream $sha and pushed."