<#
.SYNOPSIS
  Standalone test harness for the Foundry agents POST /agents/{name}/versions
  endpoint. Lets you iterate on the request body shape WITHOUT running the full
  deploy.ps1. Once a variant succeeds (and the GET-back shows knowledgeSources
  / knowledge / tools persisted), copy that exact body into deploy.ps1.

.DESCRIPTION
  Flow:
    1. Acquires an AAD token for ai.azure.com.
    2. POSTs each variant in $bodyVariants to /agents/{TestAgentName}/versions
       and logs status code + response.
    3. GETs the freshly-created version and dumps what Foundry actually
       persisted (which is the ground truth - the POST may return 200 while
       silently dropping fields).
    4. Optionally cleans up the test agent at the end.

  EDIT $bodyVariants below to try new shapes. Each variant is fully self-
  contained so you can experiment with property names / nesting / wrappers
  without affecting the others.

.PARAMETER ProjectEndpoint
  Foundry agents endpoint, e.g.
    https://aif-foundryiq-mai-dev-519196.services.ai.azure.com/api/projects/aifp-foundryiq-mai-dev-519196

.PARAMETER KbName
  The Foundry IQ knowledge base name (must already exist on the search
  service, e.g. created by deploy.ps1 Phase 8c-pre).

.PARAMETER TestAgentName
  Name of the throwaway agent used for testing. Defaults to
  'catalog-search-agent-test'. Each run mints a NEW version under this name -
  older versions remain in the portal history (non-destructive).

.PARAMETER Cleanup
  If set, deletes the test agent at the end of the run.

.EXAMPLE
  pwsh ./tools/foundry-test/test-create-agent.ps1 `
    -ProjectEndpoint 'https://aif-foundryiq-mai-dev-519196.services.ai.azure.com/api/projects/aifp-foundryiq-mai-dev-519196' `
    -KbName 'bath-fittings-kb'

  Then look at the [DIAG] output to see which variant Foundry actually
  persisted with knowledgeSources populated.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectEndpoint,
    [Parameter(Mandatory)][string]$KbName,
    [string]$TestAgentName = 'catalog-search-agent-test',
    [string]$ApiVersion = 'v1',
    [switch]$Cleanup
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
Write-Host "Acquiring AAD token for ai.azure.com..." -ForegroundColor Cyan
$token = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv 2>$null
if (-not $token -or $token.Length -lt 100) {
    $token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
}
if (-not $token -or $token.Length -lt 100) {
    Write-Host "FAILED to get token. Run 'az login' and try again." -ForegroundColor Red
    exit 1
}
$hdr = @{
    Authorization      = "Bearer $token"
    'Content-Type'     = 'application/json'
    'Foundry-Features' = 'HostedAgents=V1Preview'
}

$ProjectEndpoint = $ProjectEndpoint.TrimEnd('/')
$createUri = "$ProjectEndpoint/agents/$TestAgentName/versions?api-version=$ApiVersion"
$listUri   = "$ProjectEndpoint/agents/$TestAgentName/versions?api-version=$ApiVersion"
$delUri    = "$ProjectEndpoint/agents/$TestAgentName`?api-version=$ApiVersion"

Write-Host "Endpoint   : $createUri" -ForegroundColor DarkCyan
Write-Host "Test agent : $TestAgentName" -ForegroundColor DarkCyan
Write-Host "KB name    : $KbName" -ForegroundColor DarkCyan
Write-Host ""

# ---------------------------------------------------------------------------
# Body variants - EDIT THESE to try new shapes.
# Each variant is a [hashtable] that will be ConvertTo-Json'd and POSTed.
# Add / remove / mutate freely. The diagnostics show which one persisted.
# ---------------------------------------------------------------------------
$instructions = "Test agent. Search the bath-fittings KB and return JSON."

