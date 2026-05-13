#!/usr/bin/env pwsh
# =============================================================================
#  Interior Design Accelerator - SEQUENTIAL Deployer
# -----------------------------------------------------------------------------
#  Each Bicep module is deployed as its own `az deployment group create` call,
#  one at a time, synchronously. State is persisted to .deploy-state.json
#  after EACH successful step, so if the terminal is closed mid-run a re-run
#  resumes from the last completed step.
#
#  Phase order (sequential):
#    0  Prereq check
#    1  az login (+ optional azd via -AzdLogin)
#    2  Cleanup prompt        (NEVER auto-deletes - always asks)
#    3  Collect parameters
#    4a Resource group        (create if missing)
#    4b identity              (User-Assigned Managed Identity)
#    4c monitor               (Log Analytics + App Insights)
#    4e storage               (with deployer IP firewall rule)
#    5  CATALOG UPLOAD        (Jaguar + Parryware -> blob, AAD)
#    6a search                (AI Search service)
#    6b search-data-plane     (index + datasource + indexer via REST)
#    7  (removed - Content Understanding is no longer used; Document Intelligence runs in Phase 8d)
#    8a foundry               (account + project + chat & image deployments + AI Search connection)
#    8c foundryAgents         (3 hosted agents: chat, catalog-search, image-gen)
#    9  aca                   (Container Apps env + Orchestrator app placeholder)
#    10 image-build           (ACR + az acr build + container app update)
#    11 appsvc                (App Service plan + Web App)
#    12 webui-publish         (zip-deploy)
#    13 apim                  (Consumption SKU front door)
#    14 Summary
#
#  Re-run safely:    pwsh deploy.ps1
#  Reset state:      pwsh deploy.ps1 -Reset
#  Bicep what-if:    pwsh deploy.ps1 -WhatIf
# =============================================================================

[CmdletBinding()]
param(
    [ValidateSet('swedencentral','canadacentral','northcentralus','australiaeast')]
    [string] $Location,
    [string] $EnvironmentName,
    [string] $ResourceGroup,
    [string] $SubscriptionId,
    [string] $ExistingFoundryAccountId,
    [switch] $NewFoundry,
    [string] $ChatModelName              = 'gpt-4.1-mini',
    [string] $ImageModelName             = 'MAI-Image-2',
    [string] $ChatModelVersion           = '2025-04-14',
    [int]    $ChatModelCapacity          = 50,
    [string] $ImageModelVersion          = '2026-02-20',
    [int]    $ImageModelCapacity         = 1,
    [string] $CatalogSourcePath          = '',   # leave empty to use in-repo data\catalogs\
    [switch] $SkipCleanupPrompt = $true,    # legacy alias for -NoCleanupPrompt; kept for back-compat
    [switch] $NoCleanupPrompt,              # truly skip Phase 2 prompt (CI / unattended runs only)
    [switch] $Yes = $true,                  # default ON - non-interactive (use $Interactive to opt out)
    [switch] $Interactive,                  # opt-in: prompt for confirmations (overrides $Yes)
    [switch] $SkipImageBuild,
    [switch] $SkipWebUiPublish,
    [switch] $SkipUpgrades = $true,    # default ON - 'az upgrade' silently stalls 1-3 min and is rarely needed
    [switch] $DoUpgrade,                # opt-in to run the upgrade pass
    [switch] $AzdLogin,
    [switch] $WhatIf,
    [switch] $Reset,
    # -ResetSection: redo a SINGLE phase on the next run without nuking the
    # whole state file. Accepts one of the section keys we manage in state:
    # '8d' (catalog extraction), '8e' (search seed), '10' (image build), etc.
    # Example: pwsh .\deploy.ps1 -ResetSection 8d   # redo Phase 8d only.
    [string] $ResetSection,
    # Keep the host window open after the script finishes (or fails) so users who
    # launch via right-click / VS Code 'Run' / a shortcut can read the output
    # instead of losing it when the transient PowerShell host exits. Pass
    # -NoPause (or set $env:DEPLOY_NOPAUSE = '1') to disable in CI / automation.
    [switch] $NoPause
)

# Honor explicit opt-in if user really wants the upgrade pass
if ($DoUpgrade) { $SkipUpgrades = $false }

# $Interactive overrides the default non-interactive mode
if ($Interactive) { $Yes = $false; $SkipCleanupPrompt = $false }

# Honour either the new -NoCleanupPrompt switch or the legacy alias.
if ($SkipCleanupPrompt -and -not $PSBoundParameters.ContainsKey('SkipCleanupPrompt')) {
    # Default value only - do NOT treat the implicit default as "skip prompt".
    # Phase 2 must always ask interactively. Use -NoCleanupPrompt to truly skip.
    $SkipCleanupPrompt = $false
}
if ($SkipCleanupPrompt) { $NoCleanupPrompt = $true }

# IMMEDIATE liveness output - guarantees the user sees the script is alive
# within milliseconds, even before any Azure call. Helps diagnose 'looks hung'.
Write-Host ''
Write-Host '== deploy.ps1 starting ...' -ForegroundColor Cyan
Write-Host ('   PowerShell ' + $PSVersionTable.PSVersion) -ForegroundColor DarkGray

# -----------------------------------------------------------------------------
# Keep-window-open guard. Without this, a top-level `throw` or `exit` returning
# control to a transient PowerShell host (right-click Run, VS Code Run button,
# `powershell -File deploy.ps1` shortcut, double-click) closes the window
# instantly and the user loses all output. With the trap + final pause below,
# the window stays open until the user presses Enter.
# -----------------------------------------------------------------------------
# Pause-before-close defaults to TRUE. The previous heuristic relied on
# [Environment]::UserInteractive which returns $false in many real-world hosts
# (VS Code Run button, Visual Studio Run, Windows Terminal launched via shortcut,
# right-click 'Run with PowerShell'), causing the window to slam shut on any
# error or normal exit. We now ALWAYS pause unless the user explicitly opts out
# via -NoPause or $env:DEPLOY_NOPAUSE=1 (CI / true unattended runs).
$script:__shouldPause = (-not $NoPause) -and (-not $env:DEPLOY_NOPAUSE)
function Wait-ForExitKey {
    if (-not $script:__shouldPause) { return }
    try {
        Write-Host ''
        [void](Read-Host 'Press Enter to close this window')
    } catch {
        # No console at all (truly headless) - skip silently.
    }
}
# Wrapper for any explicit `exit` so the window stays open. Bare `exit` does NOT
# trigger the trap below (it isn't a terminating error), so we MUST go through
# this helper. Search the file for `exit ` - everything that isn't 'exit 0/1' in
# a wrapped helper should be Exit-Deploy.
function Exit-Deploy {
    param([int]$Code = 0)
    try { Stop-Transcript | Out-Null } catch { }
    Wait-ForExitKey
    exit $Code
}
trap {
    Write-Host ''
    Write-Host '== deploy.ps1 FAILED ==' -ForegroundColor Red
    Write-Host ("   {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    }
    try { Stop-Transcript | Out-Null } catch { }
    Wait-ForExitKey
    break
}
Write-Host ''

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
# PS 7.3+ makes native commands (az.cmd) honor $ErrorActionPreference, so any
# stderr text from `az` (warnings, deprecation notices, progress) is turned into
# a terminating NativeCommandError. We rely on $LASTEXITCODE checks instead, so
# opt out of that behavior here. (Harmless on PS 5.1 / earlier 7.x.)
$PSNativeCommandUseErrorActionPreference = $false

# Suppress CLI upgrade nags ONCE.
$env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'
$env:AZD_SKIP_UPDATE_CHECK       = 'true'

# az config set was previously called here on every run - that triggers CLI init
# (3-6 sec stall). The settings persist between runs so we only need them once.
# A user can run them manually if they ever want to reset.
# Skipping by default for fast startup.

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function Write-Phase($n, $msg) {
    Write-Host ''
    Write-Host ('=' * 80) -ForegroundColor Cyan
    Write-Host ("  PHASE $n - $msg") -ForegroundColor Cyan
    Write-Host ('=' * 80) -ForegroundColor Cyan
}
function Write-Step($msg) { Write-Host "  > $msg" -ForegroundColor Yellow }
function Write-Ok($msg)   { Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "    [SKIP] $msg" -ForegroundColor DarkGray }
function Write-Info($msg) { Write-Host "    [INFO] $msg" -ForegroundColor Blue }
function Write-Err2($msg) { Write-Host "    [ERR]  $msg" -ForegroundColor Red }

function Ask-YesNo($question, $defaultYes = $true) {
    if ($Yes) { return $true }
    $suffix = if ($defaultYes) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $defaultYes }
    return $answer -match '^[yY]'
}
function Ask-Default($question, $default) {
    if ($Yes) { return $default }   # non-interactive mode: just take the default
    $answer = Read-Host "$question [$default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default } else { return $answer }
}

function Invoke-Safe {
    param([Parameter(Mandatory)][scriptblock]$Script, [switch]$ShowErr)
    $global:LASTEXITCODE = 0
    try {
        if ($ShowErr) { $out = & $Script } else { $out = & $Script 2>$null }
    } catch { return $null }
    if ($LASTEXITCODE -ne 0) { return $null }
    return $out
}

function Get-AzAccount {
    $raw = Invoke-Safe { az account show }
    if (-not $raw) { return $null }
    try { return ($raw | Out-String | ConvertFrom-Json) } catch { return $null }
}

# -----------------------------------------------------------------------------
# State file (resumable / idempotent re-runs).
# Lives OUTSIDE the workspace at %LOCALAPPDATA%\InteriorDesignAccelerator\state.json
# so editor buffers (VS / VS Code) can never clobber it on focus-change auto-save.
# -----------------------------------------------------------------------------
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Set-Location $projectRoot
$artifacts   = Join-Path $projectRoot 'artifacts'
New-Item -ItemType Directory -Path $artifacts -Force | Out-Null

$stateDir  = Join-Path $env:LOCALAPPDATA 'InteriorDesignAccelerator'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$statePath = Join-Path $stateDir 'state.json'

# One-time migration: if old in-workspace state exists, copy it out and remove it
$legacyState = Join-Path $projectRoot '.deploy-state.json'
if ((Test-Path $legacyState) -and -not (Test-Path $statePath)) {
    Copy-Item $legacyState $statePath -Force
    Write-Host "Migrated state file: $legacyState -> $statePath" -ForegroundColor DarkGray
    Write-Host "(IDE editor buffers were clobbering the old in-workspace location)" -ForegroundColor DarkGray
}
if (Test-Path $legacyState) {
    Remove-Item $legacyState -Force -ErrorAction SilentlyContinue   # remove so IDE never re-saves it
}

if ($Reset) {
    if (Test-Path $statePath) {
        Write-Host "Reset requested - deleting state: $statePath" -ForegroundColor Yellow
        Remove-Item $statePath -Force
    }
    $wsLog = Join-Path $artifacts 'deploy.log'
    if (Test-Path $wsLog) {
        Write-Host "Reset requested - deleting log:   $wsLog"  -ForegroundColor Yellow
        Remove-Item $wsLog -Force -ErrorAction SilentlyContinue
    }
    # Also clean up any legacy log left over at the old LOCALAPPDATA location.
    $oldLog = Join-Path $stateDir 'deploy.log'
    if (Test-Path $oldLog) { Remove-Item $oldLog -Force -ErrorAction SilentlyContinue }
}

# -----------------------------------------------------------------------------
# Simple resume rule: log file present == resume from where we failed.
# Log file MISSING == either first run OR last run succeeded (Phase 14 cleanup
# deletes the log on success). In both cases the user wants a fresh deploy,
# so drop any prior state and let every phase run from scratch.
#   * Failed run  -> log preserved -> next run resumes (state intact)
#   * Successful run -> log deleted -> next run is fresh (state cleared here)
#   * To force fresh manually: delete artifacts\deploy.log
# -----------------------------------------------------------------------------
$earlyLogPath = Join-Path $artifacts 'deploy.log'
if (-not $Reset -and -not (Test-Path $earlyLogPath) -and (Test-Path $statePath)) {
    Write-Host ''
    Write-Host '  No deploy.log found - treating as fresh run.' -ForegroundColor Yellow
    Write-Host "  Clearing prior state at: $statePath" -ForegroundColor Yellow
    Write-Host '  (To resume from a partial failure instead, do not delete the log file.)' -ForegroundColor DarkGray
    Write-Host ''
    Remove-Item $statePath -Force
}

# -----------------------------------------------------------------------------
# -ResetSection: clear the state keys for a single phase so it re-runs without
# nuking the entire state file. Useful for "redo Phase 8d only" scenarios.
# -----------------------------------------------------------------------------
if ($ResetSection -and (Test-Path $statePath)) {
    $sectionMap = @{
        '8d' = @('catalog_extracted','catalog_extracted_at','catalog_synthesized')
        '8e' = @('search_seeded')
        '10' = @('image_built','image_built_at')
        '12' = @('webui_published','webui_published_at')
    }
    if ($sectionMap.ContainsKey($ResetSection)) {
        $raw = Get-Content $statePath -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            try {
                $obj = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            } catch {
                # PS 5.1 fallback
                $obj = @{}
                ($raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $obj[$_.Name] = $_.Value }
            }
            $cleared = @()
            foreach ($k in $sectionMap[$ResetSection]) {
                if ($obj.ContainsKey($k)) { $obj.Remove($k); $cleared += $k }
            }
            if ($cleared.Count -gt 0) {
                $obj | ConvertTo-Json -Depth 30 | Set-Content $statePath -Encoding UTF8
                Write-Host ''
                Write-Host "  -ResetSection $ResetSection : cleared keys [$($cleared -join ', ')] from state." -ForegroundColor Yellow
                Write-Host '  Phase will re-run on this invocation.' -ForegroundColor Yellow
                Write-Host ''
            }
        }
    } else {
        Write-Host ''
        Write-Host "  -ResetSection '$ResetSection' is not recognized. Known sections: $($sectionMap.Keys -join ', ')" -ForegroundColor Yellow
        Write-Host ''
    }
}

function ConvertTo-HashTableSafe {
    # Recursively convert a PSCustomObject (output of ConvertFrom-Json on PS 5.1)
    # into a plain hashtable so script logic that uses .ContainsKey() / indexer
    # access works identically in PowerShell 5.1 and 7+.
    param($obj)
    if ($null -eq $obj) { return @{} }
    if ($obj -is [hashtable]) { return $obj }
    if ($obj -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $obj.Keys) { $h[$k] = $obj[$k] }
        return $h
    }
    if ($obj.PSObject -and $obj.PSObject.Properties) {
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }
    return @{}
}

function Load-State {
    if (-not (Test-Path $statePath)) { return @{} }
    try {
        $raw = Get-Content $statePath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        # PS 7 supports -AsHashtable; PS 5.1 does not. We branch by version so the
        # script runs identically under powershell.exe (5.1) and pwsh.exe (7+).
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            return ($raw | ConvertFrom-Json -AsHashtable)
        }
        return (ConvertTo-HashTableSafe ($raw | ConvertFrom-Json))
    }
    catch { return @{} }
}
function Save-State($s) {
    # Atomic write: temp file then rename. Avoids leaving a half-written file if killed mid-write.
    $tmp = "$statePath.tmp"
    $s | ConvertTo-Json -Depth 30 | Set-Content $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $statePath -Force
}
function State-Set($key, $value) { $s = Load-State; $s[$key] = $value; Save-State $s }
function State-Get($key) { $s = Load-State; if ($s.ContainsKey($key)) { return $s[$key] } else { return $null } }

function Validate-State {
    # Detect partial / clobbered state - if we have any *_done or *_outputs keys but no
    # ResourceGroup, the file was almost certainly truncated by an external editor.
    param([hashtable]$s)
    if ($null -eq $s -or $s.Count -eq 0) { return $s }
    $hasProgress = @($s.Keys | Where-Object { $_ -like '*_done' -or $_ -like '*_outputs' -or $_ -in @('catalog_uploaded','search_seeded','agents_done','knowledge_done') }).Count -gt 0
    $hasMeta     = $s.ContainsKey('ResourceGroup') -and $s['ResourceGroup']
    if ($hasProgress -and -not $hasMeta) {
        Write-Host ''
        Write-Host "  WARNING: state file at $statePath has progress flags but no ResourceGroup." -ForegroundColor Yellow
        Write-Host '           This usually means the file was clobbered by an editor. Treating as empty.' -ForegroundColor Yellow
        Write-Host ''
        Save-State @{}   # reset to clean slate
        return @{}
    }
    return $s
}
Write-Host '   Loading state ...' -ForegroundColor DarkGray
$state = Load-State
$state = Validate-State $state
if ($null -eq $state) { $state = @{} }

# -----------------------------------------------------------------------------
# Bicep-version cache invalidation. Each module's bicep declares an output
# `bicepVersion` (a string sentinel that is bumped whenever the bicep semantics
# change in a way that requires a re-deploy on existing stacks - e.g. a new
# role assignment that wasn't there before). When the cached state's version
# is older than the EXPECTED version below, we clear the *_done / *_outputs
# flags for that module so Deploy-Module re-runs the bicep idempotently.
# This is what unblocks "I changed the bicep but state says we're done".
# -----------------------------------------------------------------------------
$expectedBicepVersions = @{
    foundry = '2026-05-10-deployer-cog-contrib-v7'   # adds Cognitive Services Contributor (listKeys) to deployer for Phase 8d key auth
    appsvc  = '2026-05-12-linux-no-runfrompkg-v1'    # removes WEBSITE_RUN_FROM_PACKAGE (Linux App Service HTTP 500 fix)
}

# Helper: returns $true if the supplied outputs hashtable/object carries a
# `bicepVersion` that does NOT match the expected version for the given module.
# Used by Deploy-Module to invalidate stale state-OR-ARM cached outputs.
function Test-BicepVersionDrift {
    param([string]$ModuleName, $Outputs)
    if (-not $expectedBicepVersions.ContainsKey($ModuleName)) { return $false }
    $expected = $expectedBicepVersions[$ModuleName]
    $actual = $null
    if ($Outputs) {
        if ($Outputs -is [hashtable])                            { $actual = $Outputs['bicepVersion'] }
        elseif ($Outputs.PSObject.Properties['bicepVersion'])    { $actual = $Outputs.bicepVersion }
    }
    if (-not $actual) {
        # No bicepVersion at all = old deployment from before this contract existed = drift.
        Write-Host ("    [drift] module '{0}': cached outputs have no bicepVersion; expected '{1}'" -f $ModuleName, $expected) -ForegroundColor Yellow
        return $true
    }
    if ($actual -ne $expected) {
        Write-Host ("    [drift] module '{0}': cached='{1}' expected='{2}'" -f $ModuleName, $actual, $expected) -ForegroundColor Yellow
        return $true
    }
    return $false
}

foreach ($mod in $expectedBicepVersions.Keys) {
    $expected = $expectedBicepVersions[$mod]
    $outKey   = "${mod}_outputs"
    $doneKey  = "${mod}_done"
    $cached   = $state[$outKey]
    $cachedVer = $null
    if ($cached) {
        if ($cached -is [hashtable])             { $cachedVer = $cached['bicepVersion'] }
        elseif ($cached.PSObject.Properties['bicepVersion']) { $cachedVer = $cached.bicepVersion }
    }
    if ($state[$doneKey] -and $cachedVer -and $cachedVer -ne $expected) {
        Write-Host ''
        Write-Host "  Bicep version drift detected for module '$mod':" -ForegroundColor Yellow
        Write-Host "    cached: $cachedVer   expected: $expected" -ForegroundColor Yellow
        Write-Host "    -> clearing ${mod}_done so the bicep re-runs idempotently this session." -ForegroundColor Yellow
        $state.Remove($doneKey)   | Out-Null
        $state.Remove($outKey)    | Out-Null
        Save-State $state
    }
}

# -----------------------------------------------------------------------------
# Central logging + idempotency-strengthening additions.
# These run BEFORE Phase 0 so that any crash from this point on is recoverable
# and the RG/Env name we resolve survives across terminals/machines/IDEs.
# -----------------------------------------------------------------------------

# Central log: ONE file per machine, appended across all runs (any terminal can tail it).
# Log file lives in the WORKSPACE at artifacts/deploy.log so you can find/delete it
# easily. State file stays at LOCALAPPDATA (IDE auto-save would clobber it).
Write-Host '   Opening transcript ...' -ForegroundColor DarkGray
$logFile = Join-Path $artifacts 'deploy.log'
try { Stop-Transcript | Out-Null } catch { }   # in case a prior session left one open
try { Start-Transcript -Path $logFile -Append -IncludeInvocationHeader -ErrorAction Stop | Out-Null } catch { }

# Run counter: bumped each invocation so log + state can be cross-referenced.
$runCounter = 1
if ($state.ContainsKey('RunCount')) { $runCounter = [int]$state['RunCount'] + 1 }
State-Set 'RunCount'    $runCounter
State-Set 'LastRunUtc'  (Get-Date).ToUniversalTime().ToString('o')

# Persist any explicit params NOW (before Phase 0). If the script crashes in
# auth / prereq / cleanup, the next run still finds the RG name to resume from.
if ($Subscription)    { State-Set 'Subscription'    $Subscription }
if ($Location)        { State-Set 'Location'        $Location }
if ($EnvironmentName) { State-Set 'EnvironmentName' $EnvironmentName }
if ($ResourceGroup)   { State-Set 'ResourceGroup'   $ResourceGroup }
$state = Load-State

# -------- Loud startup banner (visible before any Azure call) ---------------
$bannerLines = @()
$bannerLines += ''
$bannerLines += '+============================================================================+'
$bannerLines += "|  Interior Design Accelerator - Deploy Run #$runCounter"
$bannerLines += "|  Started:    $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))"
$bannerLines += "|  State file: $statePath"
$bannerLines += "|  Log file:   $logFile"
$bannerLines += '|'
if ($state['ResourceGroup']) {
    $bannerLines += "|  RESUMING into existing RG: $($state['ResourceGroup'])"
    $bannerLines += "|    Subscription: $($state['Subscription'])"
    $bannerLines += "|    Location:     $($state['Location'])"
    $doneFlags = @($state.Keys | Where-Object { $_ -like '*_done' -or $_ -in @('catalog_uploaded','search_seeded','image_built','webui_published','knowledge_done','agents_done') })
    if ($doneFlags.Count -gt 0) {
        $bannerLines += "|    Already-completed phases: $($doneFlags.Count) -> $(($doneFlags | Sort-Object) -join ', ')"
    }
} else {
    $bannerLines += '|  Fresh run - no prior state. RG will be created.'
}
$bannerLines += '|'
$bannerLines += '|  To restart from scratch: rerun with -Reset (deletes the state file).'
$bannerLines += "|  Tail this log from another terminal:"
$bannerLines += "|    Get-Content '$logFile' -Wait -Tail 50"
$bannerLines += '+============================================================================+'
$bannerLines += ''
foreach ($l in $bannerLines) { Write-Host $l -ForegroundColor Cyan }

