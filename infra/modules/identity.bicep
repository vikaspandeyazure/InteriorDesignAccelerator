// Single User-Assigned Managed Identity used by every compute service
// (orchestrator container app + web app). Foundry, Search and Storage
// data-plane RBAC are granted to this principal in the respective modules.
param location string
param tags object
param names object

resource appId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: names.appIdentity
  location: location
  tags: tags
}

output appIdentityId string = appId.id
output appPrincipalId string = appId.properties.principalId
output appClientId string = appId.properties.clientId