$bodyVariants = @(

    @{
        Label = 'V1: properties + knowledgeSources (no connection)'
        Body  = @{
            name       = $TestAgentName
            properties = @{
                description  = "Test agent grounded in $KbName"
                model        = @{ name = 'gpt-4.1-mini' }
                instructions = $instructions
                knowledgeSources = @(
                    @{
                        type          = 'azure_ai_search'
                        knowledgeBase = @{ name = $KbName }
                    }
                )
            }
        }
    },

    @{
        Label = 'V2: properties + knowledgeSources WITH connection=jaguar-catalog'
        Body  = @{
            name       = $TestAgentName
            properties = @{
                description  = "Test agent grounded in $KbName"
                model        = @{ name = 'gpt-4.1-mini' }
                instructions = $instructions
                knowledgeSources = @(
                    @{
                        type          = 'azure_ai_search'
                        connection    = 'jaguar-catalog'
                        knowledgeBase = @{ name = $KbName }
                    }
                )
            }
        }
    },

    @{
        Label = 'V3: properties + knowledgeSources with kbName at top of source'
        Body  = @{
            name       = $TestAgentName
            properties = @{
                description  = "Test agent grounded in $KbName"
                model        = @{ name = 'gpt-4.1-mini' }
                instructions = $instructions
                knowledgeSources = @(
                    @{
                        type     = 'azure_ai_search'
                        kbName   = $KbName
                    }
                )
            }
        }
    },

    @{
        Label = 'V4: definition + knowledgeSources (mix old wrapper + new field)'
        Body  = @{
            definition = @{
                kind         = 'prompt'
                model        = 'gpt-4.1-mini'
                instructions = $instructions
                knowledgeSources = @(
                    @{
                        type          = 'azure_ai_search'
                        knowledgeBase = @{ name = $KbName }
                    }
                )
            }
        }
    },

    @{
        Label = 'V5: properties + tools array of azure_ai_search type'
        Body  = @{
            name       = $TestAgentName
            properties = @{
                description  = "Test agent grounded in $KbName via tools"
                model        = @{ name = 'gpt-4.1-mini' }
                instructions = $instructions
                tools        = @(
                    @{
                        type            = 'azure_ai_search'
                        azure_ai_search = @{
                            knowledge_base_name = $KbName
                        }
                    }
                )
            }
        }
    }
)

