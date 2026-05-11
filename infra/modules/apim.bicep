// Consumption-tier APIM in front of the Orchestrator. Demo-friendly (no VNet),
// flip to 'Developer' or 'Premium' + internal mode for production.
param location string
param tags object
param names object
param orchestratorBackendUrl string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: names.apim
  location: location
  tags: tags
  sku: { name: 'Consumption', capacity: 0 }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherEmail: 'demo@contoso.com'
    publisherName: 'Interior Design Accelerator'
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'design'
  properties: {
    displayName: 'Design Orchestrator'
    path: 'design'
    protocols: [ 'https' ]
    serviceUrl: orchestratorBackendUrl
    subscriptionRequired: true
  }
}

resource opGenerate 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'generate'
  properties: {
    displayName: 'Generate design'
    method: 'POST'
    urlTemplate: '/api/design/generate'
  }
}

resource opHealth 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'health'
  properties: {
    displayName: 'Health'
    method: 'GET'
    urlTemplate: '/api/design/health'
  }
}

output gatewayUrl string = apim.properties.gatewayUrl
output apimName string = apim.name