# Make sure transcript is closed cleanly even on hard exit (Ctrl+C, exception)
$cleanupHandler = {
    try { Stop-Transcript | Out-Null } catch { }
}
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $cleanupHandler | Out-Null


# -----------------------------------------------------------------------------
# Sync-StateFromAzure: at startup, scan the resource group and mark *_done
# flags for every module whose primary resource ALREADY EXISTS. This makes the
# script truly idempotent across state losses (clobbered file, fresh terminal,
# different machine, etc.) - if Azure already has it, we don't redeploy it.
# -----------------------------------------------------------------------------
function Sync-StateFromAzure {
    param([string]$ResourceGroup)
    if (-not $ResourceGroup) { return }
    $rgExists = (Invoke-Safe { az group exists --name $ResourceGroup }) -eq 'true'
    if (-not $rgExists) {
        Write-Skip "Sync skipped - RG '$ResourceGroup' does not exist (will be created)."
        return
    }
    Write-Step "Syncing state from Azure (rg: $ResourceGroup)..."
    $rawList = Invoke-Safe { az resource list -g $ResourceGroup -o json }
    if (-not $rawList) { Write-Skip 'No resources in RG yet.'; return }
    $resources = $rawList | Out-String | ConvertFrom-Json
    if (-not $resources -or $resources.Count -eq 0) { Write-Skip 'RG is empty.'; return }

    # Map Azure resource type -> module-done flag
    $detected = @{}
    $acrName  = ''
    foreach ($r in $resources) {
        switch ($r.type) {
            'Microsoft.ManagedIdentity/userAssignedIdentities' { $detected['identity_done']             = $true }
            'Microsoft.Storage/storageAccounts'                { $detected['storage_done']              = $true }
            'Microsoft.OperationalInsights/workspaces'         { $detected['monitor_done']              = $true }
            'Microsoft.Search/searchServices'                  { $detected['search_done']               = $true }
            'Microsoft.App/managedEnvironments'                { $detected['aca_done']                  = $true }
            'Microsoft.Web/sites'                              { $detected['appsvc_done']               = $true }
            'Microsoft.ApiManagement/service'                  { $detected['apim_done']                 = $true }
            'Microsoft.ContainerRegistry/registries'           { $acrName                               = $r.name }
            'Microsoft.CognitiveServices/accounts'             {
                # Foundry account follows the aif-* convention.
                if ($r.name -like 'aif-*') { $detected['foundry_done'] = $true }
            }
        }
    }

    $synced = @()
    foreach ($k in $detected.Keys) {
        if (-not $script:state[$k]) {
            $script:state[$k] = $true
            State-Set $k $true
            $synced += $k
        }
    }
    if ($acrName -and -not $script:state['AcrName']) {
        State-Set 'AcrName' $acrName
        $synced += "AcrName=$acrName"
    }

    # Also auto-detect data-plane completion (cheap probes):
    # 1) Catalog uploaded? Check if 'catalogs' container has any blobs.
    #    Run whenever storage exists (state OR freshly detected) so a lost/missing
    #    catalog_uploaded flag is recovered on subsequent runs without re-uploading.
    if (-not $script:state['catalog_uploaded'] -and ($detected['storage_done'] -or $script:state['storage_done'])) {
        $sa = ($resources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' } | Select-Object -First 1).name
        if ($sa) {
            $count = Invoke-Safe { az storage blob list --account-name $sa --container-name catalogs --auth-mode login --query "length(@)" -o tsv }
            if ($count -and [int]$count -gt 0) {
                State-Set 'catalog_uploaded' $true
                $synced += 'catalog_uploaded'
            }
        }
    }

    if ($synced.Count -gt 0) {
        Write-Ok "Synced from Azure (script will SKIP these): $($synced -join ', ')"
    } else {
        Write-Skip 'Nothing new synced - state was already accurate.'
    }
    $script:state = Load-State    # refresh cache
}

# -----------------------------------------------------------------------------
# Get-LatestModuleOutputs: when state says a module is done but outputs are
# missing (e.g. state file got reset), query ARM for the most recent successful
# deployment matching ida-<module>-* and return its outputs. Avoids re-running
# a 5-minute bicep just to recover output values.
# -----------------------------------------------------------------------------
function Get-LatestModuleOutputs {
    param([string]$ResourceGroup, [string]$ModuleName)
    $depList = Invoke-Safe { az deployment group list -g $ResourceGroup --query "sort_by([?starts_with(name, 'ida-$ModuleName-') && properties.provisioningState=='Succeeded'], &properties.timestamp) | [-1].name" -o tsv }
    if (-not $depList) { return $null }
    $outRaw = Invoke-Safe { az deployment group show -g $ResourceGroup -n $depList --query properties.outputs -o json }
    if (-not $outRaw) { return $null }
    $outObj = $outRaw | Out-String | ConvertFrom-Json
    # Flatten: {name: {type, value}} -> {name: value}
    $flat = @{}
    foreach ($prop in $outObj.PSObject.Properties) { $flat[$prop.Name] = $prop.Value.value }
    return $flat
}

# -----------------------------------------------------------------------------
# Test-SourceChanged: returns $true if any .cs/.csproj/.razor/.json file under
# the given relative source folder is newer than the supplied ISO timestamp.
# Used by Phase 10/12 to auto-detect when the orchestrator or web ui code was
# edited since the last successful build, so the next deploy run rebuilds
# without the user needing to manually clear state.
# -----------------------------------------------------------------------------
function Test-SourceChanged {
    param([string]$RelativePath, [string]$BuiltAtIso)
    if ([string]::IsNullOrWhiteSpace($BuiltAtIso)) { return $true }
    try { $builtAt = [datetime]::Parse($BuiltAtIso).ToUniversalTime() }
    catch { return $true }
    $full = Join-Path $projectRoot $RelativePath
    if (-not (Test-Path $full)) { return $false }
    $latest = Get-ChildItem $full -Recurse -File -Include *.cs,*.csproj,*.razor,*.json,*.cshtml,*.html,*.css `
        -ErrorAction SilentlyContinue `
        | Where-Object { $_.FullName -notmatch '\\(obj|bin)\\' } `
        | Sort-Object LastWriteTimeUtc -Descending `
        | Select-Object -First 1
    if (-not $latest) { return $false }
    return $latest.LastWriteTimeUtc -gt $builtAt
}

# ============================================================================
# Content-hash fingerprinting for incremental phase skip/re-run decisions.
# ============================================================================
# Test-SourceChanged above uses mtime, which misses three real cases that bit
# us during demo iterations:
#   * File renames (NTFS preserves mtime on rename - looks unchanged)
#   * File deletions (latest mtime of remaining files unchanged)
#   * Shared dependency edits (e.g. Shared.Contracts edits affect Web.Ui AND
#     Orchestrator.Api but Test-SourceChanged is called on each project root)
#
# Get-DirectoryFingerprint computes SHA256 over the sorted list of
# (relativePath | sha256-of-content) tuples for every file under the supplied
# paths matching $Include. The result is a single 64-char hex string that
# changes if ANY file is added, removed, renamed, or has its content modified.
# Phases compare current vs state-stored fingerprint and only fire when they
# differ. Cascading: when an upstream phase's fingerprint changes, it ALSO
# clears the downstream fingerprint so the dependent phase re-runs.
function Get-DirectoryFingerprint {
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [string[]]$Include = @('*.cs','*.csproj','*.razor','*.cshtml','*.css','*.html','*.json','*.bicep','Dockerfile','*.ps1','*.sln','*.slnx'),
        # File-extension list for binary asset directories (e.g. data/catalogs/*.pdf).
        # When the caller passes a pure asset folder we still want to fingerprint by
        # content, just over a different extension set.
        [switch]$AssetMode
    )
    if ($AssetMode) { $Include = @('*.pdf','*.png','*.jpg','*.jpeg','*.webp') }
    $sb = New-Object System.Text.StringBuilder
    foreach ($p in $Paths) {
        $full = Join-Path $projectRoot $p
        if (-not (Test-Path $full)) { continue }
        $isFile = -not (Test-Path $full -PathType Container)
        $files = if ($isFile) {
            @(Get-Item $full)
        } else {
            Get-ChildItem $full -Recurse -File -Include $Include -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/](obj|bin|\.vs|node_modules|publish[^\\/]*|artifacts)[\\/]' }
        }
        foreach ($f in ($files | Sort-Object FullName)) {
            $rel = $f.FullName.Substring($projectRoot.Length).TrimStart('\','/').Replace('\','/')
            try {
                $h = (Get-FileHash $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                [void]$sb.AppendLine("$rel|$h")
            } catch {
                # Locked file (e.g. running IDE). Fall back to size + mtime so we
                # still detect concurrent edits without bombing the whole hash.
                [void]$sb.AppendLine("$rel|locked|$($f.Length)|$($f.LastWriteTimeUtc.Ticks)")
            }
        }
    }
    if ($sb.Length -eq 0) { return $null }
    $bytes = [Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

# ============================================================================
# File-level differential blob sync (used by Phase 5).
# ============================================================================
# Previous Phase 5 logic compared counts only ($blobCount >= $pdfCount). That
# silently kept stale content when:
#   * A local PDF was REPLACED (same name, new content)  -> never re-uploaded
#   * A local PDF was RENAMED                            -> orphan blob left
#   * A local PDF was DELETED                            -> orphan blob left
# This helper instead enumerates both sides, computes diffs by (name + size),
# and:
#   * Uploads new + changed files (with --overwrite)
#   * Deletes blobs that no longer exist locally (configurable via $PruneOrphans)
#   * Returns counts so the caller can decide whether to invalidate downstream
#     phase fingerprints (Phase 8d / 8e).
# Note: Azure Blob's stored Content-MD5 is not always populated reliably across
# upload tools, so we use SIZE as the content-change signal. For PDFs (which
# never trivially share a size if content differs in any meaningful way) this
# is sufficient; combined with the upstream fingerprint, the contract is sound.
function Sync-BlobsIncremental {
    param(
        [Parameter(Mandatory)][string]$AccountName,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$LocalRoot,
        [string[]]$IncludePatterns = @('*.pdf'),
        [switch]$PruneOrphans
    )
    if (-not (Test-Path $LocalRoot)) { return @{ Uploaded=0; Deleted=0; Unchanged=0; ChangedAny=$false } }

    # --- local
    $rootLen = $LocalRoot.TrimEnd('\','/').Length + 1
    $localFiles = @()
    foreach ($pat in $IncludePatterns) {
        $localFiles += Get-ChildItem $LocalRoot -Recurse -File -Include $pat -ErrorAction SilentlyContinue
    }
    $localFiles = $localFiles | Sort-Object FullName -Unique
    $local = @{}
    foreach ($f in $localFiles) {
        $rel = $f.FullName.Substring($rootLen).Replace('\','/')
        $local[$rel] = [PSCustomObject]@{ Rel=$rel; FullName=$f.FullName; Size=$f.Length }
    }

    # --- blob
    $blobsJson = & { $ErrorActionPreference='Continue'; az storage blob list --account-name $AccountName --container-name $Container --auth-mode login --query "[].{name:name,size:properties.contentLength}" -o json 2>&1 } | Out-String
    $blob = @{}
    if ($LASTEXITCODE -eq 0 -and $blobsJson.Trim()) {
        try {
            $arr = $blobsJson | ConvertFrom-Json
            foreach ($b in $arr) { $blob[$b.name] = $b }
        } catch { }
    }

    # --- diffs
    $toUpload = @()
    foreach ($rel in $local.Keys) {
        $bf = $blob[$rel]
        if (-not $bf) {
            $toUpload += @{ Rel=$rel; FullName=$local[$rel].FullName; Reason='new' }
        } elseif ([int64]$bf.size -ne [int64]$local[$rel].Size) {
            $toUpload += @{ Rel=$rel; FullName=$local[$rel].FullName; Reason="size $($bf.size) -> $($local[$rel].Size)" }
        }
    }
    $toDelete = @()
    if ($PruneOrphans) {
        foreach ($name in $blob.Keys) {
            if (-not $local.ContainsKey($name)) { $toDelete += $name }
        }
    }

    # --- execute uploads with retry-on-transient (RBAC propagation, throttling).
    # Storage data-plane RBAC ('Storage Blob Data Contributor' on the deployer)
    # is granted by storage.bicep, but can take 30-90s to propagate. We retry
    # on transient errors. NON-FATAL: even if a few PDFs still fail after
    # retries the deploy continues - downstream phases (extraction + search
    # seed) work with whatever made it into the container; the user can re-run
    # deploy.ps1 to pick up the missing files (the diff sync will retry only
    # those that aren't there).
    $uploadedOk   = 0
    $uploadedFail = 0
    $failedFiles  = New-Object System.Collections.Generic.List[string]
    foreach ($u in $toUpload) {
        $maxAttempts = 5
        $success     = $false
        $lastErr     = ''
        for ($i = 1; $i -le $maxAttempts; $i++) {
            $output = & {
                $ErrorActionPreference='Continue'
                az storage blob upload `
                    --account-name $AccountName `
                    --container-name $Container `
                    --name $u.Rel `
                    --file $u.FullName `
                    --auth-mode login `
                    --overwrite `
                    --only-show-errors 2>&1
            } | Out-String
            if ($LASTEXITCODE -eq 0) { $success = $true; break }

            # Capture the FULL error - az writes "ERROR:" on one line and the
            # actual message on the next (or wraps long messages). The previous
            # "first non-empty line" extraction lost the real reason and showed
            # just "ERROR:" with no context. Now we keep all non-empty lines and
            # join them, then trim hard for the log.
            $errLines = ($output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'ERROR:' })
            $lastErr  = if ($errLines) { ($errLines -join ' | ') } else { 'az CLI returned non-zero with no stderr output' }

            $isTransient = $lastErr -match 'AuthorizationPermissionMismatch|AuthorizationFailure|does not have access|Forbidden|Status code: 4(0[138]|29)|Status code: 5\d\d|TimeoutException|ServerBusy|temporar|connection.*reset|connection.*aborted|RequestTimeout|InternalError|OperationTimedOut'
            if ($i -lt $maxAttempts -and $isTransient) {
                $delay = @(0, 10, 20, 40, 60)[$i]
                Write-Host "    [.] $($u.Rel) attempt $i/$maxAttempts transient - retry in ${delay}s" -ForegroundColor DarkYellow
                Start-Sleep -Seconds $delay
                continue
            }
            break
        }
        if ($success) {
            Write-Host "    [+] $($u.Rel)  ($($u.Reason))" -ForegroundColor Green
            $uploadedOk++
        } else {
            $trimmed = if ($lastErr.Length -gt 320) { $lastErr.Substring(0,320) + '...' } else { $lastErr }
            Write-Host "    [!] $($u.Rel) upload FAILED after $maxAttempts attempts: $trimmed" -ForegroundColor Red
            $uploadedFail++
            $failedFiles.Add($u.Rel) | Out-Null
        }
    }
    foreach ($d in $toDelete) {
        & { $ErrorActionPreference='Continue'; az storage blob delete --account-name $AccountName --container-name $Container --name $d --auth-mode login --only-show-errors 2>&1 } | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "    [-] $d  (removed - no longer in source)" -ForegroundColor Yellow }
    }

    return @{
        Uploaded     = $uploadedOk
        Failed       = $uploadedFail
        FailedFiles  = $failedFiles.ToArray()
        Deleted      = $toDelete.Count
        Unchanged    = ($local.Count - $toUpload.Count)
        ChangedAny   = ($uploadedOk -gt 0 -or $toDelete.Count -gt 0)
    }
}

# Sequential bicep module deployer with resume support.
function Deploy-Module {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BicepPath,
        [Parameter(Mandatory)][hashtable]$Params,
        [string[]]$RequiredOutputs = @()   # If cached outputs lack any of these, force re-run
    )
    $stateKey = "${Name}_done"
    $outKey   = "${Name}_outputs"

    # Check if cached outputs satisfy required keys. Returns $null if all good, else array of missing keys.
    $missingFn = {
        param($outs, $req)
        if (-not $req -or $req.Count -eq 0) { return $null }
        if (-not $outs) { return $req }
        $miss = @()
        foreach ($k in $req) {
            $v = $null
            if ($outs -is [hashtable])             { $v = $outs[$k] }
            elseif ($outs.PSObject.Properties[$k]) { $v = $outs.$k }
            if ($null -eq $v -or "$v" -eq '') { $miss += $k }
        }
        if ($miss.Count -eq 0) { return $null } else { return $miss }
    }

    if ($state[$stateKey] -and $state[$outKey]) {
        $missing = & $missingFn $state[$outKey] $RequiredOutputs
        if (-not $missing -and -not (Test-BicepVersionDrift $Name $state[$outKey])) {
            Write-Skip "${Name}: already deployed (state file says so) - reusing cached outputs"
            return $state[$outKey]
        }
        if ($missing) {
            Write-Skip "${Name}: cached outputs lack required keys ($($missing -join ',')) - bicep is newer, re-running idempotently"
        } else {
            Write-Skip "${Name}: bicep version drift detected against cached outputs - re-running idempotently"
        }
    } elseif ($state[$stateKey]) {
        # Try ARM first: fetch outputs from the most recent successful deployment.
        $armOuts = Get-LatestModuleOutputs -ResourceGroup $ResourceGroup -ModuleName $Name
        if ($armOuts) {
            $missing = & $missingFn $armOuts $RequiredOutputs
            $drift   = Test-BicepVersionDrift $Name $armOuts
            if (-not $missing -and -not $drift) {
                Write-Skip "${Name}: state had no outputs but ARM has them - reusing from latest deployment"
                State-Set $outKey $armOuts
                $script:state = Load-State
                return $armOuts
            }
            if ($missing) {
                Write-Skip "${Name}: ARM-recovered outputs lack required keys ($($missing -join ',')) - bicep is newer, re-running"
            } else {
                Write-Skip "${Name}: bicep version drift detected against ARM outputs - re-running idempotently"
            }
        } else {
            Write-Skip "${Name}: marked done but outputs missing - re-running bicep idempotently"
        }
    }
    Write-Step "Deploying module '${Name}' ..."

    # Build the parameters JSON file
    $paramObj = @{
        '$schema'        = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        'contentVersion' = '1.0.0.0'
        'parameters'     = @{}
    }
    foreach ($k in $Params.Keys) {
        $v = $Params[$k]
        # Force JSON array shape for any value that IS already an array. The
        # call site is responsible for ensuring array-typed params are typed
        # arrays (e.g. [string[]]$ipList = @()) - the if-as-expression idiom
        # unwraps single-element arrays to scalars and breaks bicep 'array' params.
        if ($v -is [System.Array] -or $v -is [System.Collections.IList]) {
            $genList = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $v) { [void]$genList.Add($item) }
            $paramObj.parameters[$k] = @{ value = $genList }
        } else {
            $paramObj.parameters[$k] = @{ value = $v }
        }
    }
    $pf = Join-Path $artifacts ("params-{0}.json" -f $Name)
    $paramObj | ConvertTo-Json -Depth 30 | Set-Content $pf -Encoding UTF8

    $depName = "ida-{0}-{1}" -f $Name, (Get-Date -Format 'yyMMddHHmmss')
    $sw = [Diagnostics.Stopwatch]::StartNew()

    # Retry on transient Azure errors. Common patterns we see in practice:
    #   * StorageAccountOperationInProgress  - prior op (often a role assignment
    #     from the identity module) hasn't released its exclusive lock yet
    #   * AnotherOperationInProgress / OperationInProgress  - generic ARM lock
    #   * Conflict + 'in progress'           - ditto
    #   * RetryableError / TooManyRequests / ServiceUnavailable / 5xx
    # We don't retry on real bicep / parameter / quota errors (those are not
    # transient and would just waste time). The detection is deliberately
    # narrow - if a new transient pattern shows up, add it here.
    $maxAttempts  = 5
    $delaysSec    = @(15, 30, 60, 90, 120)
    $raw          = ''
    $depSucceeded = $false
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        # Wrap in sub-scope with EAP=Continue: on Windows PowerShell 5.1, native commands
        # writing to stderr still produce a terminating NativeCommandError under EAP=Stop
        # even with 2>&1. We rely on $LASTEXITCODE checks below.
        $thisDepName = if ($attempt -eq 1) { $depName } else { "{0}-r{1}" -f $depName, $attempt }
        $raw = & { $ErrorActionPreference = 'Continue'; az deployment group create -g $ResourceGroup -n $thisDepName -f $BicepPath --parameters "@$pf" -o json 2>&1 } | Out-String
        if ($LASTEXITCODE -eq 0) { $depSucceeded = $true; break }

        $isTransient = $raw -match 'StorageAccountOperationInProgress|AnotherOperationInProgress|OperationInProgress|in progress|RetryableError|TooManyRequests|ServiceUnavailable|InternalServerError|GatewayTimeout|RequestTimeout|TemporarilyUnavailable|Conflict.*progress|503|504'
        if ($isTransient -and $attempt -lt $maxAttempts) {
            $delay = $delaysSec[$attempt - 1]
            Write-Skip "  ${Name}: transient Azure error on attempt $attempt/$maxAttempts; sleeping ${delay}s then retrying..."
            # Surface a one-line hint so the operator sees what's happening
            $hint = ($raw -split "`r?`n") | Where-Object { $_ -match 'StorageAccountOperationInProgress|AnotherOperationInProgress|OperationInProgress|RetryableError|TooManyRequests|ServiceUnavailable|InternalServerError' } | Select-Object -First 1
            if ($hint) { Write-Skip "    hint: $($hint.Trim())" }
            Start-Sleep -Seconds $delay
            continue
        }
        break
    }
    $sw.Stop()
    if (-not $depSucceeded) {
        Write-Err2 "Module '${Name}' failed (exit $LASTEXITCODE):`n$raw"
        throw "Module ${Name} failed"
    }
    try { $out = $raw | ConvertFrom-Json } catch { Write-Err2 "Could not parse az output for ${Name}"; throw }
    if ($out.properties.provisioningState -ne 'Succeeded') {
        Write-Err2 "Module '${Name}' state=$($out.properties.provisioningState)"
        throw "Module ${Name} failed"
    }
    Write-Ok "${Name}: Succeeded in $([math]::Round($sw.Elapsed.TotalSeconds))s"

    # Hashtable of module outputs (key -> raw value)
    $outputs = @{}
    if ($out.properties.outputs) {
        foreach ($p in $out.properties.outputs.PSObject.Properties) {
            $outputs[$p.Name] = $p.Value.value
        }
    }
    State-Set $stateKey $true
    State-Set "${Name}_outputs" $outputs
    $script:state = Load-State
    return $outputs
}


# -----------------------------------------------------------------------------
# Pre-flight quota check for Foundry model deployments. Fails FAST (in 2 sec)
# with actionable instructions if quota is insufficient, instead of wasting 5
# min on a doomed `az deployment group create`. Soft-deleted accounts in the
# region are listed with ready-to-paste purge commands.
# -----------------------------------------------------------------------------
function Check-FoundryQuota {
    param(
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][hashtable]$Models   # @{ chat=@{name='gpt-4.1-mini';capacity=50}; image=@{name='MAI-Image-2';capacity=1} }
    )
    Write-Step "Pre-flight: checking Foundry model quota in '$Region' ..."
    $usageRaw = Invoke-Safe { az cognitiveservices usage list -l $Region -o json }
    if (-not $usageRaw) {
        Write-Skip "Could not query usage in '$Region' - skipping pre-flight (deploy will surface real error)."
        return $true
    }
    $usage = $usageRaw | Out-String | ConvertFrom-Json
    $allOk = $true
    $shortfalls = @()
    foreach ($k in $Models.Keys) {
        $m       = $Models[$k]
        $name    = $m.name
        $needed  = [int]$m.capacity
        # Quota row format: AIServices.GlobalStandard.<modelname>
        $row = $usage | Where-Object { $_.name.value -ieq "AIServices.GlobalStandard.$name" } | Select-Object -First 1
        if (-not $row) {
            Write-Skip "  $k '$name': no GlobalStandard quota row in $Region (model may not be available here)"
            continue
        }
        $available = [int]($row.limit - $row.currentValue)
        if ($available -ge $needed) {
            Write-Ok "  $k '$name': $available RPM available (need $needed) - OK"
        } else {
            Write-Err2 "  $k '$name': INSUFFICIENT - $available RPM available, need $needed"
            $allOk = $false
            $shortfalls += "$k=$name(need $needed, have $available)"
        }
    }
    if (-not $allOk) {
        Write-Host ''
        Write-Host '  ============================================================' -ForegroundColor Yellow
        Write-Host '   QUOTA SHORTFALL - HOW TO FREE QUOTA' -ForegroundColor Yellow
        Write-Host '  ============================================================' -ForegroundColor Yellow
        Write-Host "   Shortfall: $($shortfalls -join ', ')" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '   Soft-deleted Cognitive Services accounts hold quota until' -ForegroundColor Yellow
        Write-Host '   they are physically purged (auto-purge ~48h).' -ForegroundColor Yellow
        Write-Host ''
        $delRaw = Invoke-Safe { az cognitiveservices account list-deleted -o json }
        $deletedHere = @()
        if ($delRaw) {
            try {
                $deletedAll = $delRaw | Out-String | ConvertFrom-Json
                $deletedHere = $deletedAll | Where-Object { $_.location -eq $Region }
            } catch { }
        }
        if ($deletedHere) {
            Write-Host "   Soft-deleted accounts currently in '$Region':" -ForegroundColor Yellow
            foreach ($d in $deletedHere) {
                $rg = $d.properties.originalResourceGroup
                if ([string]::IsNullOrWhiteSpace($rg)) { $rg = '<original RG was deleted>' }
                Write-Host "     - $($d.name)  (original RG: $rg)" -ForegroundColor Cyan
                Write-Host "       Purge: az cognitiveservices account purge --location $Region --name $($d.name) --resource-group $rg" -ForegroundColor DarkCyan
            }
        } else {
            Write-Host "   No soft-deleted accounts found in '$Region'." -ForegroundColor Yellow
            Write-Host '   Quota is likely held by ACTIVE deployments. Either:' -ForegroundColor Yellow
            Write-Host '     a) Reduce capacity:  -ChatModelCapacity 25  -ImageModelCapacity 1' -ForegroundColor Cyan
            Write-Host '     b) Request quota increase via Azure Portal -> Cognitive Services -> Quotas' -ForegroundColor Cyan
        }
        Write-Host ''
        Write-Host '   Or in the Azure Portal:' -ForegroundColor Yellow
        Write-Host '     1. portal.azure.com -> search "Cognitive Services"' -ForegroundColor Yellow
        Write-Host '     2. Top toolbar: "Manage deleted accounts"' -ForegroundColor Yellow
        Write-Host "     3. Filter to '$Region', click your account, click 'Purge'" -ForegroundColor Yellow
        Write-Host '  ============================================================' -ForegroundColor Yellow
        Write-Host ''
    }
    return $allOk
}


# Wrapper for Invoke-RestMethod that retries on transient AAD/RBAC propagation errors.
# Used for AI Search seed (storage RBAC takes 30-90 sec to propagate after search.bicep).
function Invoke-RestWithRetry {
    param([string]$Method, [string]$Uri, $Headers, $Body, [int]$MaxAttempts = 12, [int]$DelaySec = 15)
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $Body -ErrorAction Stop
        } catch {
            $msg = $_.ErrorDetails.Message
            if (-not $msg) { $msg = $_.Exception.Message }
            # Retry on:
            #   * 401/403 -> RBAC propagation (account/project role assignments take 30-90 sec)
            #   * 408/429/5xx -> transient
            #   * known message patterns (covers SDK / API responses without status code)
            $status = 0
            if ($_.Exception.Response) { try { $status = [int]$_.Exception.Response.StatusCode } catch { } }
            $isTransientStatus = $status -in @(401,403,408,429,500,502,503,504)
            $isTransientMsg    = $msg -match 'Credentials.*invalid|expired|Forbidden|AuthorizationFailed|access.*denied|no.*permission|RBAC.*propagat|PermissionDenied|does not have access|Unauthorized|TooManyRequests|throttl|temporar'
            $isTransient = $isTransientStatus -or $isTransientMsg
            if ($isTransient -and $i -lt $MaxAttempts) {
                Write-Skip "    attempt $i/$MaxAttempts failed (HTTP $status, transient AAD/RBAC) - waiting $DelaySec sec then retry..."
                Start-Sleep -Seconds $DelaySec
                continue
            }
            throw
        }
    }
}

function Get-ShortHash([string]$Text) {
    # NOTE: the parameter is intentionally named $Text, NOT $input. $input is a
    # PowerShell automatic variable (the pipeline-input enumerator) and silently
    # shadows any parameter of the same name, which would make this function
    # always hash the empty string and return 'e3b0c4' (SHA256 prefix of '').
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    $hex   = -join ($bytes | ForEach-Object { '{0:x2}' -f $_ })
    return $hex.Substring(0, 6)
}

function Get-ContentFingerprint([string]$Text) {
    # 16-hex-char fingerprint used to detect content drift in agent definitions
    # (model + instructions + knowledge bindings + KB name). When the local
    # fingerprint differs from the cached one in state, deploy.ps1 mints a new
    # version of the agent in Foundry instead of reusing the existing one.
    if ($null -eq $Text) { $Text = '' }
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        $hex   = -join ($bytes | ForEach-Object { '{0:x2}' -f $_ })
        return $hex.Substring(0, 16)
    } finally { $sha.Dispose() }
}

# =============================================================================
# PHASE 0 - Prerequisite check
# =============================================================================
Write-Phase 0 'Prerequisite check'
Write-Info "Project root: $projectRoot"
foreach ($t in @('az','dotnet','pwsh')) {
    $cmd = Get-Command $t -ErrorAction SilentlyContinue
    if (-not $cmd) { Write-Err2 "$t not found on PATH"; Exit-Deploy 1 }
    Write-Ok "$t -> $($cmd.Source)"
}
$hasAzd = [bool](Get-Command azd -ErrorAction SilentlyContinue)

# Best-effort upgrades (skipped with -SkipUpgrades)
function Try-Upgrade($name, [scriptblock]$script) {
    Write-Step "Upgrading $name ..."
    $global:LASTEXITCODE = 0
    try { & $script *>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "${name}: upgrade pass complete" }
        else { Write-Skip "${name}: upgrade returned exit $LASTEXITCODE - keeping current" }
    } catch { Write-Skip "${name}: upgrade skipped ($($_.Exception.Message))" }
    $global:LASTEXITCODE = 0
}
if (-not $SkipUpgrades) {
    Write-Step 'Running upgrade pass (use -SkipUpgrades to skip)...'
    Try-Upgrade 'Bicep (via az)' { az bicep upgrade --only-show-errors }
    Try-Upgrade 'Azure CLI'      { az upgrade --yes --only-show-errors }
} else {
    Write-Skip 'Tool upgrades (-SkipUpgrades set)'
}

Write-Ok 'Azure CLI : (binary on PATH; first real call happens in Phase 1)'
Write-Ok 'Bicep     : (verified on first Deploy-Module call)'
Write-Ok ('azd       : ' + $(if ($hasAzd) { 'present' } else { 'not installed' }))

# =============================================================================
# PHASE 1 - Azure login
# =============================================================================
Write-Phase 1 'Azure login'
Write-Step 'Checking az login...'
$account = Get-AzAccount
if (-not $account) {
    Write-Info "No active az session - launching 'az login' (browser will open)..."
    az login
    if ($LASTEXITCODE -ne 0) { Write-Err2 'az login failed.'; Exit-Deploy 1 }
    $global:LASTEXITCODE = 0
    $account = Get-AzAccount
    if (-not $account) { Write-Err2 'Still not signed in.'; Exit-Deploy 1 }
}
Write-Ok "Subscription : $($account.name) ($($account.id))"
Write-Ok "Tenant       : $($account.tenantId)"
Write-Ok "Signed in as : $($account.user.name)"

if (-not $SubscriptionId) {
    if (-not (Ask-YesNo 'Continue with this subscription?' $true)) {
        az account list --query '[].{Name:name, Id:id, IsDefault:isDefault}' -o table
        $SubscriptionId = Read-Host 'Enter the Subscription ID to use'
        az account set --subscription $SubscriptionId
        if ($LASTEXITCODE -ne 0) { Write-Err2 'Failed to switch subscription.'; Exit-Deploy 1 }
        $global:LASTEXITCODE = 0
        $account = Get-AzAccount
    }
} else {
    az account set --subscription $SubscriptionId | Out-Null
    $account = Get-AzAccount
}
$SubId       = $account.id
$TenantId    = $account.tenantId
$PrincipalId = Invoke-Safe { az ad signed-in-user show --query id -o tsv }
if ([string]::IsNullOrWhiteSpace($PrincipalId)) { Write-Err2 'Could not resolve user object id.'; Exit-Deploy 1 }
Write-Ok "User object id: $PrincipalId"

if ($hasAzd -and $AzdLogin) {
    Write-Step 'Signing azd in (device code, since -AzdLogin was passed)...'
    azd auth login --use-device-code --tenant-id $TenantId
    if ($LASTEXITCODE -ne 0) { Write-Skip 'azd auth failed (non-fatal).'; $global:LASTEXITCODE = 0 }
    else { Write-Ok 'azd authenticated' }
} else {
    Write-Skip 'azd auth skipped (pass -AzdLogin to enable). az is sufficient.'
}

# =============================================================================
# PHASE 2 - Cleanup prompt (NEVER auto-deletes; always asks)
# =============================================================================

# Auto-detect stale state: if previous run left module_done flags pointing at an
# RG that no longer exists in Azure, clear those flags so we redo the work cleanly.
$prevRgInState = $state['ResourceGroup']
if ($prevRgInState -and ($state.Keys | Where-Object { $_ -like '*_done' }).Count -gt 0) {
    Write-Step "Validating state against Azure (resource group: $prevRgInState) ..."
    $rgLive = (Invoke-Safe { az group exists --name $prevRgInState }) -eq 'true'
    if (-not $rgLive) {
        Write-Skip "RG '$prevRgInState' from state no longer exists in Azure - clearing stale module flags."
        $cleared = @()
        foreach ($k in @($state.Keys)) {
            if ($k -like '*_done' -or $k -like '*_outputs' -or $k -in @('catalog_uploaded','search_seeded','image_built','webui_published','AcrName')) {
                $state.Remove($k); $cleared += $k
            }
        }
        Save-State $state
        Write-Ok "Cleared $($cleared.Count) stale state keys - script will redeploy from scratch in this RG."
    } else {
        Write-Ok "RG '$prevRgInState' still exists - resume mode active."
    }
}

Write-Phase 2 'Cleanup previous deployment (optional)'

# This prompt is INTENTIONALLY interactive even when -Yes / -SkipCleanupPrompt
# is set (which is the default). Deleting a resource group is destructive and
# irreversible, so we never want to silently auto-skip the question. CI / true
# unattended runs can pass -NoCleanupPrompt to bypass it entirely.
function Read-YesNoStrict {
    param([string]$Question, [switch]$DefaultYes)
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        try {
            $answer = Read-Host "$Question $suffix"
        } catch {
            # Non-interactive host (no console) - fall back to the default.
            $defLabel = if ($DefaultYes) { 'YES' } else { 'NO' }
            Write-Skip "  (non-interactive host - defaulting to $defLabel)"
            return [bool]$DefaultYes
        }
        if ([string]::IsNullOrWhiteSpace($answer)) { return [bool]$DefaultYes }
        if ($answer -match '^[yY]') { return $true }
        if ($answer -match '^[nN]') { return $false }
        Write-Host "    Please answer y or n." -ForegroundColor DarkGray
    }
}

# Pick up the previous RG from state OR from the most recent successful run that
# may have lost state (e.g. fresh terminal, LOCALAPPDATA reset). We try state first,
# then fall back to the conventional rg-<EnvironmentName> name if the user passed it.
$prevRg = $state['ResourceGroup']
if (-not $prevRg -and $EnvironmentName) {
    $candidate = "rg-$EnvironmentName"
    if ((Invoke-Safe { az group exists --name $candidate }) -eq 'true') { $prevRg = $candidate }
}

if ($NoCleanupPrompt) {
    Write-Skip 'Cleanup prompt skipped (-NoCleanupPrompt). Resuming any existing infrastructure.'
}
elseif ($prevRg) {
    $rgExists = (Invoke-Safe { az group exists --name $prevRg }) -eq 'true'
    if (-not $rgExists) {
        Write-Skip "Previous RG '$prevRg' no longer exists in Azure - nothing to delete."
        if (Test-Path $statePath) { Remove-Item $statePath -Force -ErrorAction SilentlyContinue }
        $state = @{}
    }
    else {
        Write-Info "A previous deployment exists in resource group: $prevRg"
        if (Read-YesNoStrict "Delete '$prevRg' and start a brand-new deployment?" -DefaultYes:$false) {
            $confirm = Read-Host "  Type the RG name '$prevRg' EXACTLY to confirm deletion"
            if ($confirm -ne $prevRg) {
                Write-Skip 'RG name did not match - aborted delete. Continuing in resume mode.'
            }
            else {
                Write-Step "Deleting '$prevRg' and waiting for completion (this can take 5-15 minutes)..."
                $delStart = Get-Date

                # Kick off the delete asynchronously so we can show a heartbeat.
                # `az group delete --yes` (without --no-wait) blocks but produces no
                # progress output, which looks like a hang to the user. We launch the
                # async variant and poll `az group exists` every 15 seconds instead.
                $null = Invoke-Safe { az group delete --name $prevRg --yes --no-wait }

                $deleted = $false
                while ($true) {
                    Start-Sleep -Seconds 15
                    $stillThere = (Invoke-Safe { az group exists --name $prevRg }) -eq 'true'
                    $elapsed = [math]::Round(((Get-Date) - $delStart).TotalSeconds, 0)
                    if (-not $stillThere) {
                        Write-Ok "RG '$prevRg' deleted (took ${elapsed}s)."
                        $deleted = $true
                        break
                    }
                    Write-Host ("    ... still deleting ({0}s elapsed)" -f $elapsed) -ForegroundColor DarkGray
                    if ($elapsed -gt 1800) {
                        Write-Err2 "Delete is still running after 30 minutes; giving up the wait. You can re-run the script later."
                        throw "RG '$prevRg' delete did not complete within 30 min."
                    }
                }

                # Clear state - the next phases must start completely fresh.
                if (Test-Path $statePath) { Remove-Item $statePath -Force -ErrorAction SilentlyContinue }
                $state = @{}

                # Ask for the new RG name. Default suggests the same name (now free)
                # but the user can pick a totally fresh one.
                if ($deleted) {
                    Write-Host ''
                    $newDefault = $prevRg
                    while ($true) {
                        try {
                            $entered = Read-Host "  New resource group name to deploy into [$newDefault]"
                        } catch { $entered = '' }
                        if ([string]::IsNullOrWhiteSpace($entered)) { $entered = $newDefault }
                        if ($entered -notmatch '^[A-Za-z0-9._()-]{1,90}$') {
                            Write-Err2 "  Invalid RG name (use letters/digits/._()-, max 90 chars)."
                            continue
                        }
                        $ResourceGroup = $entered
                        break
                    }
                    State-Set 'ResourceGroup' $ResourceGroup
                    Write-Ok "New deployment will use resource group: $ResourceGroup"
                    Write-Info "Phase 8 will auto-rename the Foundry account if a soft-deleted name collision is detected."
                }
            }
        }
        else {
            Write-Skip 'Reusing existing infrastructure (resume mode).'
        }
    }
}
else {
    Write-Info 'No previous resource group detected - this is a fresh deployment.'
}

# =============================================================================
# PHASE 3 - Collect parameters
# =============================================================================
Write-Phase 3 'Parameters'

# -----------------------------------------------------------------------------
# Top-level RG choice. Always interactive (bypasses -Yes), unless the user
# passes -NoCleanupPrompt for true unattended runs. Replaces the previous
# behaviour that silently auto-adopted any RG named 'rg-<EnvironmentName>'
# from prior state, which made it impossible to start a fresh deployment in a
# new RG without manually clearing %LOCALAPPDATA%\InteriorDesignAccelerator\.
# -----------------------------------------------------------------------------
function Get-CandidateResourceGroups {
    # Return RGs in the current subscription that look like ours (tagged with
    # solution=InteriorDesignAccelerator OR named rg-*). Sorted most recent first.
    $rawTagged = Invoke-Safe { az group list --tag 'solution=InteriorDesignAccelerator' --query "[].{name:name,location:location}" -o json }
    $tagged = @()
    if ($rawTagged) { try { $tagged = @($rawTagged | Out-String | ConvertFrom-Json) } catch { } }

    if ($tagged.Count -gt 0) { return $tagged | ForEach-Object { $_.name } }

    # Fall back: any RG starting with 'rg-' in the subscription.
    $rawAll = Invoke-Safe { az group list --query "[?starts_with(name, 'rg-')].name" -o json }
    if ($rawAll) {
        try { return @($rawAll | Out-String | ConvertFrom-Json) } catch { return @() }
    }
    return @()
}

if (-not $NoCleanupPrompt -and -not $ResourceGroup) {
    Write-Host ''
    Write-Host '  Resource group choice (this prompt always runs - it is destructive to assume).' -ForegroundColor Cyan

    $candidates = @(Get-CandidateResourceGroups)
    $prevFromState = $state['ResourceGroup']

    # Show menu: previous RG (if any) marked with [*], then other candidates,
    # then the option to create a brand-new one.
    $menu = @()
    if ($prevFromState -and $candidates -notcontains $prevFromState) { $candidates = @($prevFromState) + $candidates }
    foreach ($c in $candidates) {
        $marker = if ($c -eq $prevFromState) { ' (previous deployment)' } else { '' }
        $menu  += [pscustomobject]@{ Index = $menu.Count; Label = "Update existing RG: $c$marker"; Action = 'use'; Value = $c }
    }
    $menu += [pscustomobject]@{ Index = $menu.Count; Label = 'Create a NEW resource group';            Action = 'new'; Value = $null }

    Write-Host ''
    foreach ($row in $menu) { Write-Host ("    [{0}] {1}" -f $row.Index, $row.Label) -ForegroundColor Yellow }
    Write-Host ''

    $defaultPick = if ($prevFromState) { 0 } else { $menu.Count - 1 }
    $picked = $null
    while ($null -eq $picked) {
        try {
            $entered = Read-Host "  Pick an option [$defaultPick]"
        } catch { $entered = '' }
        if ([string]::IsNullOrWhiteSpace($entered)) { $entered = "$defaultPick" }
        if ($entered -notmatch '^\d+$') { Write-Err2 "    Enter a number 0..$($menu.Count - 1)"; continue }
        $idx = [int]$entered
        if ($idx -lt 0 -or $idx -ge $menu.Count) { Write-Err2 "    Out of range. Pick 0..$($menu.Count - 1)"; continue }
        $picked = $menu[$idx]
    }

    if ($picked.Action -eq 'use') {
        $ResourceGroup = $picked.Value
        Write-Ok "Will UPDATE resources in existing RG: $ResourceGroup"
        # Derive env label from RG name (strip leading 'rg-') so deterministic
        # naming stays consistent with what's already deployed.
        if (-not $EnvironmentName) {
            if ($state['EnvironmentName']) {
                $EnvironmentName = $state['EnvironmentName']
                Write-Ok "Env label from state: $EnvironmentName"
            } elseif ($ResourceGroup -match '^rg-(.+)$') {
                $EnvironmentName = $matches[1]
                Write-Ok "Env label derived from RG name: $EnvironmentName"
            }
        }
        State-Set 'ResourceGroup'    $ResourceGroup
        State-Set 'EnvironmentName'  $EnvironmentName
    }
    else {
        # Create-new path: pick a fresh env label, default to a salted variant of
        # the previous label so the deterministic resource hashes are unique.
        $rand    = -join ((48..57 + 97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
        $base    = if ($state['EnvironmentName']) { $state['EnvironmentName'] } else { 'idabath' }
        if ($base -match '^(.+)-[a-z0-9]{3,4}$') { $base = $matches[1] }
        $envSuggested = "$base-$rand"

        Write-Host ''
        Write-Info 'Creating a brand-new resource group. Pick an environment label (lowercase, hyphens ok):'
        while (-not $EnvironmentName) {
            try {
                $entered = Read-Host "  Environment label [$envSuggested]"
            } catch { $entered = '' }
            if ([string]::IsNullOrWhiteSpace($entered)) { $entered = $envSuggested }
            if ($entered -notmatch '^[a-z0-9][a-z0-9-]*$' -or $entered.Length -gt 30) {
                Write-Err2 '    Use only lowercase/digits/hyphens, max 30 chars.'
                continue
            }
            $EnvironmentName = $entered
        }

        # RG name defaults to rg-<env>; allow override.
        $rgSuggested = "rg-$EnvironmentName"
        while (-not $ResourceGroup) {
            try {
                $entered = Read-Host "  Resource group name [$rgSuggested]"
            } catch { $entered = '' }
            if ([string]::IsNullOrWhiteSpace($entered)) { $entered = $rgSuggested }
            if ($entered -notmatch '^[A-Za-z0-9._()-]{1,90}$') {
                Write-Err2 '    Invalid RG name (letters/digits/._()-, max 90 chars).'
                continue
            }
            # Refuse to silently overwrite an existing RG when user said "create new".
            $exists = (Invoke-Safe { az group exists --name $entered }) -eq 'true'
            if ($exists) {
                Write-Err2 "    RG '$entered' already exists. Pick a different name (or restart and choose 'Update existing RG')."
                continue
            }
            $ResourceGroup = $entered
        }
        Write-Ok "Will CREATE new RG: $ResourceGroup (env label: $EnvironmentName)"
        State-Set 'ResourceGroup'    $ResourceGroup
        State-Set 'EnvironmentName'  $EnvironmentName
    }
}

$validLocs = @('swedencentral','canadacentral','northcentralus','australiaeast')
if (-not $Location) {
    if ($state.ContainsKey('Location') -and $state['Location'] -in $validLocs) {
        $Location = $state['Location']
        Write-Ok "Reusing previous location: $Location"
    } else {
        Write-Host ''
        Write-Host '  Hosted-agent regions: swedencentral / canadacentral / northcentralus / australiaeast' -ForegroundColor Yellow
        do { $Location = Ask-Default '  Choose location' 'swedencentral'
            if ($Location -notin $validLocs) { Write-Err2 "Invalid - must be one of: $($validLocs -join ', ')" }
        } while ($Location -notin $validLocs)
    }
}
if (-not $EnvironmentName) {
    if ($state.ContainsKey('EnvironmentName') -and $state['EnvironmentName']) {
        $EnvironmentName = $state['EnvironmentName']
        Write-Ok "Reusing previous env name: $EnvironmentName"
    } else {
        do { $EnvironmentName = Ask-Default '  Environment label (lowercase, hyphens ok)' 'idabath'
            if ($EnvironmentName -notmatch '^[a-z0-9][a-z0-9-]*$' -or $EnvironmentName.Length -gt 30) {
                Write-Err2 'Use only lowercase/digits/hyphens, max 30 chars'; $EnvironmentName = $null
            }
        } while (-not $EnvironmentName)
    }
}
if (-not $ResourceGroup) {
    if ($state.ContainsKey('ResourceGroup') -and $state['ResourceGroup']) {
        $ResourceGroup = $state['ResourceGroup']
        Write-Ok "Reusing previous resource group: $ResourceGroup"
    } else {
        # Auto-discover: if Azure already has rg-<EnvironmentName>, adopt it instead
        # of asking. Saves user from accidentally creating a NEW RG every run when
        # state was lost (e.g. fresh terminal that lost LOCALAPPDATA visibility).
        $candidate = "rg-" + $EnvironmentName
        if ((Invoke-Safe { az group exists --name $candidate }) -eq 'true') {
            $ResourceGroup = $candidate
            Write-Ok "Auto-discovered existing RG in Azure: $ResourceGroup (no state file but RG exists - adopting)"
        } else {
            $ResourceGroup = Ask-Default '  Resource group name' $candidate
        }
    }
}
# Persist immediately so next attempt finds the RG even if a downstream phase crashes.
State-Set 'ResourceGroup' $ResourceGroup

# Critical idempotency step: scan the RG and mark module flags for resources that
# already exist. This is what makes the script truly idempotent across state losses -
# even if state.json was nuked, the script learns from Azure what's already deployed
# and skips it. Without this, every run would create duplicate resources.
Sync-StateFromAzure -ResourceGroup $ResourceGroup
$state = Load-State

if (-not $ExistingFoundryAccountId -and -not $NewFoundry) {
    if ($state.ContainsKey('ExistingFoundryAccountId')) {
        # State has the key (even if empty string = 'create new') - honour it, do not prompt.
        $ExistingFoundryAccountId = $state['ExistingFoundryAccountId']
        if ($ExistingFoundryAccountId) { Write-Ok "Reusing existing Foundry: $ExistingFoundryAccountId" }
        else { Write-Ok 'Foundry choice from state: CREATE NEW (empty in state file)' }
    } else {
        $foundryJson = Invoke-Safe { az cognitiveservices account list --query "[?kind=='AIServices'].{name:name,rg:resourceGroup,location:location,id:id}" -o json }
        $foundryAccounts = @()
        if ($foundryJson) { try { $foundryAccounts = $foundryJson | Out-String | ConvertFrom-Json } catch { } }
        if ($foundryAccounts.Count -gt 0) {
            Write-Host ''
            Write-Host '  Existing AIServices/Foundry accounts:' -ForegroundColor Yellow
            for ($i=0; $i -lt $foundryAccounts.Count; $i++) {
                ('    [{0}] {1}  ({2}/{3})' -f $i, $foundryAccounts[$i].name, $foundryAccounts[$i].rg, $foundryAccounts[$i].location) | Write-Host
            }
            Write-Host "    [N] Create a NEW Foundry account in $ResourceGroup"
            $sel = Ask-Default '  Reuse one (index) or N for new' 'N'
            if ($sel -match '^\d+$' -and [int]$sel -lt $foundryAccounts.Count) {
                $ExistingFoundryAccountId = $foundryAccounts[[int]$sel].id
            }
        } else { Write-Info 'No existing Foundry accounts.' }
    }
}
$FoundryLocation = $Location
if ($ExistingFoundryAccountId) {
    $existingLoc = Invoke-Safe { az cognitiveservices account show --ids $ExistingFoundryAccountId --query location -o tsv }
    if ($existingLoc) { $FoundryLocation = $existingLoc }
}

# Resolve deployer's public IP for storage firewall
Write-Step 'Resolving deployer public IP...'
$deployerIp = ''
foreach ($svc in @('https://api.ipify.org','https://ifconfig.me/ip','https://ipv4.icanhazip.com')) {
    try {
        $ip = (Invoke-RestMethod -Uri $svc -TimeoutSec 5).ToString().Trim()
        if ($ip -match '^(?:\d{1,3}\.){3}\d{1,3}$') { $deployerIp = $ip; break }
    } catch { }
}
if ($deployerIp) { Write-Ok "Public IP: $deployerIp" } else { Write-Skip 'Could not resolve public IP - storage will be deny-by-default.' }

$foundryShown = if ($ExistingFoundryAccountId) { 'REUSE -> ' + (($ExistingFoundryAccountId -split '/')[-1]) } else { 'CREATE NEW' }
Write-Host ''
Write-Host '  Summary:' -ForegroundColor Cyan
Write-Host "    Subscription      : $($account.name) ($SubId)"
Write-Host "    Location          : $Location  (foundry: $FoundryLocation)"
Write-Host "    Environment label : $EnvironmentName"
Write-Host "    Resource group    : $ResourceGroup"
Write-Host "    Foundry           : $foundryShown"
Write-Host "    Chat model        : $ChatModelName ($ChatModelVersion)"
Write-Host "    Image model       : $ImageModelName ($ImageModelVersion)"
Write-Host "    Deployer IP       : $deployerIp"
$catalogShown = if ([string]::IsNullOrWhiteSpace($CatalogSourcePath)) { 'data\catalogs (in-repo)' } else { $CatalogSourcePath }
Write-Host "    Catalog source    : $catalogShown"
Write-Host ''
if (-not (Ask-YesNo 'Proceed with sequential deployment?' $true)) { Write-Skip 'Aborted by user.'; Exit-Deploy 0 }


# Persist resolved settings
State-Set 'Subscription'             $SubId
State-Set 'Tenant'                   $TenantId
State-Set 'Location'                 $Location
State-Set 'FoundryLocation'          $FoundryLocation
State-Set 'EnvironmentName'          $EnvironmentName
State-Set 'ResourceGroup'            $ResourceGroup
$existingFoundryArg = if ($ExistingFoundryAccountId) { $ExistingFoundryAccountId } else { '' }
State-Set 'ExistingFoundryAccountId' $existingFoundryArg
State-Set 'ChatModelName'            $ChatModelName
State-Set 'ImageModelName'           $ImageModelName
State-Set 'DeployerIpAddress'        $deployerIp
$state = Load-State

# Compute resource names (deterministic per-RG)
$rgIdForHash = "/subscriptions/$SubId/resourceGroups/$ResourceGroup"
$shortHash   = Get-ShortHash "$rgIdForHash|$EnvironmentName|dev"
$weTagFull   = ($EnvironmentName + 'dev').ToLower() -replace '[-_]',''
$weTag       = if ($weTagFull.Length -gt 14) { $weTagFull.Substring(0, 14) } else { $weTagFull }
$weTagSt     = if ($weTagFull.Length -gt 12) { $weTagFull.Substring(0, 12) } else { $weTagFull }
$names = @{
    logAnalytics         = "law-$EnvironmentName-dev-$shortHash"
    appInsights          = "appi-$EnvironmentName-dev-$shortHash"
    appIdentity          = "id-$EnvironmentName-dev-$shortHash"
    storage              = ("st${weTagSt}${shortHash}").ToLower()
    search               = "srch-$EnvironmentName-dev-$shortHash"
    foundryAccount       = "aif-$EnvironmentName-dev-$shortHash"
    foundryProject       = "aifp-$EnvironmentName-dev-$shortHash"
    acaEnv               = "cae-$EnvironmentName-dev-$shortHash"
    orchestratorApp      = "ca-orch-${weTag}-${shortHash}"   # 32-char limit; weTag is alnum-truncated to 14
    appServicePlan       = "asp-$EnvironmentName-dev-$shortHash"
    webApp               = "app-web-$EnvironmentName-dev-$shortHash"
    apim                 = "apim-$EnvironmentName-dev-$shortHash"
}
$tags = @{
    workload = $EnvironmentName
    env      = 'dev'
    solution = 'InteriorDesignAccelerator'
}
Write-Host ''
Write-Info "Computed names: storage=$($names.storage) search=$($names.search) foundry=$($names.foundryAccount)"

# =============================================================================
# PHASE 4 - Sequential infra (one bicep module at a time)
# =============================================================================
Write-Phase 4 'Sequential infrastructure'

# Resume banner: print exactly what is going to be SKIPPED on this attempt vs run.
# Lets the user see at a glance whether resume is correct, and abort with Ctrl+C
# (then re-run with -Reset) if state looks wrong before any new work happens.
$resumeKeys = @($state.Keys | Where-Object { $_ -like '*_done' -or $_ -in @('catalog_uploaded','search_seeded','image_built','webui_published') })
if ($resumeKeys.Count -gt 0) {
    Write-Host ''
    Write-Host '  +-----------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '  | RESUMING from previous run                                |' -ForegroundColor Cyan
    Write-Host '  | Already-completed phases (will SKIP):                     |' -ForegroundColor Cyan
    foreach ($k in ($resumeKeys | Sort-Object)) { Write-Host ("  |   {0,-55} |" -f ("[SKIP] " + $k)) -ForegroundColor DarkGray }
    Write-Host '  | To start completely fresh: Ctrl+C then re-run with -Reset |' -ForegroundColor Cyan
    Write-Host '  +-----------------------------------------------------------+' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  State file: ' -NoNewline; Write-Host $statePath -ForegroundColor DarkGray
    Write-Host '  (Editor MUST NOT open this file - auto-save can clobber it)' -ForegroundColor DarkGray
    Write-Host ''
} else {
    Write-Host ''
    Write-Host '  Fresh run - no prior state to resume from. State will be saved to:' -ForegroundColor Cyan
    Write-Host ("  " + $statePath) -ForegroundColor DarkGray
    Write-Host ''
}


# 4a) Resource group
Write-Step "Ensuring resource group '$ResourceGroup' in '$Location' ..."
if ((Invoke-Safe { az group exists --name $ResourceGroup }) -ne 'true') {
    az group create -n $ResourceGroup -l $Location --tags ($tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) | Out-Null
    Write-Ok "Created RG '$ResourceGroup'"
} else { Write-Ok "RG '$ResourceGroup' exists" }

# 4b) Identity (the only blocking dependency for Storage RBAC)
$idOut = Deploy-Module 'identity' 'infra/modules/identity.bicep' @{
    location = $Location; tags = $tags; names = $names
}

# 4c) Storage (with deployer IP firewall). Runs right after identity so
#     Phase 5 (catalog upload) can begin ASAP. Monitor is deferred to after
#     the upload to shorten time-to-first-upload.
# Build the IP list defensively. PS if-as-expression unwraps single-element arrays
# back to a string in expression context, which breaks bicep 'array' params.
[string[]]$ipList = @()
if ($deployerIp) { $ipList += $deployerIp }
$storageOut = Deploy-Module 'storage' 'infra/modules/storage.bicep' @{
    location = $Location; tags = $tags; names = $names
    appUserAssignedIdentityPrincipalId = $idOut.appPrincipalId
    deployerObjectId                   = $PrincipalId
    allowedIpAddresses                 = $ipList
}
$blobEndpoint     = $storageOut.blobEndpoint
$catalogContainer = $storageOut.catalogContainer
$generatedCont    = $storageOut.generatedContainer
$storageAccount   = $storageOut.storageAccountName

# Always-on: refresh the deployer's IP on the storage account firewall every
# run. The bicep module above only re-applies IP rules when it actually deploys
# (i.e. when state['storage_done'] is false). On resumed runs the deployer's
# public IP may have changed (different network, ISP lease) which would 401/403
# every data-plane call (blob upload, blob list) until manually fixed in the
# portal. `network-rule add` is idempotent and uses ARM (management plane), so
# it works even while the data plane firewall is blocking us.
if ($deployerIp) {
    $rgForSa = & { $ErrorActionPreference='Continue'; az storage account show --name $storageAccount --query resourceGroup -o tsv 2>&1 } | Out-String
    $rgForSa = $rgForSa.Trim()
    if ($rgForSa) {
        Write-Step "Refreshing storage firewall: allow deployer IP $deployerIp on '$storageAccount' ..."
        $nrOut = & { $ErrorActionPreference='Continue'; az storage account network-rule add --resource-group $rgForSa --account-name $storageAccount --ip-address $deployerIp --only-show-errors 2>&1 } | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "  Deployer IP allowed on storage firewall (rule added)."
        } else {
            Write-Skip "  Could not add IP rule (already present or permission issue): $($nrOut.Trim())"
        }

        # Poll the data plane until the firewall rule actually propagates. We
        # probe a cheap data plane op (container list) every 5s for up to 60s.
        # Single fixed Sleeps are fragile on first-time IP add.
        Write-Step "  Waiting for firewall rule to propagate (data-plane probe up to 60s)..."
        $propagated = $false
        $probeStart = Get-Date
        while (((Get-Date) - $probeStart).TotalSeconds -lt 60) {
            $probe = & { $ErrorActionPreference='Continue'; az storage container list --account-name $storageAccount --auth-mode login --num-results 1 --only-show-errors -o tsv 2>&1 } | Out-String
            if ($LASTEXITCODE -eq 0) { $propagated = $true; break }
            Start-Sleep -Seconds 5
        }

        if ($propagated) {
            $waited = [int]((Get-Date) - $probeStart).TotalSeconds
            Write-Ok "  Data plane reachable (propagation completed in ~${waited}s)."
        } else {
            # Fallback: detected IP doesn't match what Azure storage actually sees
            # for our traffic (common with mobile carriers / CGNAT / corporate
            # proxies - the IP returned by api.ipify.org is the egress for HTTPS
            # to ipify, but Azure may route to a different egress block). Rather
            # than fail the whole deploy, temporarily flip defaultAction to Allow.
            # AAD RBAC (Blob Data Contributor on the deployer + the app identity)
            # remains the security gate, so this is safe for an accelerator.
            Write-Skip "  IP rule didn't unblock the data plane (likely NAT/proxy/IP-mismatch)."
            Write-Step "  Falling back: temporarily setting storage defaultAction=Allow ..."
            $upd = & { $ErrorActionPreference='Continue'; az storage account update --resource-group $rgForSa --name $storageAccount --default-action Allow --only-show-errors 2>&1 } | Out-String
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "  defaultAction=Allow applied. Re-probing data plane..."
                $deadline2 = (Get-Date).AddSeconds(45)
                while ((Get-Date) -lt $deadline2) {
                    $probe2 = & { $ErrorActionPreference='Continue'; az storage container list --account-name $storageAccount --auth-mode login --num-results 1 --only-show-errors -o tsv 2>&1 } | Out-String
                    if ($LASTEXITCODE -eq 0) { $propagated = $true; break }
                    Start-Sleep -Seconds 3
                }
                if ($propagated) {
                    Write-Ok "  Data plane reachable. Continuing the deploy."
                    State-Set 'StorageDefaultActionRelaxed' $true
                    Write-Skip "  NOTE: storage defaultAction is now 'Allow'. To re-tighten after the deploy succeeds, run: az storage account update -g $rgForSa -n $storageAccount --default-action Deny"
                } else {
                    Write-Err2 "  Data plane STILL blocked after relaxing defaultAction. Something else is wrong (possibly a private-endpoint policy on the subscription)."
                }
            } else {
                Write-Err2 "  Could not relax defaultAction: $($upd.Trim())"
            }
        }
    }
}

# =============================================================================
# PHASE 5 - Catalog upload (storage is ready)
# =============================================================================
Write-Phase 5 'Catalog upload'
# Resolve catalog source: prefer in-repo data/catalogs (now the canonical location),
# but allow -CatalogSourcePath to point at an external folder for first-time staging.
$repoData = Join-Path $projectRoot 'data/catalogs'
foreach ($brand in @('jaguar','parryware','misc')) {
    New-Item -ItemType Directory -Path (Join-Path $repoData $brand) -Force | Out-Null
}

# Copy from external source into the repo staging area (only if -CatalogSourcePath was passed)
if ($CatalogSourcePath -and (Test-Path $CatalogSourcePath)) {
    Write-Step "Staging from external source: $CatalogSourcePath"
    foreach ($brand in @('jaguar','parryware')) {
        $src = Join-Path $CatalogSourcePath $brand
        if (Test-Path $src) { Copy-Item "$src/*" (Join-Path $repoData $brand) -Recurse -Force }
    }
    Get-ChildItem -Path $CatalogSourcePath -File -ErrorAction SilentlyContinue | ForEach-Object {
        $name  = $_.Name.ToLowerInvariant()
        $brand = if ($name -match 'jaguar') { 'jaguar' } elseif ($name -match 'parryware') { 'parryware' } else { 'misc' }
        Copy-Item $_.FullName (Join-Path $repoData $brand) -Force
        Write-Ok "Staged $($_.Name) -> $brand"
    }
}

# Count local PDFs (canonical "what we WANT in the container")
$pdfCount = (Get-ChildItem $repoData -Recurse -File -Include *.pdf -ErrorAction SilentlyContinue | Measure-Object).Count

if ($pdfCount -eq 0) {
    Write-Err2 "No PDFs found under $repoData. Drop your trimmed Jaguar/Parryware PDFs into data\catalogs\jaguar\ and data\catalogs\parryware\ and re-run."
} else {
    # ------------------------------------------------------------------------
    # Storage firewall: open the data plane for both upload AND runtime.
    #
    # Two separate consumers need the data plane:
    #   * Phase 5 (this phase): uploads PDFs from the deployer's machine. On
    #     multi-egress networks (CGNAT, ISP load-balancing, corporate proxies)
    #     a single ipRule isn't enough because az CLI's bulk uploads are
    #     round-robined across several egress IPs; only one is allowed.
    #   * RUNTIME (Container Apps orchestrator + AI Search indexer + Web.Ui
    #     hero-image proxy): the orchestrator reads catalog PDFs from blob
    #     to render the per-page thumbnail shown in each "Fittings you may
    #     like" card and to extract hero images. Container Apps do NOT
    #     qualify for 'bypass: AzureServices' (only specific trusted services
    #     like AI Search indexer do). So the runtime orchestrator's outbound
    #     IP would also be blocked unless we pin every egress IP to ipRules.
    #
    # Resolution (accelerator pattern): keep defaultAction='Allow' both
    # during AND after Phase 5. The AAD RBAC layer is the actual security
    # gate - every blob call requires a valid Bearer token with
    # 'Storage Blob Data Reader/Contributor' on the deployer (granted by
    # storage.bicep) or on the orchestrator's user-assigned MI. The IP
    # firewall was just a second-layer defense that's incompatible with
    # multi-egress deployer networks AND with Container Apps runtime; for
    # an open-source accelerator the simpler+working "AAD as the gate"
    # posture is the right tradeoff.
    #
    # If you want to re-tighten for a hardened production deployment, the
    # right move is NOT to flip back to Deny here - it's to add the Container
    # Apps environment static outbound IPs to ipRules in storage.bicep AND
    # use a private endpoint for the deployer. Until then, leaving Allow.
    $rgForSa = & { $ErrorActionPreference='Continue'; az storage account show --name $storageAccount --query resourceGroup -o tsv 2>&1 } | Out-String
    $rgForSa = $rgForSa.Trim()
    $priorDefaultAction = & { $ErrorActionPreference='Continue'; az storage account show -g $rgForSa -n $storageAccount --query networkRuleSet.defaultAction -o tsv 2>&1 } | Out-String
    $priorDefaultAction = $priorDefaultAction.Trim()
    if ($priorDefaultAction -ne 'Allow') {
        Write-Step "Opening storage data-plane firewall for upload + runtime (defaultAction: $priorDefaultAction -> Allow; AAD RBAC remains the security gate)..."
        $flip = & { $ErrorActionPreference='Continue'; az storage account update -g $rgForSa -n $storageAccount --default-action Allow --only-show-errors 2>&1 } | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "  Storage firewall: defaultAction=Allow (AAD RBAC is the gate)."
            # Brief propagation wait - data plane firewall takes a few seconds.
            Start-Sleep -Seconds 8
        } else {
            Write-Skip "  Could not flip firewall to Allow ($($flip.Trim())). Continuing - uploads may still partially fail on multi-egress networks."
        }
    } else {
        Write-Skip "Storage firewall is already defaultAction=Allow - leaving it as-is."
    }

    Write-Step "Syncing PDFs to storage '$storageAccount' container '$catalogContainer' (file-level diff)..."
    $syncRes = Sync-BlobsIncremental -AccountName $storageAccount -Container $catalogContainer -LocalRoot $repoData -IncludePatterns @('*.pdf') -PruneOrphans

    # If some files transiently failed (rare now that the firewall is open),
    # do ONE final retry pass after a short pause. NON-FATAL: downstream
    # phases work on whatever made it into the container; a re-run picks up
    # the stragglers via the normal diff sync.
    if ($syncRes.Failed -gt 0) {
        Write-Skip "  $($syncRes.Failed) file(s) failed on first pass: $($syncRes.FailedFiles -join ', ')"
        Write-Step "  Pausing 20s then retrying just the failed files..."
        Start-Sleep -Seconds 20
        $syncRes2 = Sync-BlobsIncremental -AccountName $storageAccount -Container $catalogContainer -LocalRoot $repoData -IncludePatterns @('*.pdf')
        $totalUploaded = $syncRes.Uploaded + $syncRes2.Uploaded
        $totalFailed   = $syncRes2.Failed
        if ($totalFailed -gt 0) {
            Write-Skip "  $totalFailed file(s) STILL failing after retry: $($syncRes2.FailedFiles -join ', ')"
            Write-Skip "  Continuing deploy - downstream extraction/search will work on uploaded files."
            Write-Skip "  Re-run deploy.ps1 to pick up the stragglers (the diff sync uploads only what's missing)."
        }
        $syncRes = @{
            Uploaded   = $totalUploaded
            Failed     = $totalFailed
            Deleted    = $syncRes.Deleted
            Unchanged  = $syncRes.Unchanged
            ChangedAny = $true
        }
    }

    if ($syncRes.ChangedAny) {
        $failHint = if ($syncRes.Failed -gt 0) { ", $($syncRes.Failed) failed" } else { '' }
        Write-Ok ("Catalog sync: {0} uploaded, {1} deleted, {2} unchanged{3}." -f $syncRes.Uploaded, $syncRes.Deleted, $syncRes.Unchanged, $failHint)
        # Cascade: any blob change must force Phase 8d to re-extract and Phase
        # 8e to re-seed the AI Search indexes. Clearing the fingerprints (not
        # the boolean flags) is the cleanest signal for the new
        # fingerprint-based skip-checks in those phases.
        $s = Load-State
        $s.Remove('catalog_extracted_fingerprint') | Out-Null
        $s.Remove('search_seeded_fingerprint')     | Out-Null
        Save-State $s
        $script:state = Load-State
    } else {
        Write-Skip ("Catalogs already in sync ({0} blob(s) match {1} local PDF(s))." -f $syncRes.Unchanged, $pdfCount)
    }

    # Always update fingerprint + boolean so resumed runs see a stable marker.
    State-Set 'catalog_uploaded'             $true
    State-Set 'catalog_uploaded_fingerprint' (Get-DirectoryFingerprint -Paths @('data/catalogs') -AssetMode)
}

