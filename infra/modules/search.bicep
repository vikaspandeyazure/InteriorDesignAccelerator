// Azure AI Search service + an empty index that the post-deploy script
// (infra/scripts/seed-search.ps1) populates from the catalog blobs.
// Index schema is intentionally simple so the demo "just works".
param location string
param tags object
param names object
param storageAccountId string
param storageAccountName string
param catalogContainer string
param appUserAssignedIdentityPrincipalId string
param deployerObjectId string

var searchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var searchServiceContributor   = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
var searchIndexDataReader      = '1407120a-92aa-4202-b7e9-c0e197c71c8f'

resource srch 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: names.search
  location: location
  tags: tags
  sku: { name: 'basic' }
  identity: { type: 'SystemAssigned' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    semanticSearch: 'free'
    publicNetworkAccess: 'enabled'
    authOptions: { aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' } }
  }
}

resource roleApp 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: srch
  name: guid(srch.id, appUserAssignedIdentityPrincipalId, searchIndexDataReader)
  properties: {
    principalId: appUserAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataReader)
  }
}

resource roleDeployerData 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: srch
  name: guid(srch.id, deployerObjectId, searchIndexDataContributor)
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataContributor)
  }
}

resource roleDeployerSvc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: srch
  name: guid(srch.id, deployerObjectId, searchServiceContributor)
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchServiceContributor)
  }
}

// Allow the Search service's MI to read source blobs.
resource roleSearchOnStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: resourceGroup()
  name: guid(srch.id, storageAccountId, 'storageBlobDataReader')
  properties: {
    principalId: srch.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
  }
}

output searchServiceId string = srch.id
output searchServiceName string = srch.name
output searchEndpoint string = 'https://${srch.name}.search.windows.net'
output indexName string = 'bath-fittings'
