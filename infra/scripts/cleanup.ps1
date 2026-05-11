#!/usr/bin/env pwsh
# =============================================================================
#  Interior Design Accelerator - Tear-down
# -----------------------------------------------------------------------------
#  Reads .deploy-state.json (produced by deploy.ps1) and deletes the resource
#  group it created. If you supply -ResourceGroup explicitly, that wins and
#  the state file is ignored.
#
#  USAGE
#    pwsh .\cleanup.ps1                       # delete RG from .deploy-state.json
#    pwsh .\cleanup.ps1 -ResourceGroup rg-x   # delete a specific RG
#    pwsh .\cleanup.ps1 -Force                # don't ask for confirmation
# =============================================================================

[CmdletBinding()]
param(
    [string] $ResourceGroup,
    [switch] $Force,
    [switch] $PurgeFoundry
)

$ErrorActionPreference = 'Stop'

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$statePath   = Join-Path $projectRoot '.deploy-state.json'

if (-not $ResourceGroup) {
    if (-not (Test-Path $statePath)) {
        Write-Host 'No -ResourceGroup supplied and no .deploy-state.json found - nothing to clean up.' -ForegroundColor Yellow
        exit 0
    }
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    $ResourceGroup = $state.ResourceGroup
}

Write-Host ''
Write-Host "About to DELETE resource group: $ResourceGroup" -ForegroundColor Red
Write-Host '  This destroys: Foundry project + agents, AI Search, Storage, ACA env, App Service, APIM, Key Vault.' -ForegroundColor Yellow
Write-Host ''

if (-not $Force) {
    $c = Read-Host "Type the RG name to confirm"
    if ($c -ne $ResourceGroup) { Write-Host 'Aborted - name did not match.' -ForegroundColor Yellow; exit 0 }
}

$exists = (az group exists --name $ResourceGroup) -eq 'true'
if (-not $exists) {
    Write-Host "Resource group '$ResourceGroup' does not exist." -ForegroundColor Yellow
} else {
    az group delete --name $ResourceGroup --yes --no-wait | Out-Null
    Write-Host "Deletion initiated (running async). Check progress with:" -ForegroundColor Green
    Write-Host "  az group show -n $ResourceGroup --query properties.provisioningState -o tsv" -ForegroundColor White
}

if ($PurgeFoundry) {
    Write-Host "`nPurging soft-deleted Cognitive Services accounts (forever-delete)..." -ForegroundColor Yellow
    $deletedJson = az cognitiveservices account list-deleted --query "[?resourceGroup=='$ResourceGroup'].{name:name,location:location,rg:resourceGroup}" -o json
    if ($deletedJson) {
        $deleted = $deletedJson | ConvertFrom-Json
        foreach ($d in $deleted) {
            Write-Host "  Purging $($d.name) in $($d.location)..." -ForegroundColor DarkGray
            az cognitiveservices account purge --location $d.location --resource-group $d.rg --name $d.name | Out-Null
        }
    }
}

if (Test-Path $statePath) {
    Remove-Item $statePath -Force
    Write-Host 'Removed local .deploy-state.json' -ForegroundColor DarkGray
}