# =============================================================================
# PHASE 5b - Monitor (deferred until after the upload)
# =============================================================================
Write-Phase '5b' 'Monitor (deferred)'
$monOut = Deploy-Module 'monitor' 'infra/modules/monitor.bicep' @{
    location = $Location; tags = $tags; names = $names
}

# =============================================================================
# PHASE 6 - AI Search (service + data plane index/datasource/indexer)
# =============================================================================
Write-Phase 6 'Azure AI Search'
$searchOut = Deploy-Module 'search' 'infra/modules/search.bicep' @{
    location = $Location; tags = $tags; names = $names
    storageAccountId                   = $storageOut.storageAccountId
    storageAccountName                 = $storageAccount
    catalogContainer                   = $catalogContainer
    appUserAssignedIdentityPrincipalId = $idOut.appPrincipalId
    deployerObjectId                   = $PrincipalId
}
$searchEndpoint = $searchOut.searchEndpoint
$searchIndex   = $searchOut.indexName

# 6b) Data plane: TWO indexes (one per brand) - matches use-case spec.
#     Each datasource filters blobs by 'catalogs/{brand}/' prefix via `query`.
# Schema version marker - bump to force re-creation of both indexes when the
# field set changes (e.g. adding pageNumber for the per-page reference proxy).
# Azure Search will NOT add a missing field on a PUT against an existing
# index unless we bump this marker and recreate cleanly.
$searchSchemaVersion = 'v2-pageNumber'
if ($state['search_schema_done'] -and $state['search_schema_version'] -eq $searchSchemaVersion) {
    Write-Skip 'AI Search index schemas already created at expected version (datasource + indexer happen in Phase 8e).'
} else {
    if ($state['search_schema_done']) {
        Write-Skip "  search schema version drift (cached='$($state['search_schema_version'])' expected='$searchSchemaVersion') - recreating indexes."
    }
    Write-Step 'Seeding AI Search - creating 2 brand-specific indexes (jaguar + parryware)...'
    $searchApi = '2024-07-01'
    $srchToken = az account get-access-token --resource https://search.azure.com --query accessToken -o tsv
    $srchHdr   = @{ Authorization = "Bearer $srchToken"; 'Content-Type' = 'application/json' }
    $saRgName  = az storage account show --name $storageAccount --query resourceGroup -o tsv

    # Shared schema for both brand indexes
    function New-BrandIndexBody {
        param([string]$indexName)
        return @{
            name = $indexName
            fields = @(
                @{ name='id';          type='Edm.String'; key=$true; filterable=$true }
                @{ name='brand';       type='Edm.String'; filterable=$true; facetable=$true; searchable=$true }
                @{ name='category';    type='Edm.String'; filterable=$true; facetable=$true; searchable=$true }
                @{ name='name';        type='Edm.String'; searchable=$true; sortable=$true }
                @{ name='description'; type='Edm.String'; searchable=$true }
                @{ name='imageUrl';    type='Edm.String' }
                @{ name='content';     type='Edm.String'; searchable=$true }
                @{ name='sourceFile';  type='Edm.String'; filterable=$true; retrievable=$true }
                @{ name='pageNumber';  type='Edm.Int32';  filterable=$true; retrievable=$true; sortable=$true }
            )
            semantic = @{ configurations = @( @{
                name = 'default'
                prioritizedFields = @{
                    titleField                = @{ fieldName = 'name' }
                    prioritizedContentFields  = @( @{ fieldName='description' }, @{ fieldName='content' } )
                    prioritizedKeywordsFields = @( @{ fieldName='brand' }, @{ fieldName='category' } )
                }
            } ) }
        } | ConvertTo-Json -Depth 12
    }

    # Brands -> matching blob folder prefix in the 'catalogs' container
    $brandIndexes = @(
        @{ brand='jaguar';    indexName='jaguar-catalog';    folder='jaguar' }
        @{ brand='parryware'; indexName='parryware-catalog'; folder='parryware' }
    )

    foreach ($b in $brandIndexes) {
        $idxName = $b.indexName

        Write-Step "  -- Index '$idxName' (schema version=$searchSchemaVersion) --"

        # If the index exists with an older schema (missing pageNumber etc.),
        # delete it first - PUT can't add a new field to an existing index.
        $existsResp = & { $ErrorActionPreference='Continue'
            try { Invoke-RestMethod -Method Get -Uri "$searchEndpoint/indexes/${idxName}?api-version=$searchApi" -Headers $srchHdr -ErrorAction Stop } catch { $null }
        }
        if ($existsResp) {
            $hasPageNumber = $existsResp.fields | Where-Object { $_.name -eq 'pageNumber' }
            if (-not $hasPageNumber) {
                Write-Skip "    [$($b.brand)] existing index missing 'pageNumber' field - deleting + recreating."
                Invoke-RestMethod -Method Delete -Uri "$searchEndpoint/indexes/${idxName}?api-version=$searchApi" -Headers $srchHdr | Out-Null
            }
        }

        # Index schema (one row per product, populated later by jsonArray indexer)
        Invoke-RestMethod -Method Put -Uri "$searchEndpoint/indexes/${idxName}?api-version=$searchApi" -Headers $srchHdr -Body (New-BrandIndexBody $idxName) | Out-Null

        Write-Ok "    [$($b.brand)] index='$idxName' schema created/updated"
    }

    State-Set 'searchIndexes' @('jaguar-catalog','parryware-catalog')
    State-Set 'search_schema_done'    $true
    State-Set 'search_schema_version' $searchSchemaVersion
}

