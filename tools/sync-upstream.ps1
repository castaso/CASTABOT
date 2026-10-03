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

    brand-tooling is the single source of truth for branding/ and tools/ --
    including this script. Step 2 checks it out over the working tree, so edit
    tooling on brand-tooling and COMMIT it before running a sync.

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

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# git and python both write progress to stderr. Under $ErrorActionPreference='Stop'
# PowerShell raises a terminating NativeCommandError before $LASTEXITCODE is ever
# consulted, so a successful `git checkout` would abort the run. Native commands
# therefore run under 'Continue' and are gated on the exit code instead.
#
# The parameter is $NativeArgs, not $Args: $args is an automatic variable and
# binding to it silently swallows the caller's arguments.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$NativeArgs = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $File @NativeArgs
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) {
        throw "$File $($NativeArgs -join ' ') failed with exit code $code"
    }
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NativeArgs)
    Invoke-Native -File 'git' -NativeArgs (@('-C', $RepoRoot) + $NativeArgs)
}

# Two PowerShell traps live here, and both present as git exiting 128:
#
#  1. A bare `--` is consumed by the parser as its own end-of-parameters marker, so
#     git never receives it.
#  2. Passing an array into a [string[]] parameter that also declares
#     ValueFromRemainingArguments is ambiguous -- the array can bind as one
#     argument instead of splatting, and git then gets a single bogus pathspec.
#
# This takes the pathspec list as its own named parameter so it always arrives as
# separate arguments, and uses no bare `--`.
function Invoke-GitPaths {
    param(
        [Parameter(Mandatory = $true)][string[]]$GitArgs,
        [Parameter(Mandatory = $true)][string[]]$Paths
    )
    Invoke-Native -File 'git' -NativeArgs (@('-C', $RepoRoot) + $GitArgs + $Paths)
}

function Invoke-Apply {
    param([Parameter(Mandatory = $true)][string[]]$ApplyArgs)
    Invoke-Native -File 'python' -NativeArgs (@((Join-Path $RepoRoot 'branding/apply.py')) + $ApplyArgs)
}

# main, rebrand/CASTABOT and brand-tooling are all GENERATED. Nothing hand-written
# belongs on them, so a dirty tree there is leftover from an interrupted run and is
# safe to discard -- and must be, because a dirty tree makes `git merge --ff-only`
# fail outright. Any other branch is a developer's work and is never touched.
function Reset-GeneratedTree {
    $current = (Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -First 1).Trim()
    $dirty = @(Invoke-Git status --porcelain)
    if ($dirty.Count -eq 0) {
        return
    }
    if (@($Mirror, $Branded, $Tooling) -notcontains $current) {
        throw "on '$current' with $($dirty.Count) uncommitted change(s); commit or stash them before syncing"
    }
    Write-Step "Discarding $($dirty.Count) leftover change(s) on generated branch '$current'"
    Invoke-Git reset --hard HEAD
    # -x is deliberately NOT passed: .git/info/exclude holds the local .planning/
    # directory and it must survive a sync.
    Invoke-Git clean -fd
}

Push-Location $RepoRoot
try {
    Write-Step 'Checking branch roles'
    Invoke-Git config rerere.enabled true | Out-Null
    Invoke-Git config rerere.autoupdate true | Out-Null

    # Upstream has 2000+ branches. A default fetch would create a remote-tracking ref
    # for every one of them; only main is ever synced.
    $expected = "+refs/heads/main:refs/remotes/$Upstream/main"
    $actual = (Invoke-Git config --get "remote.$Upstream.fetch" | Select-Object -First 1)
    if ($actual -ne $expected) {
        throw "remote.$Upstream.fetch is '$actual', expected '$expected'. Upstream has 2000+ branches and a wide refspec is a footgun."
    }

    if ($DryRun) {
        Write-Step 'Dry run'
        Write-Host "Would: fetch $Upstream main; ff-merge into $Mirror;"
        Write-Host "       rebuild $Branded from $Mirror; apply the overlay; gate; push."
        return
    }

    Write-Step "Step 1/3  Fast-forwarding $Mirror from $Upstream/main"
    Reset-GeneratedTree
    Invoke-Git checkout $Mirror
    Invoke-Git fetch $Upstream main
    Invoke-Git merge --ff-only "$Upstream/main"

    Write-Step "Step 2/3  Rebuilding $Branded from $Mirror"
    Invoke-Git checkout -B $Branded $Mirror
    # checkout -B carries the working tree along, so without this the rebuild would
    # inherit whatever was dirty and would not actually be "main + overlay".
    Invoke-Git reset --hard HEAD
    Invoke-Git checkout $Tooling -- branding tools

    Write-Step 'Step 3/3  Applying the branding overlay'
    Invoke-Apply -ApplyArgs @('--apply')

    Write-Step 'Gate 1  Overlay is idempotent and templates are installed'
    Invoke-Apply -ApplyArgs @('--check')

    Write-Step 'Gate 2  Touched Python files still compile'
    $pys = @(Invoke-GitPaths -GitArgs @('diff', '--name-only') -Paths @('*.py'))
    if ($pys.Count -gt 0) {
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
        Invoke-Native -File 'python' -NativeArgs (@($checkerPath) + $pys)
        Write-Host "  $($pys.Count) file(s) compile"
    }

    Write-Step 'Gate 3  Nothing protected was modified'
    # LICENSE legitimately gains an APPENDED notice; the MIT grant above it must be
    # untouched. Everything else here must be byte-identical to upstream.
    $protectedPaths = @(
        'SECURITY.md', 'SECURITY.es.md', 'pyproject.toml', 'uv.lock',
        'package-lock.json', '.github', 'apps/desktop/product-identity.cjs',
        'apps/desktop/electron-builder.config.cjs'
    )
    $leaked = @(Invoke-GitPaths -GitArgs @('diff', '--name-only') -Paths $protectedPaths)
    if ($leaked.Count -gt 0) {
        throw "protected files were modified: $($leaked -join ', ')"
    }
    Write-Host '  no protected file modified'

    $licenseRemovals = @(Invoke-GitPaths -GitArgs @('diff', '--unified=0') -Paths @('LICENSE') |
        Where-Object { $_ -match '^-[^-]' })
    if ($licenseRemovals.Count -gt 0) {
        throw "LICENSE has removed lines; the append must be additive only:`n$($licenseRemovals -join "`n")"
    }
    Write-Host '  LICENSE is append-only (MIT grant intact)'

    $sha = (Invoke-Git rev-parse --short "$Upstream/main" | Select-Object -First 1)
    $tag = "upstream-sync/$(Get-Date -Format yyyyMMdd)"

    Write-Step "Committing and tagging ($tag @ $sha)"
    Invoke-Git add -A
    Invoke-Git commit -m "brand: CASTABOT overlay on upstream $sha"
    Invoke-Git tag -f $tag

    if ($SkipPush) {
        Write-Step 'Done (--SkipPush: nothing pushed)'
        return
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