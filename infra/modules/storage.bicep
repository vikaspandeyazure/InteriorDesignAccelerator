param location string
param tags object
param names object
param appUserAssignedIdentityPrincipalId string
param deployerObjectId string

@description('Public IPs (or CIDRs) allowed to reach the storage data plane. Pass the deployer + any tester IPs. Required when the org policy denies open public access. Empty = no IP rules (only AzureServices bypass).')
param allowedIpAddresses array = []

var blobDataContributor   = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageBlobDataReader = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource sa 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: names.storage
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false                  // org-policy compliant: no anonymous access
    publicNetworkAccess: 'Enabled'                // endpoint reachable but firewalled below
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'                     // trusted services (AI Search indexer, etc.)
      defaultAction: 'Deny'                       // selected networks
      ipRules: [for ip in allowedIpAddresses: {
        value: ip
        action: 'Allow'
      }]
      virtualNetworkRules: []
    }
  }
}

resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: sa
  name: 'default'
  properties: {
    cors: {
      corsRules: [
        {
          allowedOrigins: [ '*' ]
          allowedMethods: [ 'GET', 'HEAD', 'OPTIONS' ]
          allowedHeaders: [ '*' ]
          exposedHeaders: [ '*' ]
          maxAgeInSeconds: 3600
        }
      ]
    }
  }
}

resource catalogContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobSvc
  name: 'catalogs'
  properties: { publicAccess: 'None' }
}

// products: per-brand JSON arrays (one entry per product extracted from catalog
// PDFs by Document Intelligence Layout in deploy.ps1 Phase 5b) + cropped figure
// images. AI Search ingests {brand}.json from here as the canonical product index.
resource productsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobSvc
  name: 'products'
  properties: { publicAccess: 'None' }
}

resource generatedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobSvc
  name: 'generated'
  properties: { publicAccess: 'None' }
}

resource roleApp 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: sa
  name: guid(sa.id, appUserAssignedIdentityPrincipalId, blobDataContributor)
  properties: {
    principalId: appUserAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributor)
  }
}

resource roleDeployer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: sa
  name: guid(sa.id, deployerObjectId, blobDataContributor)
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributor)
  }
}

output storageAccountId string = sa.id
output storageAccountName string = sa.name
output blobEndpoint string = sa.properties.primaryEndpoints.blob
output catalogContainer string = catalogContainer.name
output productsContainer string = productsContainer.name
output generatedContainer string = generatedContainer.name