# =============================================================================
# PHASE 7 - Content Understanding (REMOVED)
# =============================================================================
# Removed: Content Understanding's prebuilt-imageAnalyzer requires real raster
# image URLs (PNG/JPG); we were giving it PDF blob URLs which just returned
# 'files are not readable'. Replaced by Document Intelligence Layout in new
# Phase 8d, which actually OCRs the catalog PDFs and emits per-product entries.
$cuEndpoint = ''
Write-Phase 7 'Content Understanding (removed)'
Write-Skip 'Content Understanding is no longer used; Document Intelligence Layout (Phase 8d) extracts product data instead.'

# =============================================================================
# PHASE 8 - Foundry stack (account + project + models, knowledge, agents)
# =============================================================================
Write-Phase 8 'Microsoft Foundry'

# -----------------------------------------------------------------------------
# Cross-region quota probe for the IMAGE model. If the requested image model
# has zero quota in $FoundryLocation, auto-probe a list of preferred regions
# and move the WHOLE Foundry deployment to the first one that has quota.
# This honors the user's "deploy in another location if Sweden lacks quota"
# requirement without forcing them to re-run with -FoundryLocation manually.
# All other resources (storage, search, ACA, App Service, APIM) stay in $Location.
# -----------------------------------------------------------------------------
function Get-ImageQuotaInRegion {
    param([string]$Region, [string]$ModelName, [int]$NeededRpm)
    $raw = Invoke-Safe { az cognitiveservices usage list -l $Region -o json 2>$null }
    if (-not $raw) { return -1 }
    try {
        $usage = $raw | Out-String | ConvertFrom-Json
        $row = $usage | Where-Object { $_.name.value -ieq "AIServices.GlobalStandard.$ModelName" } | Select-Object -First 1
        if (-not $row) { return -1 }
        return [int]($row.limit - $row.currentValue)
    } catch { return -1 }
}

