// Linux App Service plan + Web App for the Blazor UI. The site uses the same
// User-Assigned MI as the orchestrator and reads the orchestrator URL from
// app settings (Orchestrator__BaseUrl).
param location string
param tags object
param names object
param appUserAssignedIdentityId string
param appInsightsConnectionString string
param orchestratorBaseUrl string
param apimSubscriptionKeySecretUri string

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: names.appServicePlan
  location: location
  tags: tags
  sku: { name: 'B1', tier: 'Basic' }
  kind: 'linux'
  properties: { reserved: true }
}

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: names.webApp
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${appUserAssignedIdentityId}': {} }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    keyVaultReferenceIdentity: appUserAssignedIdentityId
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      alwaysOn: true
      webSocketsEnabled: true   // REQUIRED for Blazor Server SignalR circuit
      ftpsState: 'Disabled'
      http20Enabled: true
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        { name: 'AZURE_CLIENT_ID', value: reference(appUserAssignedIdentityId, '2023-01-31').clientId }
        { name: 'Orchestrator__BaseUrl', value: orchestratorBaseUrl }
        { name: 'Orchestrator__ApimSubscriptionKey', value: empty(apimSubscriptionKeySecretUri)
            ? ''
            : '@Microsoft.KeyVault(SecretUri=${apimSubscriptionKeySecretUri})' }
        // NOTE: WEBSITE_RUN_FROM_PACKAGE is intentionally NOT set. On Linux App
        // Service it makes the site filesystem read-only, which is incompatible
        // with `az webapp deploy --type zip` (the deployment lands in the wrong
        // location and the .NET runtime can't find the entry assembly, producing
        // HTTP 500 on every request). Run-from-package only works on Windows.
        // For Linux the correct pattern is plain Kudu zip deploy with no
        // WEBSITE_RUN_FROM_PACKAGE setting at all.
      ]
    }
  }
}

output defaultHostName string = 'https://${site.properties.defaultHostName}'
output webAppName string = site.name
output bicepVersion string = '2026-05-12-linux-no-runfrompkg-v1'   // bump when bicep semantics change to invalidate state cache
