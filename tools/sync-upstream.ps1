<#
.SYNOPSIS
    Sync the CASTABOT fork with upstream and rebuild the branded branch.

.DESCRIPTION
    Three steps, in order, and the order matters:

      1. main is fast-forwarded to upstream/main. It is a mirror and is never
         committed to, so --ff-only is the whole correctness argument.
      2. rebrand/CASTABOT is REBUILT from main rather than merged into. This is
         what makes the fork conflict-free: there is no merge, so there is
         nothing to conflict. The previous branded tip is replaced.
      3. The overlay is applied and gated before anything is pushed.

    brand-tooling is the single source of truth for branding/ and tools/.

.PARAMETER DryRun
    Report what would happen without fetching, rebuilding or pushing.

.PARAMETER SkipPush
    Do everything locally, but do not push.

.EXAMPLE
    ./tools/sync-upstream.ps1
    ./tools/sync-upstream.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipPush
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Upstream = 'upstream'
$Mirror = 'main'
$Branded = 'rebrand/CASTABOT'
$Tooling = 'brand-tooling'

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    & git -C $RepoRoot @Args
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Args -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

Push-Location $RepoRoot
try {
    Write-Step 'Checking branch roles'
    Invoke-Git config rerere.enabled true | Out-Null
    Invoke-Git config rerere.autoupdate true | Out-Null
    $expected = "+refs/heads/main:refs/remotes/$Upstream/main"
    $actual = (& git -C $RepoRoot config --get "remote.$Upstream.fetch")
    if ($actual -ne $expected) {
        throw "remote.$Upstream.fetch is '$actual', expected '$expected'. Upstream has 2000+ branches; a wide refspec is a footgun."
    }

    if ($DryRun) {
        Write-Step 'Dry run'
        Write-Host "Would: fetch $Upstream main; ff-merge into $Mirror;"
        Write-Host "       rebuild $Branded from $Mirror; apply branding; push."
        exit 0
    }

    Write-Step "Step 1/3  Fast-forwarding $Mirror from $Upstream/main"
    Invoke-Git checkout $Mirror
    Invoke-Git fetch $Upstream main
    Invoke-Git merge --ff-only "$Upstream/main"

    Write-Step "Step 2/3  Rebuilding $Branded from $Mirror"
    Invoke-Git checkout -B $Branded $Mirror
    Invoke-Git checkout $Tooling -- branding tools

    Write-Step 'Step 3/3  Applying the branding overlay'
    Invoke-Git status --short
    & python (Join-Path $RepoRoot 'branding/apply.py') --apply
    if ($LASTEXITCODE -ne 0) { throw "branding/apply.py --apply failed" }

    Write-Step 'Gate 1  Overlay is idempotent and templates are installed'
    & python (Join-Path $RepoRoot 'branding/apply.py') --check
    if ($LASTEXITCODE -ne 0) { throw 'branding/apply.py --check failed' }

    Write-Step 'Gate 2  Touched Python files still compile'
    $pys = & git -C $RepoRoot diff --name-only -- '*.py'
    if ($pys) {
        $checker = @'
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
'@
        $checkerPath = Join-Path ([System.IO.Path]::GetTempPath()) 'castabot_compile_check.py'
        Set-Content -LiteralPath $checkerPath -Value $checker -Encoding ascii
        & python $checkerPath @pys
        if ($LASTEXITCODE -ne 0) { throw 'a branded Python file no longer compiles' }
        Write-Host "  $($pys.Count) file(s) compile"
    }

    Write-Step 'Gate 3  Nothing protected was modified'
    $protected = @(
        'LICENSE', 'SECURITY.md', 'SECURITY.es.md', 'pyproject.toml', 'uv.lock',
        'package-lock.json', '.github', 'apps/desktop/product-identity.cjs',
        'apps/desktop/electron-builder.config.cjs'
    )
    $args = @('diff', '--name-only', '--') + $protected
    $leaked = & git -C $RepoRoot @args
    if ($leaked) {
        # LICENSE legitimately gains an appended notice; everything else must be pristine.
        $unexpected = $leaked | Where-Object { $_ -ne 'LICENSE' }
        if ($unexpected) {
            throw "protected files were modified: $($unexpected -join ', ')"
        }
        Write-Host '  LICENSE changed only by the appended notice (expected)'
    } else {
        Write-Host '  no protected file modified'
    }

    $sha = (& git -C $RepoRoot rev-parse --short "$Upstream/main")
    $tag = "upstream-sync/$(Get-Date -Format yyyyMMdd)"
    Write-Step "Committing and tagging ($tag @ $sha)"
    Invoke-Git add -A
    Invoke-Git commit -m "brand: CASTABOT overlay on upstream $sha"
    Invoke-Git tag -f $tag

    if ($SkipPush) {
        Write-Step 'Done (--SkipPush: not pushing)'
        exit 0
    }

    Write-Step 'Pushing'
    Invoke-Git push origin $Mirror
    Invoke-Git push --force-with-lease origin $Branded
    Invoke-Git push origin $Tooling
    Invoke-Git push origin "refs/tags/$tag"

    Write-Step "Done. $Branded rebuilt on upstream $sha and pushed."
}
finally {
    Pop-Location
}