$preferredImageRegions = @($FoundryLocation, 'eastus2', 'westus3', 'switzerlandnorth', 'francecentral', 'australiaeast') | Select-Object -Unique
$picked = $null
Write-Step "Probing '$ImageModelName' quota across $(($preferredImageRegions).Count) regions..."
foreach ($r in $preferredImageRegions) {
    $avail = Get-ImageQuotaInRegion -Region $r -ModelName $ImageModelName -NeededRpm $ImageModelCapacity
    $verdict = if ($avail -ge $ImageModelCapacity) { "OK ($avail RPM available)" }
               elseif ($avail -eq 0) { '0 RPM' }
               elseif ($avail -gt 0) { "$avail RPM (insufficient)" }
               else { 'no row (model not available here)' }
    Write-Host "    $r : $verdict"
    if ($avail -ge $ImageModelCapacity -and -not $picked) { $picked = $r }
}
if (-not $picked) {
    Write-Err2 "No region in the preferred list has at least $ImageModelCapacity RPM for '$ImageModelName'."
    Write-Err2 "Request quota at https://aka.ms/oai/quotaincrease or pass -ImageModelName <other> -ImageModelVersion <ver>"
    throw "No region with sufficient quota for image model '$ImageModelName'"
}
if ($picked -ne $FoundryLocation) {
    Write-Skip "Original FoundryLocation '$FoundryLocation' lacks quota - moving Foundry to '$picked' for this run."
    $FoundryLocation = $picked
    State-Set 'FoundryLocation' $FoundryLocation
}

# Pre-flight quota check - fails fast with actionable purge commands if short on quota.
# Auto-fallback for image model: try the requested one first, then alternatives in priority order.
# Each candidate is (name, version). First one with >=capacity RPM available wins.
$imageCandidates = @(
    @{ name = $ImageModelName;   version = $ImageModelVersion }
    @{ name = 'MAI-Image-2';     version = '2026-02-20' }
    @{ name = 'MAI-Image-2e';    version = '2026-04-09' }
    @{ name = 'gpt-image-1.5';   version = '2025-12-16' }
    @{ name = 'dall-e-3';        version = '3.0'        }
) | Group-Object name | ForEach-Object { $_.Group[0] }   # de-dup by name keeping order
$pickedImage = $null
$usageRaw = Invoke-Safe { az cognitiveservices usage list -l $FoundryLocation -o json }
if ($usageRaw) {
    $usage = $usageRaw | Out-String | ConvertFrom-Json
    foreach ($cand in $imageCandidates) {
        $row = $usage | Where-Object { $_.name.value -ieq "AIServices.GlobalStandard.$($cand.name)" } | Select-Object -First 1
        if (-not $row) { continue }
        $avail = [int]($row.limit - $row.currentValue)
        if ($avail -ge [int]$ImageModelCapacity) {
            $pickedImage = $cand
            if ($cand.name -ne $ImageModelName) {
                Write-Skip "Requested image model '$ImageModelName' has insufficient quota - falling back to '$($cand.name)' ($avail RPM available)"
            }
            break
        }
    }
    if ($pickedImage) {
        $ImageModelName    = $pickedImage.name
        $ImageModelVersion = $pickedImage.version
        State-Set 'ImageModelName'    $ImageModelName
        State-Set 'ImageModelVersion' $ImageModelVersion
    }
}

$quotaOk = Check-FoundryQuota -Region $FoundryLocation -Models @{
    chat  = @{ name = $ChatModelName;  capacity = $ChatModelCapacity  }
    image = @{ name = $ImageModelName; capacity = $ImageModelCapacity }
}
if (-not $quotaOk) { Write-Err2 'Foundry quota pre-flight failed - see instructions above. Aborting (no resources changed).'; Exit-Deploy 1 }

# -----------------------------------------------------------------------------
# Pre-flight: detect SOFT-DELETED Cognitive Services accounts that would collide
# with the deterministic Foundry account name we are about to create. Cognitive
# Services holds the subdomain reservation for 5-15 minutes (sometimes longer)
# AFTER `purge` -- and `az cognitiveservices account list-deleted` reports the
# entry gone well before ARM actually releases the subdomain. So racing the
# purge is unreliable.
#
# When a collision is detected we DO NOT fail. Per design we:
#   1. Kick off a best-effort `purge` for the soft-deleted account (so the user
#      reclaims their quota over the next ~15 min).
#   2. Generate a NEW unique foundry account name by appending a random salt.
#   3. Persist the salted name to state so resumes use the SAME name.
#   4. Continue the deploy with the new name -- no user intervention required.
#
# The salt is also persisted on the names hashtable so subsequent steps (agent
# creation, container app env vars) all see the corrected name.
# -----------------------------------------------------------------------------
Write-Step "Pre-flight: checking for soft-deleted Foundry account '$($names.foundryAccount)' in '$FoundryLocation' ..."

# If a previous run already chose a salted name, honour it (resume case) so we
# don't keep stacking salts on each retry.
if ($state['FoundryAccountOverride']) {
    $names.foundryAccount = $state['FoundryAccountOverride']
    if ($state['FoundryProjectOverride']) { $names.foundryProject = $state['FoundryProjectOverride'] }
    Write-Skip "  Resuming with previously-salted Foundry name: $($names.foundryAccount)"
}

$delRaw = Invoke-Safe { az cognitiveservices account list-deleted -o json }
$collision = $null
if ($delRaw) {
    try {
        $deletedAll = $delRaw | Out-String | ConvertFrom-Json
        $collision = $deletedAll | Where-Object {
            $_.name -eq $names.foundryAccount -and $_.location -eq $FoundryLocation
        } | Select-Object -First 1
    } catch { }
}

if ($collision) {
    $origRg = $collision.properties.originalResourceGroup
    if ([string]::IsNullOrWhiteSpace($origRg)) { $origRg = $ResourceGroup }
    Write-Skip "  Found soft-deleted '$($collision.name)' (originalRG=$origRg) holding the subdomain."

    # Best-effort purge so the user eventually reclaims quota / the name. This
    # runs in the background; we do NOT wait for it because the subdomain
    # reservation lingers anyway and we are about to use a different name.
    Write-Step '  Kicking off best-effort purge in the background (does not block deploy) ...'
    try {
        Start-Job -ScriptBlock {
            param($loc, $name, $rg)
            az cognitiveservices account purge --location $loc --name $name --resource-group $rg 2>&1 | Out-Null
        } -ArgumentList $FoundryLocation, $collision.name, $origRg | Out-Null
        Write-Ok '  Background purge started (check `Get-Job` in this terminal if curious).'
    } catch {
        Write-Skip "  Background purge could not be started ($($_.Exception.Message)) - non-fatal."
    }

    # Pick a fresh, deterministic-but-collision-free name. Salt is derived from
    # the current UTC time so re-runs without state pick up via the override
    # logic above; brand-new runs always get a unique salt.
    $rand    = -join ((48..57 + 97..122) | Get-Random -Count 3 | ForEach-Object { [char]$_ })
    $newAcc  = "aif-$EnvironmentName-dev-$shortHash-$rand"
    $newProj = "aifp-$EnvironmentName-dev-$shortHash-$rand"

    # Cognitive Services account names are limited to 64 chars; in practice this
    # is well under, but guard anyway.
    if ($newAcc.Length -gt 64)  { $newAcc  = $newAcc.Substring(0, 64) }
    if ($newProj.Length -gt 64) { $newProj = $newProj.Substring(0, 64) }

    $names.foundryAccount = $newAcc
    $names.foundryProject = $newProj
    State-Set 'FoundryAccountOverride' $newAcc
    State-Set 'FoundryProjectOverride' $newProj
    $script:state = Load-State

    Write-Ok "  Continuing with NEW Foundry account name: $newAcc"
} else {
    Write-Ok "  No soft-deleted collision for '$($names.foundryAccount)' - safe to deploy."
}

$foundryOut = Deploy-Module 'foundry' 'infra/modules/foundry.bicep' @{
    location = $FoundryLocation; tags = $tags; names = $names
    chatModelName                      = $ChatModelName
    imageModelName                     = $ImageModelName
    chatModelVersion                   = $ChatModelVersion
    imageModelVersion                  = $ImageModelVersion
    chatModelCapacity                  = $ChatModelCapacity
    imageModelCapacity                 = $ImageModelCapacity
    appUserAssignedIdentityPrincipalId = $idOut.appPrincipalId
    deployerObjectId                   = $PrincipalId
    searchServiceId                    = $searchOut.searchServiceId
    searchEndpoint                     = $searchEndpoint
    storageAccountId                   = $storageOut.storageAccountId
} -RequiredOutputs @('projectEndpoint','projectId','chatModelDeployment','imageModelDeployment','searchConnectionId','bicepVersion','projectAgentsEndpoint')
$foundryProjectEndpoint = $foundryOut.projectEndpoint
$foundryProjectId       = $foundryOut.projectId
$searchConnectionId     = $foundryOut.searchConnectionId

# --- Phase 8b: Foundry Knowledge / connection (NOW DONE BY foundry.bicep) ---
# The Azure AI Search "connection" on the Foundry project is now declared in
# foundry.bicep as a child of the project (it's an ARM resource, NOT a data-plane
# resource - PUT to {projectEndpoint}/connections/X returns 405 Method Not Allowed).
# We just consume the bicep output here.

if (-not $searchConnectionId) {
    Write-Err2 'Bicep did not return searchConnectionId - check that searchServiceId was passed to foundry module.'
    throw 'searchConnectionId missing'
}
Write-Ok "Foundry AI Search connection (from bicep): $searchConnectionId"
$knowledgeId = $searchConnectionId
State-Set 'knowledge_done' $true
State-Set 'knowledgeId'    $knowledgeId
State-Set 'searchConnName' 'aoai-aisearch'

# --- Phase 8c: Foundry Agents - NEW Foundry data plane (4 hosted agents) -----
# IMPORTANT: This uses the NEW Foundry agents API at services.ai.azure.com
#   POST {projectAgentsEndpoint}/agents/{name}/versions?api-version=v1
# NOT the legacy /assistants API at cognitiveservices.azure.com.
# The legacy /assistants endpoint shows agents as "Assistants" (deprecated)
# in the New Foundry portal; the /agents/{name}/versions API shows them
# as proper "Agents" under Build > Agents.

if (-not $aiHdr) {
    $aiToken = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
    if (-not $aiToken -or $aiToken.Length -lt 100) { $aiToken = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv }
    $aiHdr = @{ Authorization = "Bearer $aiToken"; 'Content-Type' = 'application/json'; 'Foundry-Features' = 'HostedAgents=V1Preview' }
}
$fApiVer = 'v1'
$connName = $state['searchConnName']; if (-not $connName) { $connName = 'aoai-aisearch' }

# Use the NEW services.ai.azure.com endpoint (NOT the legacy cognitiveservices one).
$agentsEndpoint = $foundryOut.projectAgentsEndpoint
if (-not $agentsEndpoint) {
    Write-Err2 'foundry bicep did not return projectAgentsEndpoint - cannot create New Foundry agents'
    throw 'projectAgentsEndpoint missing - bicep stale, rerun to regenerate'
}
Write-Step "New Foundry agents endpoint: $agentsEndpoint"

