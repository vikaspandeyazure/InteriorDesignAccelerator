<#
.SYNOPSIS
  Regenerates docs/assets/*.png from the matching .svg files.

.DESCRIPTION
  We hand-author the architecture diagrams as SVG (so they're version-controllable
  and editable in any text/SVG editor). The PNGs are exports for GitHub README
  rendering and Word/Confluence/blog embeds. This script keeps them in sync.

  One-time prereq: Node.js installed and on PATH (https://nodejs.org).
  No global npm package install needed - the script provisions 'sharp' into a
  scratch folder under $env:TEMP on first run.

.EXAMPLE
  pwsh ./docs/assets/regen-png.ps1

  Re-renders both architecture-overview.png and architecture.png from their
  current .svg sources. Safe to re-run any time you edit the SVGs.
#>
[CmdletBinding()]
param(
    [int]$Width  = 1480,
    [int]$Height = 980
)

$ErrorActionPreference = 'Stop'

$repo   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$assets = Join-Path $repo 'docs\assets'
$pairs  = @(
    @{ Svg = 'architecture-overview.svg'; Png = 'architecture-overview.png' }
    @{ Svg = 'architecture.svg';          Png = 'architecture.png'          }
)

# Verify node
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Host 'node not found on PATH. Install Node.js (https://nodejs.org) and re-run.' -ForegroundColor Red
    exit 1
}

# Provision sharp in a scratch folder (idempotent - skips on repeat runs)
$tmp = Join-Path $env:TEMP 'svg2png-ida'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
if (-not (Test-Path (Join-Path $tmp 'node_modules\sharp'))) {
    Write-Host "First-time setup: installing 'sharp' into $tmp ..." -ForegroundColor DarkCyan
    Push-Location $tmp
    try {
        npm init -y           2>&1 | Out-Null
        npm install --no-audit --no-fund --silent sharp  2>&1 | Out-Null
    } finally { Pop-Location }
}

# Inline the render script (so the repo doesn't need a node_modules)
$render = @'
const sharp = require('sharp');
const fs    = require('fs');
const path  = require('path');

async function render(svgPath, pngPath, w, h) {
  const buf = fs.readFileSync(svgPath);
  const out = await sharp(buf, { density: 200 })
    .resize(w, h, { fit: 'inside' })
    .png({ compressionLevel: 9 })
    .toFile(pngPath);
  console.log('  ' + path.basename(pngPath) + '  ' + out.width + 'x' + out.height + '  ' + out.size + ' bytes');
}

(async () => {
  const pairs = JSON.parse(process.argv[2]);
  const w = parseInt(process.argv[3], 10);
  const h = parseInt(process.argv[4], 10);
  for (const p of pairs) {
    await render(p.svg, p.png, w, h);
  }
  console.log('OK');
})().catch(e => { console.error(e); process.exit(1); });
'@

$jsPath = Join-Path $tmp 'render.js'
Set-Content -Path $jsPath -Value $render -Encoding utf8 -NoNewline

$pairsArg = ($pairs | ForEach-Object {
    @{
        svg = (Join-Path $assets $_.Svg).Replace('\','/')
        png = (Join-Path $assets $_.Png).Replace('\','/')
    }
}) | ConvertTo-Json -Compress

Write-Host "Rendering PNGs from SVGs ($Width x $Height max)..." -ForegroundColor Cyan
Push-Location $tmp
try {
    node $jsPath $pairsArg $Width $Height
} finally { Pop-Location }
