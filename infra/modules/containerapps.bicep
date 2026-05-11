// Container Apps environment + Orchestrator app. The image is pulled from the
// public Microsoft 'aspnet:8.0' image at first deploy and then replaced by the
// build-and-push step in deploy.ps1.
param location string
param tags object
param names object
param appUserAssignedIdentityId string
param logAnalyticsCustomerId string
@secure()
param logAnalyticsSharedKey string
param appInsightsConnectionString string

param foundryProjectEndpoint string
param foundryAccountEndpoint string = ''   // cognitiveservices.azure.com endpoint for image SDK calls
param chatModelDeployment string
param imageModelDeployment string
param searchEndpoint string
param searchIndexName string = 'jaguar-catalog'   // legacy single-index back-compat
param searchIndexNames string = 'jaguar-catalog,parryware-catalog'
param blobAccountUrl string
param catalogContainer string
param generatedContainer string
param foundryAgentIds object

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: names.acaEnv
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: names.orchestratorApp
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${appUserAssignedIdentityId}': {} }
  }
  properties: {
    environmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'orchestrator'
          // Placeholder image. deploy.ps1 builds & pushes the real image, then
          // updates the container app with `az containerapp update --image ...`.
          image: 'mcr.microsoft.com/dotnet/samples:aspnetapp'
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'ASPNETCORE_URLS', value: 'http://+:8080' }
            { name: 'AZURE_CLIENT_ID', value: reference(appUserAssignedIdentityId, '2023-01-31').clientId }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
            { name: 'Azure__FoundryProjectEndpoint', value: foundryProjectEndpoint }
            { name: 'Azure__ChatModelDeployment',    value: chatModelDeployment }
            { name: 'Azure__ImageModelDeployment',   value: imageModelDeployment }
            { name: 'Azure__SearchEndpoint',         value: searchEndpoint }
            { name: 'Azure__SearchIndexName',        value: searchIndexName }
            { name: 'Azure__SearchIndexNames',       value: searchIndexNames }
            { name: 'Azure__FoundryAccountEndpoint', value: foundryAccountEndpoint }
            { name: 'Azure__BlobAccountUrl',         value: blobAccountUrl }
            { name: 'Azure__CatalogContainer',       value: catalogContainer }
            { name: 'Azure__GeneratedContainer',     value: generatedContainer }
            // Foundry agent NAMES (not IDs) for the NEW Foundry Responses API
            { name: 'Azure__Agents__ChatAgent',                value: 'chat-agent' }
            { name: 'Azure__Agents__CatalogSearchAgent',       value: 'catalog-search-agent' }
            { name: 'Azure__Agents__ImageGenAgent',            value: 'image-gen-agent' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
}

output orchestratorFqdn string = 'https://${app.properties.configuration.ingress.fqdn}'
output containerAppName string = app.name
output environmentId string = env.id