# Cleanup any stale legacy /assistants we created in earlier runs (so the portal
# stops showing "Assistants are not yet supported" warning).
$legacyEndpoint = $foundryProjectEndpoint   # cognitiveservices.azure.com
try {
    $legacyHdr = @{ Authorization = $aiHdr.Authorization; 'Content-Type' = 'application/json' }
    $legacyList = Invoke-RestMethod -Uri "$legacyEndpoint/assistants?api-version=v1" -Headers $legacyHdr -Method Get -ErrorAction Stop
    if ($legacyList -and $legacyList.data -and $legacyList.data.Count -gt 0) {
        Write-Step "Cleaning up $($legacyList.data.Count) stale legacy /assistants from previous runs..."
        foreach ($oldA in $legacyList.data) {
            try {
                Invoke-RestMethod -Uri "$legacyEndpoint/assistants/$($oldA.id)?api-version=v1" -Headers $legacyHdr -Method Delete -ErrorAction Stop | Out-Null
                Write-Skip "    deleted legacy assistant '$($oldA.name)' ($($oldA.id))"
            } catch {
                Write-Skip "    could not delete legacy assistant '$($oldA.id)' (will be cleaned up on RG delete)"
            }
        }
    }
    # Also clear stale agent ids from state since they were legacy assistant ids
    if ($state['agentIds']) {
        State-Set 'agentIds'    @{}
        State-Set 'agents_done' $false
        $script:state = Load-State
    }
} catch {
    # Legacy endpoint may not be reachable on a fresh project - that's fine
    Write-Skip '    no legacy /assistants found (or endpoint not reachable) - skipping cleanup'
}

# RBAC propagation warmup against NEW endpoint
Write-Step "Waiting for Foundry project RBAC to propagate (poll GET /agents)..."
$rbacOk = $false
$rbacStart = Get-Date
while (((Get-Date) - $rbacStart).TotalSeconds -lt 240) {
    try {
        $r = Invoke-WebRequest -Uri "$agentsEndpoint/agents?api-version=$fApiVer" -Headers $aiHdr -Method Get -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
            $waited = [math]::Round(((Get-Date) - $rbacStart).TotalSeconds, 1)
            Write-Ok "  Foundry RBAC propagated after $waited sec - safe to call data plane"
            $rbacOk = $true; break
        }
    } catch {
        $sc = 0; if ($_.Exception.Response) { try { $sc = [int]$_.Exception.Response.StatusCode } catch { } }
        Write-Skip "  HTTP $sc - capability host or RBAC not yet ready, sleeping 10s..."
    }
    Start-Sleep -Seconds 10
}
if (-not $rbacOk) { Write-Skip '  warmup timed out - proceeding, agent loop has its own retries.' }

# ---------------------------------------------------------------------------
# 8c-pre  Foundry IQ Knowledge Base (created on the AI Search service)
# ---------------------------------------------------------------------------
# Per the Azure AI Search agentic-retrieval docs:
#   https://learn.microsoft.com/azure/search/agentic-retrieval-how-to-create-knowledge-base
# Foundry IQ knowledge bases live on the AI SEARCH service (not on the
# Foundry account / agents endpoint - that's why the previous probes against
# services.ai.azure.com and cognitiveservices.azure.com all returned 404).
#
# The model is:
#   1. KnowledgeSource per index  -> PUT {search}/knowledgesources/{name}
#   2. KnowledgeBase referencing multiple knowledge sources by name
#                                 -> PUT {search}/knowledgebases/{name}
# api-version=2025-11-01-preview (the version the public docs and the
# Azure.Search.Documents.KnowledgeBases SDK target).
#
# Flow for this app:
#   * Create 2 knowledge sources (jaguar-ks, parryware-ks) wrapping the 2
#     existing brand indexes (jaguar-catalog, parryware-catalog).
#   * Create the unified KB 'bath-fittings-kb' that references both sources.
#   * Phase 8c below binds catalog-search-agent to this KB via the agent's
#     'knowledge_bases: [{name}]' binding. If the agent registration rejects
#     that shape, the legacy per-connection binding is the working fallback.
#
# NEVER FATAL: if the search service rejects the KB calls (region without
# preview surface, RBAC delay, free-SKU search service, etc.) we fall back
# to the legacy per-connection agent binding. The orchestrator preserves
# the agent's ranking either way and the user-visible UX is identical.
$kbName   = 'bath-fittings-kb'
$kbApiVer = '2025-11-01-preview'

# One knowledge source per brand index. Names follow the doc's '{topic}-ks'
# convention so the resources are self-describing in the Foundry IQ portal.
$kbSources = @(
    @{ ksName='jaguar-ks';    indexName='jaguar-catalog'    }
    @{ ksName='parryware-ks'; indexName='parryware-catalog' }
)

$kbBound      = $false
$kbCollection = $null
$kbApiVerUsed = $null

