// Centralised resource naming. Returns an object the rest of the modules consume so
// no module ever has to format a name itself.
@description('Short workload name.')
param workload string
@description('Environment short code.')
param env string

var u = uniqueString(resourceGroup().id, workload, env)
var short = substring(u, 0, 6)
// Compact alphanumeric tag derived from workload+env. Used in length-constrained names
// like Key Vault (24) and Storage (24). 14 chars max so 'kv-' + tag + 6-char unique = 23.
var weTagFull = toLower(replace(replace('${workload}${env}', '-', ''), '_', ''))
var weTag     = length(weTagFull) > 14 ? substring(weTagFull, 0, 14) : weTagFull
var weTagSt   = length(weTagFull) > 12 ? substring(weTagFull, 0, 12) : weTagFull  // storage: 'st' + 12 + 6 = 20

output names object = {
  // long, descriptive
  logAnalytics:           'law-${workload}-${env}-${short}'
  appInsights:            'appi-${workload}-${env}-${short}'
  keyVault:               'kv-${weTag}${short}'
  appIdentity:            'id-${workload}-${env}-${short}'
  storage:                toLower('st${weTagSt}${short}')
  search:                 'srch-${workload}-${env}-${short}'
  contentUnderstanding:   'cu-${workload}-${env}-${short}'
  foundryAccount:         'aif-${workload}-${env}-${short}'
  foundryProject:         'aifp-${workload}-${env}-${short}'
  acaEnv:                 'cae-${workload}-${env}-${short}'
  // Container Apps: max 32 chars. Use compact alnum tag (workload+env stripped) - max 8+14+1+6=29.
  orchestratorApp:        'ca-orch-${weTag}-${short}'
  appServicePlan:         'asp-${workload}-${env}-${short}'
  webApp:                 'app-web-${workload}-${env}-${short}'
  apim:                   'apim-${workload}-${env}-${short}'
}