# ---------------------------------------------------------------------------
# Run each variant - log POST status, list versions after, dump persisted body
# ---------------------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
foreach ($v in $bodyVariants) {
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  $($v.Label)" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow

    $bodyJson = $v.Body | ConvertTo-Json -Depth 15
    Write-Host "POST body:" -ForegroundColor DarkGray
    Write-Host $bodyJson -ForegroundColor DarkGray
    Write-Host ""

    $postSc   = 0
    $postBody = ''
    $postId   = $null
    $postVer  = $null
    try {
        $r = Invoke-WebRequest -Uri $createUri -Headers $hdr -Method Post -Body $bodyJson -UseBasicParsing -ErrorAction Stop
        $postSc   = [int]$r.StatusCode
        $postBody = $r.Content
        try {
            $j = $postBody | ConvertFrom-Json
            $postId  = $j.id
            $postVer = if ($j.version) { $j.version } elseif ($j.latest_version) { $j.latest_version } else { $null }
        } catch { }
        Write-Host "POST -> HTTP $postSc" -ForegroundColor Green
    } catch {
        if ($_.Exception.Response) {
            try { $postSc = [int]$_.Exception.Response.StatusCode } catch { }
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $sr = New-Object System.IO.StreamReader($stream)
                    $postBody = $sr.ReadToEnd()
                }
            } catch { }
        }
        if (-not $postBody) { $postBody = $_.ErrorDetails.Message }
        if (-not $postBody) { $postBody = $_.Exception.Message }
        Write-Host "POST -> HTTP $postSc" -ForegroundColor Red
        Write-Host "Error body:" -ForegroundColor Red
        Write-Host $postBody -ForegroundColor DarkRed
    }

    # GET back what was persisted, even on error (the agent may have been
    # created with our fields silently dropped).
    Start-Sleep -Seconds 2
    $persistedJson = ''
    try {
        $list = Invoke-RestMethod -Uri $listUri -Headers $hdr -Method Get -ErrorAction Stop
        $persistedJson = $list | ConvertTo-Json -Depth 16
    } catch {
        $em = $_.ErrorDetails.Message; if (-not $em) { $em = $_.Exception.Message }
        $persistedJson = "GET versions failed: $em"
    }

    $hasKs    = ($persistedJson -match '"knowledgeSources"')
    $hasK     = ($persistedJson -match '"knowledge"\s*:\s*\[')
    $hasKb    = ($persistedJson -match '"knowledge_bases"' -or $persistedJson -match '"knowledgeBases"')
    $hasTools = ($persistedJson -match '"tools"\s*:\s*\[')

    Write-Host ""
    Write-Host "Persisted body (after the POST):" -ForegroundColor Cyan
    if ($persistedJson.Length -gt 2400) {
        Write-Host ($persistedJson.Substring(0,2400) + "...(truncated, $($persistedJson.Length) chars)") -ForegroundColor DarkGray
    } else {
        Write-Host $persistedJson -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "Persisted contains knowledgeSources?  $hasKs" -ForegroundColor $(if ($hasKs)    { 'Green' } else { 'Yellow' })
    Write-Host "Persisted contains knowledge?         $hasK"  -ForegroundColor $(if ($hasK)     { 'Green' } else { 'Yellow' })
    Write-Host "Persisted contains knowledge_bases?   $hasKb" -ForegroundColor $(if ($hasKb)    { 'Green' } else { 'Yellow' })
    Write-Host "Persisted contains tools?             $hasTools" -ForegroundColor $(if ($hasTools){'Green' } else { 'Yellow' })
    Write-Host ""

    $results.Add([PSCustomObject]@{
        Variant       = $v.Label
        PostStatus    = $postSc
        HasKs         = $hasKs
        HasKnowledge  = $hasK
        HasKbField    = $hasKb
        HasTools      = $hasTools
    }) | Out-Null
}

# ---------------------------------------------------------------------------
# Summary table - which variant actually persisted bindings?
# ---------------------------------------------------------------------------
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "  SUMMARY" -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta
$results | Format-Table -AutoSize | Out-String | Write-Host
$winner = $results | Where-Object { $_.HasKs -or $_.HasKnowledge -or $_.HasKbField -or $_.HasTools } | Select-Object -First 1
if ($winner) {
    Write-Host "WINNER: $($winner.Variant)" -ForegroundColor Green
    Write-Host "  -> Copy that variant's body into deploy.ps1 Phase 8c agent body builder." -ForegroundColor Green
} else {
    Write-Host "No variant persisted any binding. The agents API may require:" -ForegroundColor Yellow
    Write-Host "  * a different api-version (try -ApiVersion '2025-05-15-preview' etc.)" -ForegroundColor Yellow
    Write-Host "  * a separate POST to /agents/{name}/knowledgeSources after the version is created" -ForegroundColor Yellow
    Write-Host "  * or it's currently portal-only on this rollout (open the YAML tab in the portal to compare)." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Optional cleanup
# ---------------------------------------------------------------------------
if ($Cleanup) {
    Write-Host ""
    Write-Host "Cleaning up test agent '$TestAgentName' ..." -ForegroundColor DarkYellow
    try {
        Invoke-RestMethod -Uri $delUri -Headers $hdr -Method Delete -ErrorAction Stop | Out-Null
        Write-Host "  deleted." -ForegroundColor DarkYellow
    } catch {
        $em = $_.ErrorDetails.Message; if (-not $em) { $em = $_.Exception.Message }
        Write-Host "  delete failed: $em" -ForegroundColor DarkYellow
    }
}