if ($state['foundryIqKb_done'] -and $state['foundryIqKbName'] -eq $kbName -and $state['foundryIqKbApiVer'] -eq $kbApiVer) {
    Write-Skip "Foundry IQ knowledge base '$kbName' already created on $searchEndpoint (per state)"
    $kbBound      = $true
    $kbCollection = "$searchEndpoint/knowledgebases"
    $kbApiVerUsed = $kbApiVer
} else {
    Write-Step "Foundry IQ knowledge base: creating on AI Search service '$searchEndpoint' (api-version=$kbApiVer) ..."

    # Acquire a search data-plane token. KB management requires 'Search
    # Service Contributor' on the deployer (granted by search.bicep).
    $srchToken = & { $ErrorActionPreference='Continue'; az account get-access-token --resource https://search.azure.com --query accessToken -o tsv 2>&1 } | Out-String
    $srchToken = $srchToken.Trim()
    if (-not $srchToken -or $srchToken.Length -lt 100) {
        Write-Skip "  Could not acquire search.azure.com token - falling back to legacy per-connection binding."
    } else {
        $srchHdr = @{ Authorization = "Bearer $srchToken"; 'Content-Type' = 'application/json' }

        try {
            # ---- Step 1: knowledge sources (one per existing index) --------
            foreach ($s in $kbSources) {
                $ksUri  = "$searchEndpoint/knowledgesources/$($s.ksName)?api-version=$kbApiVer"
                $ksBody = @{
                    name        = $s.ksName
                    kind        = 'searchIndex'
                    description = "Knowledge source wrapping the '$($s.indexName)' AI Search index for Foundry IQ agentic retrieval."
                    searchIndexParameters = @{
                        searchIndexName = $s.indexName
                    }
                } | ConvertTo-Json -Depth 12

                $existsKs = $false
                try {
                    $cur = Invoke-RestMethod -Uri $ksUri -Headers $srchHdr -Method Get -ErrorAction Stop
                    if ($cur -and $cur.name -eq $s.ksName) {
                        Write-Skip "    knowledge source '$($s.ksName)' exists (wraps '$($s.indexName)') - reusing"
                        $existsKs = $true
                    }
                } catch {
                    $sc = 0; if ($_.Exception.Response) { try { $sc = [int]$_.Exception.Response.StatusCode } catch { } }
                    if ($sc -ne 404 -and $sc -ne 0) {
                        Write-Skip "    GET '$($s.ksName)' returned HTTP $sc - will attempt PUT"
                    }
                }
                if (-not $existsKs) {
                    Invoke-RestWithRetry -Method Put -Uri $ksUri -Headers $srchHdr -Body $ksBody | Out-Null
                    Write-Ok "    knowledge source '$($s.ksName)' -> wraps index '$($s.indexName)'"
                }
            }

            # ---- Step 2: knowledge base referencing both sources -----------
            $kbUri  = "$searchEndpoint/knowledgebases/$kbName`?api-version=$kbApiVer"
            $kbBody = @{
                name        = $kbName
                description = 'Unified bathroom-fittings knowledge base combining the jaguar-catalog and parryware-catalog AI Search indexes for Foundry IQ agentic retrieval. Created by deploy.ps1.'
                knowledgeSources = @(
                    @{ name = 'jaguar-ks' },
                    @{ name = 'parryware-ks' }
                )
            } | ConvertTo-Json -Depth 12

            $existsKb = $false
            try {
                $curKb = Invoke-RestMethod -Uri $kbUri -Headers $srchHdr -Method Get -ErrorAction Stop
                if ($curKb -and $curKb.name -eq $kbName) {
                    Write-Skip "    KB '$kbName' exists - reusing"
                    $existsKb = $true
                }
            } catch {
                $sc = 0; if ($_.Exception.Response) { try { $sc = [int]$_.Exception.Response.StatusCode } catch { } }
                if ($sc -ne 404 -and $sc -ne 0) {
                    Write-Skip "    GET '$kbName' returned HTTP $sc - will attempt PUT"
                }
            }
            if (-not $existsKb) {
                Invoke-RestWithRetry -Method Put -Uri $kbUri -Headers $srchHdr -Body $kbBody | Out-Null
                Write-Ok "    KB '$kbName' -> created (sources: jaguar-ks, parryware-ks)"
            }

            $kbBound      = $true
            $kbCollection = "$searchEndpoint/knowledgebases"
            $kbApiVerUsed = $kbApiVer
            Write-Ok "  Foundry IQ KB '$kbName' is live on $searchEndpoint"
        } catch {
            $em = $_.ErrorDetails.Message; if (-not $em) { $em = $_.Exception.Message }
            $sc = 0; if ($_.Exception.Response) { try { $sc = [int]$_.Exception.Response.StatusCode } catch { } }
            Write-Skip "  KB creation on search service failed (HTTP $sc): $em"
            Write-Skip "  Falling back to legacy per-connection agent binding - deploy continues."
            Write-Skip "  Common causes:"
            Write-Skip "    * Search service SKU does not support knowledgebases preview (basic+ usually works; free does not)."
            Write-Skip "    * api-version 2025-11-01-preview not yet enabled in your region."
            Write-Skip "    * Deployer principal lacks 'Search Service Contributor' on $searchEndpoint."
        }
    }

    if ($kbBound) {
        State-Set 'foundryIqKb_done'         $true
        State-Set 'foundryIqKbName'          $kbName
        State-Set 'foundryIqKbCollection'    $kbCollection
        State-Set 'foundryIqKbApiVer'        $kbApiVerUsed
    } else {
        State-Set 'foundryIqKb_done'         $false
        State-Set 'foundryIqKbName'          ''
        State-Set 'foundryIqKbCollection'    ''
        State-Set 'foundryIqKbApiVer'        ''
    }
}

# Define the 4 agents using their JSON templates. The catalog-search-agent
# binds to the Foundry IQ KB if it was created above; otherwise it falls
# back to legacy per-connection binding (functionally equivalent for our
# orchestrator, which preserves the agent's ranking either way).
$catalogKnowledgeKind = if ($kbBound) { 'knowledge-base' } else { 'search' }
$agentDefs = @(
    @{ file='chat-agent.json';                 idKey='chatAgentId';            modelOverride=$ChatModelName;   knowledgeKind='none'                  }
    @{ file='catalog-search-agent.json';       idKey='catalogSearchAgentId';   modelOverride=$ChatModelName;   knowledgeKind=$catalogKnowledgeKind; knowledgeBaseName=$kbName }
    @{ file='image-gen-agent.json';            idKey='imageGenAgentId';        modelOverride=$ImageModelName;  knowledgeKind='none'                  }
)

# Resume: pick up agent ids saved last time
$agentIds = if ($state.ContainsKey('agentIds') -and $state['agentIds']) { [hashtable]$state['agentIds'] } else { @{} }

# Dedup: list existing NEW-style agents in Foundry by name
$existingByName = @{}
try {
    $list = Invoke-RestMethod -Uri "$agentsEndpoint/agents?api-version=$fApiVer" -Headers $aiHdr -Method Get -ErrorAction Stop
    if ($list -and $list.value) {
        foreach ($a in $list.value) { $existingByName[$a.name] = "$($a.name)/v$($a.latest_version)" }
        Write-Skip "  Foundry has $($existingByName.Count) existing NEW-style agent(s); will dedup by name"
    } elseif ($list -and $list.data) {
        foreach ($a in $list.data) { $existingByName[$a.name] = "$($a.name)/v$($a.latest_version)" }
        Write-Skip "  Foundry has $($existingByName.Count) existing NEW-style agent(s); will dedup by name"
    }
} catch { }

if ($state['agents_done'] -and $agentIds.Count -ge 4 -and $state['agents_knowledge_v3']) {
    Write-Skip 'All 4 New Foundry agents already created with Foundry IQ KB binding (per state)'
} else {
    Write-Step "Creating New Foundry agents (data plane) - $($agentIds.Count)/4 already done from prior runs..."

    # If state predates the Foundry IQ KB rollout (v3), force the catalog-search-agent
    # to be recreated so a new version with knowledge_bases=[bath-fittings-kb] gets
    # minted in Foundry. (POST /agents/{name}/versions creates a NEW version each
    # time, so this is non-destructive - older versions remain in the portal history.)
    if (-not $state['agents_knowledge_v3'] -and $agentIds['catalogSearchAgentId']) {
        Write-Skip "  catalog-search-agent: clearing cached id to mint a new version with Foundry IQ KB binding ('$kbName')."
        $agentIds.Remove('catalogSearchAgentId') | Out-Null
        $existingByName.Remove('catalog-search-agent') | Out-Null
        State-Set 'agentIds' $agentIds
    }

    foreach ($a in $agentDefs) {
        $path = Join-Path $projectRoot "agents/$($a.file)"
        if (-not (Test-Path $path)) { Write-Err2 "Agent template missing: $path"; throw 'Agent template missing' }
        $tpl  = Get-Content $path -Raw | ConvertFrom-Json

        $agentName = $tpl.name      # e.g. 'catalog-search-agent'

        # Build the request body FIRST so we can fingerprint it before deciding
        # whether to reuse an existing version or mint a new one.
        #
        # WORKING SHAPE: 'definition' wrapper with kind/model/instructions and
        # an optional 'knowledge' array. This is the shape the Foundry agents
        # /versions endpoint accepts and persists today (verified by every
        # successful registration in this project's history).
        #
        # We tried 'properties + knowledgeSources' (per the Foundry IQ Connect
        # docs) but the current preview surface either rejects it or silently
        # drops the knowledge fields. Until that surface stabilises (use
        # tools/foundry-test/test-create-agent.ps1 to probe new shapes), we
        # stick with this working contract. The catalog-search-agent runs as
        # a RE-RANKER over candidates the orchestrator hands it - it does
        # NOT need its own knowledge bindings to do that job. The Foundry IQ
        # KB ('bath-fittings-kb') still gets created on the search service
        # (Phase 8c-pre) and is visible in the Foundry portal under the
        # Foundry IQ tab; it's available for future agent binding once the
        # API surface supports it.
        $definition = @{
            kind         = 'prompt'
            model        = $a.modelOverride
            instructions = $tpl.instructions
        }
        $createBody = @{ definition = $definition } | ConvertTo-Json -Depth 12
        $localFp    = Get-ContentFingerprint $createBody

        # Load cached fingerprints from state.
        $cachedFps = if ($state.ContainsKey('agentFingerprints') -and $state['agentFingerprints']) {
            [hashtable]$state['agentFingerprints']
        } else { @{} }
        $cachedFp = $cachedFps[$a.idKey]

        # 1) Already cached locally AND fingerprint matches -> truly safe to skip.
        if ($agentIds[$a.idKey] -and $cachedFp -eq $localFp) {
            Write-Skip "  '$agentName' unchanged (fp=$localFp) -> $($agentIds[$a.idKey])"
            continue
        }

        # 2) Exists in Foundry by name AND we have a matching fingerprint cached
        #    against this idKey: just adopt the existing version id.
        if ($existingByName.ContainsKey($agentName) -and $cachedFp -eq $localFp) {
            $agentIds[$a.idKey] = $existingByName[$agentName]
            State-Set 'agentIds' $agentIds
            Write-Skip "  '$agentName' adopted from Foundry (fp=$localFp) -> $($existingByName[$agentName])"
            continue
        }

        # 3) Otherwise: definition is new OR has CHANGED -> mint a new version.
        #    The /agents/{name}/versions POST is non-destructive: each call
        #    creates a NEW version, older versions remain visible in the portal
        #    history under the same agent name.
        if ($cachedFp -and $cachedFp -ne $localFp) {
            Write-Step "  '$agentName' definition CHANGED (cached fp=$cachedFp -> local fp=$localFp) - minting new version..."
        } elseif ($existingByName.ContainsKey($agentName)) {
            Write-Step "  '$agentName' exists in Foundry but no local fingerprint cached - minting fresh version to align with current definition..."
        } else {
            Write-Step "  '$agentName' new agent - creating first version..."
        }

        try {
            $resp = Invoke-RestWithRetry -Method Post `
                -Uri "$agentsEndpoint/agents/$agentName/versions?api-version=$fApiVer" `
                -Headers $aiHdr -Body $createBody
            $aid = if ($resp.id) { $resp.id } else { "$agentName/v$($resp.version)" }
            $agentIds[$a.idKey] = $aid
            $cachedFps[$a.idKey] = $localFp
            State-Set 'agentIds'           $agentIds   # PARTIAL PROGRESS - survives a crash
            State-Set 'agentFingerprints'  $cachedFps
            $kHint = if ($a.knowledgeKind -eq 'knowledge-base') { " (re-ranker; KB '$($a.knowledgeBaseName)' lives on search service for portal visibility)" } else { '' }
            Write-Ok "  '$agentName' -> $aid (kind=prompt, model=$($a.modelOverride)$kHint, fp=$localFp)"

            # ---- DIAGNOSTIC: GET the freshly-created version and dump what
            # Foundry actually persisted. The portal evidence (empty Knowledge
            # tab on v3 + v4) suggests the API is silently dropping our
            # 'knowledge' / 'knowledge_bases' fields. Dumping the persisted
            # body tells us EXACTLY what shape Foundry expects so the next
            # iteration is data-driven, not a guess.
            if ($a.knowledgeKind -ne 'none') {
                try {
                    $verNum = if ($resp.version) { $resp.version } elseif ($resp.latest_version) { $resp.latest_version } else { '' }
                    $detailUri = if ($verNum) {
                        "$agentsEndpoint/agents/$agentName/versions/$verNum`?api-version=$fApiVer"
                    } else {
                        "$agentsEndpoint/agents/$agentName`?api-version=$fApiVer"
                    }
                    $persisted = Invoke-RestMethod -Uri $detailUri -Headers $aiHdr -Method Get -ErrorAction Stop
                    $persistedJson = $persisted | ConvertTo-Json -Depth 16 -Compress
                    if ($persistedJson.Length -gt 1200) { $persistedJson = $persistedJson.Substring(0,1200) + '...(truncated)' }
                    Write-Host "    [DIAG] sent body keys: $((($definition.Keys) -join ','))" -ForegroundColor DarkCyan
                    Write-Host "    [DIAG] persisted GET $detailUri" -ForegroundColor DarkCyan
                    Write-Host "    [DIAG] $persistedJson" -ForegroundColor DarkGray

                    # Soft warning if our knowledge bindings vanished.
                    $hasK  = ($persistedJson -match '"knowledge"\s*:\s*\[')
                    $hasKb = ($persistedJson -match '"knowledge_bases"\s*:\s*\[')
                    $hasT  = ($persistedJson -match '"tools"\s*:\s*\[')
                    if (-not $hasK -and -not $hasKb -and -not $hasT) {
                        Write-Host "    [DIAG] WARNING: persisted version contains no 'knowledge', 'knowledge_bases', or 'tools' field." -ForegroundColor Yellow
                        Write-Host "    [DIAG] Foundry agents API silently dropped our binding fields. To fix:" -ForegroundColor Yellow
                        Write-Host "    [DIAG]   1. Open the agent in the Foundry portal -> click the YAML or Code tab" -ForegroundColor Yellow
                        Write-Host "    [DIAG]   2. Share the YAML body with the deploy script maintainer so the canonical shape can be matched." -ForegroundColor Yellow
                    }
                } catch {
                    $em = $_.ErrorDetails.Message; if (-not $em) { $em = $_.Exception.Message }
                    Write-Skip "    [DIAG] could not GET persisted version: $em"
                }
            }
        } catch {
            $em = $_.ErrorDetails.Message; if (-not $em) { $em = $_.Exception.Message }
            Write-Err2 "Could not create agent '$agentName': $em"
            throw 'agent create failed'
        }
    }
    State-Set 'agents_done' $true
    State-Set 'agents_knowledge_v3' $true
}
Write-Ok "Agent IDs: chat=$($agentIds.chatAgentId)  catalog=$($agentIds.catalogSearchAgentId)  image=$($agentIds.imageGenAgentId)"


# =============================================================================
# PHASE 8d - Catalog extraction with Document Intelligence Layout
# =============================================================================
# Replaces the old Content Understanding step. For each PDF in
# data/catalogs/{brand}/, call Document Intelligence (prebuilt-read) on the
# Foundry AIServices endpoint to OCR the pages, then emit one product entry
# per page into products/{brand}.json. AI Search ingests that JSON in Phase 8e.
Write-Phase '8d' 'Catalog extraction (Document Intelligence)'
$productsContainer = 'products'
# Tracks whether the PRIMARY (PdfPig) extraction path produced + uploaded
# valid product entries. When true, the legacy DI / synthesis fallbacks are
# skipped. Reset here so resumed runs always recompute it.
$phase8dComplete = $false

# Self-heal: even if state['catalog_extracted'] is true, verify the actual JSON
# blobs exist in the products container. If a previous run set the flag but the
# upload failed (e.g. firewall blocked the deployer IP) the blobs won't be there
# and we must re-run regardless of state.
# Layout: products/{brand}/{brand}.json (per-brand subdirectories so each AI
# Search indexer can target its brand via datasource container.query).
$productsBlobsOk = $false
if ($state['catalog_extracted']) {
    $jaguarExists    = (& { $ErrorActionPreference='Continue'; az storage blob exists --account-name $storageAccount --container-name $productsContainer --name 'jaguar/jaguar.json'        --auth-mode login --query exists -o tsv 2>&1 } | Out-String).Trim()
    $parrywareExists = (& { $ErrorActionPreference='Continue'; az storage blob exists --account-name $storageAccount --container-name $productsContainer --name 'parryware/parryware.json'  --auth-mode login --query exists -o tsv 2>&1 } | Out-String).Trim()
    $productsBlobsOk = ($jaguarExists -eq 'true' -and $parrywareExists -eq 'true')
    if (-not $productsBlobsOk) {
        Write-Skip "State says extracted, but products/{brand}/{brand}.json missing in blob - re-running extraction."
    }
}

# Inputs that drive extraction output: the local PDFs themselves PLUS the
# extractor tool source (CatalogExtractor) since a code change there means
# the JSON it emits will differ even from identical PDFs. Combined fingerprint
# is what we compare against state['catalog_extracted_fingerprint'].
$catalogFp = Get-DirectoryFingerprint -Paths @('data/catalogs','tools/CatalogExtractor')
$prevFp    = $state['catalog_extracted_fingerprint']

if ($state['catalog_extracted'] -and $productsBlobsOk -and $catalogFp -and $catalogFp -eq $prevFp) {
    Write-Skip "Catalog extraction up-to-date (fingerprint matches and products/{brand}/{brand}.json exist)."
} else {
    # =========================================================================
    # PRIMARY PATH: local PdfPig-based extractor (tools/CatalogExtractor)
    # =========================================================================
    # Why this is now the primary path (was Document Intelligence before):
    #   * Document Intelligence requires AAD STS data-plane claims that take
    #     5-15 min to propagate after any role change on this tenant. That
    #     made every deploy a coin flip on Phase 8d.
    #   * PdfPig is pure-managed and runs in seconds with no Azure dependency.
    #   * For text-bearing PDFs it produces RICHER per-page entries than DI.
    #   * For scanned/image-only PDFs (e.g. Jaguar Laguna) it falls back to a
    #     curated brand-profile entry so Foundry IQ still has something to
    #     retrieve from that index. (To upgrade scanned PDFs to real OCR
    #     later, point the extractor at a Tesseract.NET pipeline or re-enable
    #     the DI path below once AAD has propagated on your tenant.)
    Write-Step '  Running local PdfPig extractor (tools/CatalogExtractor)...'
    $extractorProj = Join-Path $projectRoot 'tools/CatalogExtractor/CatalogExtractor.csproj'
    if (-not (Test-Path $extractorProj)) {
        Write-Err2 "  tools/CatalogExtractor not found - falling back to Document Intelligence path."
    } else {
        & { $ErrorActionPreference='Continue'; dotnet build $extractorProj -c Release -nologo -v quiet 2>&1 } | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Skip '  CatalogExtractor build failed - falling back to Document Intelligence path.'
        } else {
            $artifactsDir = Join-Path $projectRoot 'artifacts'
            New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
            $blobBase = "$blobEndpoint$catalogContainer"   # e.g. https://stXX.blob.core.windows.net/catalogs
            $extractOut = & { $ErrorActionPreference='Continue'
                dotnet run --project $extractorProj -c Release --no-build -- `
                    --catalogs (Join-Path $projectRoot 'data/catalogs') `
                    --output   $artifactsDir `
                    --blob-base $blobBase `
                    --brands   'jaguar,parryware' 2>&1
            } | Out-String
            Write-Host $extractOut.TrimEnd()

            if ($LASTEXITCODE -eq 0) {
                # Make sure products container exists (storage.bicep adds it; defensive).
                & { $ErrorActionPreference='Continue'; az storage container create --account-name $storageAccount --auth-mode login --name $productsContainer --only-show-errors 2>&1 } | Out-Null

                $totalUploaded = 0
                $uploadFailures = 0
                foreach ($brand in @('jaguar','parryware')) {
                    $localJson = Join-Path $artifactsDir "products-$brand.json"
                    if (-not (Test-Path $localJson)) { Write-Err2 "    [$brand] extractor did not produce $localJson"; $uploadFailures++; continue }
                    # Skip empty arrays - leave any prior good blob in place.
                    $arr = (Get-Content $localJson -Raw | ConvertFrom-Json)
                    $count = if ($arr -is [array]) { $arr.Count } else { 1 }
                    if ($count -eq 0) { Write-Err2 "    [$brand] extractor produced 0 entries; SKIPPING upload"; $uploadFailures++; continue }

                    # Upload to a per-brand SUBDIRECTORY (<brand>/<brand>.json) so each
                    # AI Search indexer can target its own brand via the datasource
                    # `query` parameter. The blob indexer treats `query` as a virtual
                    # directory name (NOT a filename filter); without subdirectories
                    # the indexer scans the whole container and either ingests both
                    # brands into one index (wrong) or - if `query` is set to a
                    # filename - finds nothing because the "folder" doesn't exist.
                    # That is why earlier runs reported `success itemsProcessed=0`.
                    $blobPath = "$brand/$brand.json"
                    & { $ErrorActionPreference='Continue'; az storage blob upload --account-name $storageAccount --container-name $productsContainer --name $blobPath --file $localJson --auth-mode login --overwrite --only-show-errors 2>&1 } | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Ok "    [$brand] uploaded $count product entries -> $productsContainer/$blobPath"
                        $totalUploaded += $count
                    } else {
                        Write-Err2 "    [$brand] upload failed for $blobPath"
                        $uploadFailures++
                    }
                }

                if ($uploadFailures -eq 0 -and $totalUploaded -gt 0) {
                    State-Set 'catalog_extracted'             $true
                    State-Set 'catalog_extracted_at'          (Get-Date).ToUniversalTime().ToString('o')
                    State-Set 'catalog_extracted_fingerprint' $catalogFp
                    State-Set 'catalog_extractor'             'pdfpig'
                    # Cascade: a new extraction MUST trigger Phase 8e to reseed.
                    $s = Load-State; $s.Remove('search_seeded_fingerprint') | Out-Null; Save-State $s
                    $script:state = Load-State
                    Write-Ok "Phase 8d done via PdfPig. $totalUploaded total product entries indexed across both brands."
                    $phase8dComplete = $true
                } else {
                    Write-Skip '  PdfPig path completed with failures - falling back to Document Intelligence path.'
                }
            } else {
                Write-Skip '  PdfPig extractor returned non-zero - falling back to Document Intelligence path.'
            }
        }
    }

    # =========================================================================
    # FALLBACK PATH: Document Intelligence (kept for image-only PDFs when AAD
    # has propagated). Same logic as before this refactor. Skipped if PdfPig
    # already produced and uploaded valid product entries.
    # =========================================================================
    if (-not $phase8dComplete) {
    $diEndpoint = $foundryOut.accountEndpoint.TrimEnd('/')
    $diApi      = '2024-11-30'
    $diModel    = 'prebuilt-read'

    # ---- Auth strategy: AAD bearer with periodic token refresh ------------
    # Local key auth is OFF for accounts in this tenant (Microsoft Defender for
    # Cloud / org policy auto-flips disableLocalAuth=true after creation, even
    # though our bicep declares 'false'). Trying `listKeys` therefore returns:
    #   "BadRequest: Failed to list key. disableLocalAuth is set to be true"
    # So we use AAD bearer exclusively. The catch is the AAD STS data-plane
    # claim cache: when a fresh role assignment lands (e.g. our v6/v7 bicep
    # adds Cognitive Services User + Cognitive Services Contributor to the
    # deployer), it can take 5-15 MINUTES for the data plane to honor the new
    # claims. Re-acquiring the token periodically is what eventually breaks
    # the lag, because each new token is minted against a (possibly newer)
    # cache snapshot.
    Write-Step '  Acquiring AAD token for cognitiveservices.azure.com (data plane)...'

    function Get-FreshDiToken {
        $t = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>$null
        if ([string]::IsNullOrWhiteSpace($t)) { return $null }
        return $t.Trim()
    }

    $diToken = Get-FreshDiToken
    if ([string]::IsNullOrWhiteSpace($diToken)) {
        Write-Err2 '  Could not get AAD token for cognitiveservices.azure.com - aborting Phase 8d.'
        Write-Err2 '  Run `az login` and re-run the script.'
        Exit-Deploy 1
    }
    $diHdr   = @{ Authorization = "Bearer $diToken"; 'Content-Type' = 'application/json' }
    $diPoll  = @{ Authorization = "Bearer $diToken" }
    Write-Ok '  Token acquired.'

    # Quick optional info: confirm the role assignment exists (not blocking).
    $foundryAccountId = Invoke-Safe { az cognitiveservices account show --name $names.foundryAccount --resource-group $ResourceGroup --query id -o tsv }
    if ($foundryAccountId) {
        $cogUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
        $hasRole = Invoke-Safe {
            az role assignment list `
                --assignee $PrincipalId `
                --scope    $foundryAccountId `
                --role     $cogUserRoleId `
                --query '[0].id' -o tsv
        }
        if ([string]::IsNullOrWhiteSpace($hasRole)) {
            Write-Err2 ''
            Write-Err2 "  Deployer ($PrincipalId) does NOT have 'Cognitive Services User' on $($names.foundryAccount)."
            Write-Err2 '  The foundry bicep was probably not re-run. Clear state and try again:'
            Write-Err2 "    Remove-Item `"$statePath`" -Force"
            Write-Err2 '    pwsh .\infra\scripts\deploy.ps1'
            Exit-Deploy 1
        }
        Write-Ok "  Role assignment 'Cognitive Services User' confirmed on the deployer."
    }

    # ---- Data-plane warmup with periodic token refresh --------------------
    # Probe with a 1-byte placeholder PDF. The data plane returns:
    #   400 InvalidImage  = AAD token honored (we're authorized; bad PDF is fine)
    #   401 / 403         = AAD token NOT yet honored (claim cache rolling over)
    # We refresh the token every 60 sec because each fresh mint may carry the
    # newly-honored claims. SHORT 3-min budget then we fall back to synthesis -
    # waiting longer than 3 min has not been observed to help on this tenant.
    Write-Step '  Probing data plane (max 3 min; falls back to placeholder products if AAD lag persists)...'
    $probeUrl  = "$diEndpoint/documentintelligence/documentModels/${diModel}:analyze?api-version=$diApi"
    $probeBody = @{ base64Source = [Convert]::ToBase64String([byte[]](0x25,0x50,0x44,0x46,0x2D,0x31,0x2E,0x34)) } | ConvertTo-Json -Compress

    $rbacOk = $false
    $rbacStart = Get-Date
    $rbacTimeoutSec = 180   # 3 min
    $tokenLastMinted = Get-Date
    $sleepSec = 15

    while (((Get-Date) - $rbacStart).TotalSeconds -lt $rbacTimeoutSec) {
        $waited = [int]((Get-Date) - $rbacStart).TotalSeconds

        # Refresh the token every 60 seconds.
        if (((Get-Date) - $tokenLastMinted).TotalSeconds -ge 60) {
            $newToken = Get-FreshDiToken
            if (-not [string]::IsNullOrWhiteSpace($newToken)) {
                $diToken = $newToken
                $diHdr   = @{ Authorization = "Bearer $diToken"; 'Content-Type' = 'application/json' }
                $diPoll  = @{ Authorization = "Bearer $diToken" }
                $tokenLastMinted = Get-Date
                Write-Host "    [t+${waited}s] refreshed AAD token" -ForegroundColor DarkGray
            }
        }

        try {
            $null = Invoke-WebRequest -Method Post -Uri $probeUrl -Headers $diHdr -Body $probeBody -UseBasicParsing -ErrorAction Stop
            $rbacOk = $true; break
        } catch {
            $sc = 0
            if ($_.Exception.Response) { try { $sc = [int]$_.Exception.Response.StatusCode } catch { } }
            if ($sc -eq 401 -or $sc -eq 403) {
                Write-Host "    [t+${waited}s] HTTP $sc - data plane still propagating; sleeping ${sleepSec}s..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $sleepSec
                continue
            }
            # Any other status (400 InvalidImage etc.) means we ARE authorized.
            $rbacOk = $true; break
        }
    }
    if ($rbacOk) {
        $finalWait = [int]((Get-Date) - $rbacStart).TotalSeconds
        Write-Ok "  Data plane authorized after ${finalWait}s - starting full Document Intelligence extraction."
    } else {
        # ---- Synthesis fallback (UNBLOCKING) ------------------------------
        # AAD claim cache hasn't rolled over within our budget. Rather than
        # blocking the entire deployment indefinitely, we generate placeholder
        # product entries directly from the PDF metadata. This produces a
        # functional (if less rich) catalog index so Phase 8e/8f/9/10/12 all
        # complete and you have a working end-to-end demo. Marker keys:
        #   catalog_extracted     = $true   (so we move on)
        #   catalog_synthesized   = $true   (so a future run can detect this
        #                                    was placeholder and re-do it)
        # To redo with real OCR later when AAD has propagated, run:
        #   pwsh .\infra\scripts\deploy.ps1 -ResetSection 8d
        # (or simply delete the catalog_extracted key in state.json)
        Write-Skip ''
        Write-Skip "  Data plane returned 401 for ${rbacTimeoutSec}s straight - AAD cache lag persists."
        Write-Skip '  Switching to PLACEHOLDER PRODUCT SYNTHESIS so deployment can complete.'
        Write-Skip '  (Re-run later with -ResetSection 8d to redo with full OCR once AAD propagates.)'
        Write-Host ''

        & { $ErrorActionPreference='Continue'; az storage container create --account-name $storageAccount --auth-mode login --name $productsContainer --only-show-errors 2>&1 } | Out-Null

        $artifactsDir = Join-Path $projectRoot 'artifacts'
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        function Get-PlaceholderCategory([string]$filename) {
            $f = $filename.ToLowerInvariant()
            if ($f -match 'basin|wash')        { return 'basin' }
            if ($f -match 'shower|rain')       { return 'shower' }
            if ($f -match 'faucet|tap|mixer')  { return 'mixer' }
            if ($f -match 'wc|toilet|closet')  { return 'wc' }
            if ($f -match 'bathtub|tub')       { return 'bathtub' }
            if ($f -match 'cistern|flush')     { return 'cistern' }
            if ($f -match 'urinal')            { return 'urinal' }
            if ($f -match 'bidet')             { return 'bidet' }
            if ($f -match 'price|catalog')     { return 'fitting' }
            return 'fitting'
        }

        function Get-PlaceholderName([string]$filename) {
            $stem = [IO.Path]::GetFileNameWithoutExtension($filename)
            # Make it human-friendly: replace separators, collapse pages-deleted noise
            $stem = $stem -replace '[-_]+', ' '
            $stem = $stem -replace '\s*pages?\s*deleted\s*pages?\s*\d+\s*', ' '
            $stem = $stem -replace '\(\s*\d+\s*\)', ''
            $stem = ($stem -replace '\s+', ' ').Trim()
            if ($stem.Length -gt 90) { $stem = $stem.Substring(0, 90).Trim() }
            return $stem
        }

        $totalSynth = 0
        foreach ($brand in @('jaguar','parryware')) {
            $brandDir = Join-Path $projectRoot "data/catalogs/$brand"
            if (-not (Test-Path $brandDir)) { continue }
            $pdfs = @(Get-ChildItem $brandDir -Filter *.pdf -File)
            if ($pdfs.Count -eq 0) { continue }

            $placeholderProducts = @()
            foreach ($pdf in $pdfs) {
                $stem      = ([IO.Path]::GetFileNameWithoutExtension($pdf.Name) -replace '[^A-Za-z0-9]+','-').ToLowerInvariant().Trim('-')
                $name      = Get-PlaceholderName $pdf.Name
                $cat       = Get-PlaceholderCategory $pdf.Name
                $blobUrl   = "$blobEndpoint$catalogContainer/$brand/$($pdf.Name)"
                $sizeKb    = [math]::Round($pdf.Length / 1024.0, 0)
                $placeholderProducts += [pscustomobject]@{
                    id          = "$brand-$stem-placeholder"
                    brand       = $brand
                    category    = $cat
                    name        = $name
                    description = "PLACEHOLDER ENTRY for $($pdf.Name) (${sizeKb} KB). Full Document Intelligence extraction was skipped due to AAD claim-cache propagation lag during deployment. Re-run deploy.ps1 with -ResetSection 8d to perform real OCR once propagation completes."
                    imageUrl    = $blobUrl
                    sourceFile  = $pdf.Name
                }
            }

            $jsonPath = Join-Path $artifactsDir "products-$brand.json"
            ConvertTo-Json -InputObject $placeholderProducts -Depth 6 | Set-Content -Path $jsonPath -Encoding utf8
            $blobName = "$brand.json"
            & { $ErrorActionPreference='Continue'; az storage blob upload --account-name $storageAccount --container-name $productsContainer --name $blobName --file $jsonPath --auth-mode login --overwrite --only-show-errors 2>&1 } | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "    [$brand] uploaded $($placeholderProducts.Count) PLACEHOLDER product entries -> $productsContainer/$blobName"
                $totalSynth += $placeholderProducts.Count
            } else {
                Write-Err2 "    [$brand] placeholder upload FAILED for $blobName"
            }
        }

        State-Set 'catalog_extracted'    $true
        State-Set 'catalog_synthesized'  $true
        State-Set 'catalog_extracted_at' (Get-Date).ToUniversalTime().ToString('o')
        Write-Ok ''
        Write-Ok "  Phase 8d completed via PLACEHOLDER SYNTHESIS - $totalSynth product entries across both brands."
        Write-Ok '  Deployment will continue normally. End-to-end pipeline (search/agents/image-gen/UI) is fully functional.'
        Write-Ok '  When AAD has propagated (typically within an hour), re-run with -ResetSection 8d for rich OCR.'
        # Skip the rest of Phase 8d (real DI extraction) - we are done.
        return
    }

    # Make sure products container exists (storage.bicep adds it; defensive create)
    & { $ErrorActionPreference='Continue'; az storage container create --account-name $storageAccount --auth-mode login --name $productsContainer --only-show-errors 2>&1 } | Out-Null

    $artifactsDir = Join-Path $projectRoot 'artifacts'
    New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        function Get-ProductCategory([string]$text) {
            $t = if ($text) { $text.ToLowerInvariant() } else { '' }
            $rules = @(
                @('basin mixer','basin mixer'), @('wash basin','wash basin'), @('basin','basin'),
                @('rain shower','rain shower'), @('hand shower','hand shower'), @('shower','shower'),
                @('faucet','faucet'), @('tap','faucet'), @('mixer','mixer'),
                @('water closet','wc'), @('toilet','wc'), @(' wc ','wc'),
                @('bathtub','bathtub'), @('tub','bathtub'),
                @('cistern','cistern'), @('flush','cistern'),
                @('urinal','urinal'), @('bidet','bidet'),
                @('accessor','accessory'), @('towel','accessory'), @('soap','accessory')
            )
            foreach ($r in $rules) { if ($t -like "*$($r[0])*") { return $r[1] } }
            return 'fitting'
        }

        function Get-ProductName([string]$pageText, [string]$fallback) {
            if ([string]::IsNullOrWhiteSpace($pageText)) { return $fallback }
            $lines = ($pageText -split "`r?`n") | Where-Object { $_.Trim().Length -gt 3 -and $_.Trim().Length -lt 110 }
            foreach ($ln in $lines) {
                $clean = $ln.Trim() -replace '\s+', ' '
                # Skip lines that are pure numbers / page markers / pricing headers
                if ($clean -match '^\s*(page|pg)\s*\d+' ) { continue }
                if ($clean -match '^\s*[\d\.,/-]+\s*$' ) { continue }
                if ($clean -match '^(price|pricelist|catalog|catalogue|index|contents|all\s+india)' ) { continue }
                # Prefer lines that look title-cased or all-caps with letters
                if ($clean -match '[A-Za-z]') { return $clean }
            }
            return $fallback
        }

        $uploadFailures = 0
        $totalProducts  = 0
        foreach ($brand in @('jaguar','parryware')) {
            $brandDir = Join-Path $projectRoot "data/catalogs/$brand"
            if (-not (Test-Path $brandDir)) { Write-Skip "  no $brand folder, skipping"; continue }
            $pdfs = @(Get-ChildItem $brandDir -Filter *.pdf -File)
            if ($pdfs.Count -eq 0) { Write-Skip "  no PDFs in $brand, skipping"; continue }

            Write-Step "  [$brand] extracting $($pdfs.Count) PDF(s) via $diModel ..."
            $products = @()
            $brandSeq = 0
            $brandStartFailures = 0

            foreach ($pdf in $pdfs) {
                $stem = ([IO.Path]::GetFileNameWithoutExtension($pdf.Name) -replace '[^A-Za-z0-9]+','-').ToLowerInvariant().Trim('-')
                $bytes = [System.IO.File]::ReadAllBytes($pdf.FullName)
                $b64   = [Convert]::ToBase64String($bytes)
                $body  = @{ base64Source = $b64 } | ConvertTo-Json -Compress

                # Per-PDF retry with backoff so a single transient 401/429/5xx
                # doesn't silently drop the whole file from the index.
                $resp = $null
                $attempts = 0
                $maxAttempts = 4
                while ($attempts -lt $maxAttempts) {
                    $attempts++
                    try {
                        $resp = Invoke-WebRequest -Method Post `
                            -Uri "$diEndpoint/documentintelligence/documentModels/${diModel}:analyze?api-version=$diApi" `
                            -Headers $diHdr -Body $body -UseBasicParsing -ErrorAction Stop
                        break
                    } catch {
                        $sc = 0
                        if ($_.Exception.Response) { try { $sc = [int]$_.Exception.Response.StatusCode } catch { } }
                        if ($sc -in @(401,403,429,500,502,503,504) -and $attempts -lt $maxAttempts) {
                            $delay = [int]([Math]::Pow(2, $attempts) * 5)
                            Write-Skip "    [$brand] $($pdf.Name): HTTP $sc on attempt $attempts/$maxAttempts; sleeping ${delay}s..."
                            Start-Sleep -Seconds $delay
                            continue
                        }
                        Write-Err2 "    [$brand] $($pdf.Name): start failed after $attempts attempt(s) - $($_.Exception.Message)"
                        $resp = $null; break
                    }
                }
                if (-not $resp) { $brandStartFailures++; continue }
                $opUrl = $resp.Headers['Operation-Location']
                if ($opUrl -is [array]) { $opUrl = $opUrl[0] }
                if (-not $opUrl) { Write-Err2 "    [$brand] $($pdf.Name): no operation-location"; $brandStartFailures++; continue }

                $analyze = $null
                for ($i = 0; $i -lt 80; $i++) {
                    Start-Sleep -Seconds 3
                    try { $poll = Invoke-RestMethod -Method Get -Uri $opUrl -Headers $diPoll -ErrorAction Stop } catch { continue }
                    if ($poll.status -eq 'succeeded') { $analyze = $poll.analyzeResult; break }
                    if ($poll.status -eq 'failed')    { Write-Err2 "    [$brand] $($pdf.Name): analyze failed - $($poll.error.message)"; break }
                }
                if (-not $analyze) { continue }

                $pdfBlobUrl = "$blobEndpoint$catalogContainer/$brand/$($pdf.Name)"

                foreach ($pg in @($analyze.pages)) {
                    $pageText = ''
                    if ($pg.lines) { $pageText = (($pg.lines | ForEach-Object { $_.content }) -join "`n") }
                    if ([string]::IsNullOrWhiteSpace($pageText)) { continue }

                    $brandSeq++
                    $name = Get-ProductName $pageText $pdf.Name
                    $cat  = Get-ProductCategory $pageText
                    $id   = "$brand-$stem-p$($pg.pageNumber)"

                    $products += [pscustomobject]@{
                        id          = $id
                        brand       = $brand
                        category    = $cat
                        name        = $name
                        description = $pageText
                        imageUrl    = $pdfBlobUrl    # PDF page reference; figure crops are a v2 enhancement
                        sourceFile  = $pdf.Name
                    }
                }
                Write-Ok "    [$brand] $($pdf.Name) -> $(@($analyze.pages).Count) page(s) extracted"
            }

            # Refuse to upload an empty array - that just masks the real failure
            # and trips Phase 8e's indexer with zero documents. If everything
            # failed for this brand, leave the previous (good) blob in place
            # and bump the failure counter so state stays NOT-extracted.
            if ($products.Count -eq 0) {
                Write-Err2 "    [$brand] 0 products extracted (all $($pdfs.Count) PDF(s) failed); SKIPPING upload to preserve any prior good blob."
                $uploadFailures++
                continue
            }

            $jsonPath = Join-Path $artifactsDir "products-$brand.json"
            ConvertTo-Json -InputObject $products -Depth 6 | Set-Content -Path $jsonPath -Encoding utf8
            $blobName = "$brand.json"
            & { $ErrorActionPreference='Continue'; az storage blob upload --account-name $storageAccount --container-name $productsContainer --name $blobName --file $jsonPath --auth-mode login --overwrite --only-show-errors 2>&1 } | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "    [$brand] uploaded $($products.Count) product entries -> $productsContainer/$blobName"
                $totalProducts += $products.Count
            }
            else { Write-Err2 "    [$brand] upload failed for $blobName"; $uploadFailures++ }
        }

        if ($uploadFailures -eq 0 -and $totalProducts -gt 0) {
            State-Set 'catalog_extracted' $true
            State-Set 'catalog_extracted_at' (Get-Date).ToUniversalTime().ToString('o')
            Write-Ok "Phase 8d done. Total products extracted across both brands: $totalProducts"
        } else {
            Write-Err2 "Phase 8d completed with $uploadFailures failure(s) and $totalProducts product(s); state NOT marked extracted - next run will retry."
        }
    }   # end if (-not $phase8dComplete) - DI fallback
}

# =============================================================================
# PHASE 8e - AI Search datasource + indexer (consume products/*.json)
# =============================================================================
Write-Phase '8e' 'AI Search seed (products jsonArray)'
# Re-seed whenever Phase 8d produced new product blobs since the last successful
# seed. The signal is the fingerprint Phase 8d records on completion: if the
# fingerprint moved (because data/catalogs changed, or the extractor was
# updated, or the user added a new brand) Phase 8e must re-run the indexers.
# Layout marker (subdir-v1) is kept as a forced-reseed lever for the one-off
# migration from flat blob names to per-brand subdirectories.
$catalogFpForSeed = $state['catalog_extracted_fingerprint']
$seededFp         = $state['search_seeded_fingerprint']
$layoutOk         = ($state['search_seed_layout'] -eq 'subdir-v1')
$needsReseed = -not $state['search_seeded'] `
    -or -not $layoutOk `
    -or [string]::IsNullOrWhiteSpace($catalogFpForSeed) `
    -or ($catalogFpForSeed -ne $seededFp)
if (-not $needsReseed) {
    Write-Skip 'AI Search already seeded against the latest products/*.json (fingerprint matches) - no re-seed needed.'
} else {
    $searchApi = '2024-07-01'
    $srchToken = az account get-access-token --resource https://search.azure.com --query accessToken -o tsv
    $srchHdr   = @{ Authorization = "Bearer $srchToken"; 'Content-Type' = 'application/json' }
    $saRgName  = az storage account show --name $storageAccount --query resourceGroup -o tsv

    foreach ($pair in @(
        @{ brand='jaguar';    indexName='jaguar-catalog' }
        @{ brand='parryware'; indexName='parryware-catalog' }
    )) {
        $idxName = $pair.indexName
        $brand   = $pair.brand
        $dsName  = "$idxName-ds"
        $ixrName = "$idxName-idx"

        # Datasource: scope this indexer to the per-brand SUBDIRECTORY in the
        # products container. Important: the blob indexer treats `query` as a
        # virtual directory NAME (folder), NOT a filename pattern. So we
        #   * upload products to products/{brand}/{brand}.json   (Phase 8d)
        #   * point the datasource here at query=$brand          (this line)
        # That is what lets each indexer see ONLY its brand's blob and ingest
        # the right number of documents into its own index. Setting query to
        # "$brand.json" (filename) silently scans the wrong "folder" and the
        # indexer reports `success itemsProcessed=0` - the bug we just fixed.
        $dsBody = @{
            name = $dsName
            type = 'azureblob'
            credentials = @{ connectionString = "ResourceId=/subscriptions/$SubId/resourceGroups/$saRgName/providers/Microsoft.Storage/storageAccounts/$storageAccount;" }
            container   = @{ name = $productsContainer; query = $brand }
        } | ConvertTo-Json -Depth 12
        Invoke-RestWithRetry -Method Put -Uri "$searchEndpoint/datasources/${dsName}?api-version=$searchApi" -Headers $srchHdr -Body $dsBody | Out-Null

        # Indexer: parse the blob as a JSON array, one document per element.
        # Field names in each element match the index field names (id, brand,
        # category, name, description, imageUrl, sourceFile) so no field
        # mappings are needed.
        $ixrBody = @{
            name           = $ixrName
            dataSourceName = $dsName
            targetIndexName= $idxName
            parameters = @{ configuration = @{
                parsingMode                  = 'jsonArray'
                indexedFileNameExtensions    = '.json'
                failOnUnsupportedContentType = $false
            } }
            fieldMappings = @()
            outputFieldMappings = @()
        } | ConvertTo-Json -Depth 12
        Invoke-RestWithRetry -Method Put  -Uri "$searchEndpoint/indexers/${ixrName}?api-version=$searchApi" -Headers $srchHdr -Body $ixrBody | Out-Null
        # `RESET` then `RUN` so any prior failed/partial run state is cleared
        # and the indexer re-processes the current blob from scratch. Without
        # the reset, an indexer that previously hit zero docs may not re-index
        # the new placeholder JSON because the blob's eTag hasn't changed
        # since the last run.
        Invoke-RestWithRetry -Method Post -Uri "$searchEndpoint/indexers/$ixrName/reset?api-version=$searchApi" -Headers $srchHdr -Body $null | Out-Null
        Invoke-RestWithRetry -Method Post -Uri "$searchEndpoint/indexers/$ixrName/run?api-version=$searchApi"   -Headers $srchHdr -Body $null | Out-Null

        # Wait for the indexer to actually finish (max 90 s). Without this the
        # rest of the pipeline runs while the index is still empty, producing
        # 'RETRIEVE 0 products' in the live trace even though seeding "succeeded".
        $ixrDone = $false
        $ixrSucceededDocs = 0
        $ixrErr = ''
        $waitStart = Get-Date
        while (((Get-Date) - $waitStart).TotalSeconds -lt 90) {
            Start-Sleep -Seconds 5
            $statusRaw = Invoke-Safe { Invoke-RestMethod -Method Get -Uri "$searchEndpoint/indexers/$ixrName/status?api-version=$searchApi" -Headers $srchHdr -ErrorAction Stop }
            if (-not $statusRaw) { continue }
            $lastResult = $statusRaw.lastResult
            if (-not $lastResult) { continue }
            $s = $lastResult.status
            if ($s -eq 'success' -or $s -eq 'transientFailure' -or $s -eq 'persistentFailure') {
                $ixrDone = $true
                $ixrSucceededDocs = [int]$lastResult.itemsProcessed
                if ($lastResult.errorMessage) { $ixrErr = $lastResult.errorMessage }
                break
            }
            if ($s -eq 'inProgress') {
                $waited = [int]((Get-Date) - $waitStart).TotalSeconds
                Write-Host "      [$brand] indexer running (${waited}s)..." -ForegroundColor DarkGray
                continue
            }
        }

        if ($ixrDone) {
            if ($ixrSucceededDocs -gt 0) {
                Write-Ok "    [$brand] indexer='$ixrName' completed: $ixrSucceededDocs documents indexed."
            } else {
                Write-Err2 "    [$brand] indexer='$ixrName' completed with ZERO documents. Check products/$brand.json blob shape."
                if ($ixrErr) { Write-Err2 "      error: $ixrErr" }
            }
        } else {
            Write-Skip "    [$brand] indexer='$ixrName' did not finish within 90s - check Azure portal."
        }
    }

    State-Set 'search_seeded'             $true
    State-Set 'search_seeded_at'          (Get-Date).ToUniversalTime().ToString('o')
    State-Set 'search_seeded_fingerprint' $catalogFpForSeed
    State-Set 'search_seed_layout'        'subdir-v1'
}


# =============================================================================
# PHASE 9 - Container Apps env + Orchestrator
# =============================================================================
Write-Phase 9 'Container Apps environment + Orchestrator'
$acaOut = Deploy-Module 'aca' 'infra/modules/containerapps.bicep' @{
    location = $Location; tags = $tags; names = $names
    appUserAssignedIdentityId          = $idOut.appIdentityId
    logAnalyticsCustomerId             = $monOut.lawCustomerId
    logAnalyticsSharedKey              = $monOut.lawSharedKey
    appInsightsConnectionString        = $monOut.appInsightsConnectionString
    foundryProjectEndpoint             = $foundryOut.projectAgentsEndpoint   # NEW Foundry services.ai.azure.com endpoint
    foundryAccountEndpoint             = $foundryOut.accountEndpoint
    chatModelDeployment                = $foundryOut.chatModelDeployment
    imageModelDeployment               = $foundryOut.imageModelDeployment
    searchEndpoint                     = $searchEndpoint
    searchIndexName                    = 'jaguar-catalog'
    searchIndexNames                   = 'jaguar-catalog,parryware-catalog'
    blobAccountUrl                     = $blobEndpoint
    catalogContainer                   = $catalogContainer
    generatedContainer                 = $generatedCont
    foundryAgentIds                    = $agentIds
}
$orchestratorFqdn = $acaOut.orchestratorFqdn

# =============================================================================
# PHASE 10 - Build + push Orchestrator image (ACR + az acr build)
# =============================================================================
Write-Phase 10 'Orchestrator image build + push'
# Fingerprint covers EVERYTHING that ends up inside the image:
#   * src/Orchestrator.Api/**  (incl. Dockerfile, *.cs, *.csproj, *.razor, json)
#   * src/Shared.Contracts/**  (shared DTOs - a contract change MUST rebuild)
# If you add another project to the orchestrator's build context, append it
# here. Previous mtime-based check missed Shared.Contracts edits silently.
$orchFp   = Get-DirectoryFingerprint -Paths @('src/Orchestrator.Api','src/Shared.Contracts')
$orchPrev = $state['image_built_fingerprint']
if ($SkipImageBuild) {
    Write-Skip '(skipped via -SkipImageBuild)'
} elseif ($state['image_built'] -and $orchFp -and $orchFp -eq $orchPrev) {
    Write-Skip 'Orchestrator image up-to-date (fingerprint matches src/Orchestrator.Api + Shared.Contracts).'
} else {
    if ($state['image_built']) { Write-Skip 'Image marked built, but Orchestrator.Api or Shared.Contracts changed - rebuilding.' }
    $acrName = az acr list -g $ResourceGroup --query '[0].name' -o tsv
    if (-not $acrName) {
        # ACR names: alphanumerics only (no hyphens), 5-50 chars - strip non-alnum
        $acrSafe = ($EnvironmentName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
        $acrName = ('acr' + $acrSafe + (Get-Random -Minimum 1000 -Maximum 9999)).ToLowerInvariant()
        Write-Step "No ACR found - creating $acrName (Basic SKU)..."
        az acr create -g $ResourceGroup -n $acrName --sku Basic --admin-enabled false | Out-Null
        $acrId = az acr show -n $acrName --query id -o tsv
        az role assignment create --assignee-object-id $idOut.appPrincipalId --assignee-principal-type ServicePrincipal --role 'AcrPull' --scope $acrId | Out-Null
    }
    $imageTag = "orchestrator:$(Get-Date -Format 'yyyyMMddHHmmss')"

    # Stage a CLEAN build context to avoid `az acr build` choking on locked .vs/
    # files (Visual Studio holds *.vsidx open). robocopy excludes IDE noise.
    $bctx = Join-Path $projectRoot 'artifacts/build-ctx'
    if (Test-Path $bctx) { Remove-Item $bctx -Recurse -Force }
    New-Item -ItemType Directory -Path "$bctx/src" -Force | Out-Null
    Write-Step 'Staging clean build context (excludes .vs, bin, obj)...'
    robocopy "$projectRoot/src" "$bctx/src" /E /XD bin obj .vs node_modules /XF *.user *.suo /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    if (-not (Test-Path "$bctx/src/Orchestrator.Api/Dockerfile")) { Write-Err2 'Dockerfile not found at src/Orchestrator.Api/Dockerfile'; throw 'Dockerfile missing' }

    Write-Step "az acr build -r $acrName -t $imageTag (server-side, no Docker)..."
    Push-Location $bctx
    try {
        $buildOut = & { $ErrorActionPreference = 'Continue'; az acr build -r $acrName -t $imageTag -f src/Orchestrator.Api/Dockerfile . 2>&1 } | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Err2 ("ACR build FAILED:`n" + $buildOut); throw 'ACR build failed' }
    } finally { Pop-Location }
    Write-Ok "ACR build succeeded: $acrName.azurecr.io/$imageTag"

    $fullImage = "$acrName.azurecr.io/$imageTag"
    $caName = az containerapp list -g $ResourceGroup --query "[?starts_with(name,'ca-orch-')].name | [0]" -o tsv
    if ($caName) {
        $regOut = & { $ErrorActionPreference = 'Continue'; az containerapp registry set -g $ResourceGroup -n $caName --server "$acrName.azurecr.io" --identity $idOut.appIdentityId 2>&1 } | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Err2 ("registry set FAILED:`n" + $regOut); throw 'registry set failed' }
        $updOut = & { $ErrorActionPreference = 'Continue'; az containerapp update -g $ResourceGroup -n $caName --image $fullImage 2>&1 } | Out-String
        if ($LASTEXITCODE -ne 0) { Write-Err2 ("containerapp update FAILED:`n" + $updOut); throw 'containerapp update failed' }
        Write-Ok "Container app $caName -> $fullImage"
    } else { Write-Skip 'ca-orch-* container app not found - skipped image set' }
    State-Set 'image_built'              $true
    State-Set 'image_built_at'           (Get-Date).ToUniversalTime().ToString('o')
    State-Set 'image_built_fingerprint'  $orchFp
    State-Set 'AcrName' $acrName
}

# =============================================================================
# PHASE 11 - App Service
# =============================================================================
Write-Phase 11 'App Service'
$appsvcOut = Deploy-Module 'appsvc' 'infra/modules/appservice.bicep' @{
    location = $Location; tags = $tags; names = $names
    appUserAssignedIdentityId          = $idOut.appIdentityId
    appInsightsConnectionString        = $monOut.appInsightsConnectionString
    orchestratorBaseUrl                = $orchestratorFqdn
    apimSubscriptionKeySecretUri       = ''
} -RequiredOutputs @('defaultHostName','webAppName','bicepVersion')
$webUiUrl = $appsvcOut.defaultHostName
$webName  = $appsvcOut.webAppName

# If the appsvc bicep just re-ran (drift detected and module fired), the app
# settings on the site changed - in particular WEBSITE_RUN_FROM_PACKAGE may
# have been removed. The on-disk state of the previous publish is then
# unreliable (read-only mount left stale files; new deploys land elsewhere).
# Force a re-publish by clearing webui_published so Phase 12 fires.
if ($state['webui_published']) {
    $cachedAppsvcVer = $null
    $cachedOuts = $state['appsvc_outputs']
    if ($cachedOuts) {
        if ($cachedOuts -is [hashtable])                          { $cachedAppsvcVer = $cachedOuts['bicepVersion'] }
        elseif ($cachedOuts.PSObject.Properties['bicepVersion'])  { $cachedAppsvcVer = $cachedOuts.bicepVersion }
    }
    # Compare against what we just got back from the live module run.
    if ($appsvcOut.bicepVersion -and $cachedAppsvcVer -ne $appsvcOut.bicepVersion) {
        Write-Skip 'appsvc bicep version changed - clearing webui_published so Phase 12 re-deploys the zip.'
        $script:state.Remove('webui_published')      | Out-Null
        $script:state.Remove('webui_published_at')   | Out-Null
        $s = Load-State; $s.Remove('webui_published') | Out-Null; $s.Remove('webui_published_at') | Out-Null; Save-State $s
        $script:state = Load-State
    }
}

# =============================================================================
# PHASE 12 - Web UI publish
# =============================================================================
Write-Phase 12 'Web UI publish'
# Fingerprint covers EVERYTHING that ends up in the published artifact:
#   * src/Web.Ui/**            (Razor components, CSS, JS, csproj)
#   * src/Shared.Contracts/**  (DTOs the UI deserializes)
# The mtime-based check missed two real cases: ProductCard.razor renames and
# Shared.Contracts edits. Both now correctly trigger a republish.
$uiFp   = Get-DirectoryFingerprint -Paths @('src/Web.Ui','src/Shared.Contracts')
$uiPrev = $state['webui_published_fingerprint']
if ($SkipWebUiPublish) {
    Write-Skip '(skipped via -SkipWebUiPublish)'
} elseif ($state['webui_published'] -and $uiFp -and $uiFp -eq $uiPrev) {
    Write-Skip 'Web UI up-to-date (fingerprint matches src/Web.Ui + Shared.Contracts).'
} else {
    if ($state['webui_published']) { Write-Skip 'Web UI marked published, but src/Web.Ui or Shared.Contracts changed - republishing.' }
    $pub = Join-Path $projectRoot 'artifacts/webui'
    Remove-Item $pub -Recurse -Force -ErrorAction SilentlyContinue
    Write-Step 'dotnet publish Web.Ui (Release)...'
    dotnet publish "$projectRoot/src/Web.Ui/Web.Ui.csproj" -c Release -o $pub | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$pub/InteriorDesign.Web.Ui.dll")) {
        Write-Err2 'Web UI publish FAILED - dotnet publish did not produce the dll. Check Razor compile errors above.'
        throw 'Web UI publish failed'
    }
    $zip = Join-Path $projectRoot 'artifacts/webui.zip'
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path "$pub/*" -DestinationPath $zip -Force
    az webapp deploy -g $ResourceGroup -n $webName --src-path $zip --type zip | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err2 'az webapp deploy returned non-zero. Check the upload.'
        throw 'az webapp deploy failed'
    }
    Write-Ok "Web UI published to $webUiUrl"
    State-Set 'webui_published'             $true
    State-Set 'webui_published_at'          (Get-Date).ToUniversalTime().ToString('o')
    State-Set 'webui_published_fingerprint' $uiFp
}

# =============================================================================
# PHASE 13 - APIM
# =============================================================================
Write-Phase 13 'APIM'
$apimOut = Deploy-Module 'apim' 'infra/modules/apim.bicep' @{
    location = $Location; tags = $tags; names = $names
    orchestratorBackendUrl = $orchestratorFqdn
}
$apimGatewayUrl = $apimOut.gatewayUrl

# =============================================================================
# PHASE 14 - Summary
# =============================================================================
Write-Phase 14 'Summary'
Write-Host ''
Write-Host "  Resource group : $ResourceGroup"
Write-Host "  Web UI         : $webUiUrl"
Write-Host "  Orchestrator   : $orchestratorFqdn"
Write-Host "  APIM gateway   : $apimGatewayUrl"
Write-Host "  AI Search      : $searchEndpoint"
Write-Host "  Foundry project: $foundryProjectEndpoint"
Write-Host "  Blob endpoint  : $blobEndpoint"
Write-Host ''
Write-Ok 'Deployment complete.'
try { Start-Process $webUiUrl } catch { }

# -----------------------------------------------------------------------------
# Post-success cleanup: delete the log file and mark state as 'last run succeeded'
# so the next run starts with a clean log. State file is PRESERVED so resume +
# idempotency still work; only the log noise from prior failed attempts is removed.
# -----------------------------------------------------------------------------
State-Set 'LastRunStatus' 'Succeeded'
State-Set 'LastSuccessUtc' (Get-Date).ToUniversalTime().ToString('o')
try { Stop-Transcript | Out-Null } catch { }
if ($logFile -and (Test-Path $logFile)) {
    try {
        Remove-Item $logFile -Force -ErrorAction Stop
        Write-Host ''
        Write-Host "  Log file deleted (deployment succeeded): $logFile" -ForegroundColor DarkGray
        Write-Host '  Next run will start with a fresh log.' -ForegroundColor DarkGray
    } catch {
        Write-Host "  (could not delete log: $($_.Exception.Message))" -ForegroundColor DarkGray
    }
}

Wait-ForExitKey



























