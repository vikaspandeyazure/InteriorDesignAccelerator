// Microsoft Foundry: AI account + project + chat & image model deployments.
// CREATE-ONLY path. The "reuse existing account" path was removed to avoid the
// duplicate-resource compile issue (BCP420 + ARM "defined multiple times").
// If you ever need to reuse an existing account, add a separate `foundry-reuse.bicep`
// module and have deploy.ps1 pick one or the other based on $ExistingFoundryAccountId.
param location string
param tags object
param names object
param chatModelName string
param imageModelName string
@description('Optional explicit chat model version. Empty = let Azure pick the default.')
param chatModelVersion string = ''
@description('Optional explicit image model version.')
param imageModelVersion string = ''
@description('Chat model deployment capacity in RPM.')
param chatModelCapacity int = 50
@description('Image model deployment capacity in RPM.')
param imageModelCapacity int = 1
param appUserAssignedIdentityPrincipalId string
param deployerObjectId string

@description('Azure AI Search service resource ID. When non-empty, a CognitiveSearch connection is created on the project so agents can use the azure_ai_search tool.')
param searchServiceId string = ''

@description('Azure AI Search endpoint URL (https://<name>.search.windows.net). Required when searchServiceId is set.')
param searchEndpoint string = ''

@description('Storage account resource ID. When non-empty, the project MI gets Storage Blob Data Reader so vision/image agents can read blob URLs.')
param storageAccountId string = ''

// Auto-detect publisher format. MAI-* = Microsoft, gpt-* / o-* = OpenAI.
var chatModelFormat  = startsWith(toLower(chatModelName),  'mai-') ? 'Microsoft' : 'OpenAI'
var imageModelFormat = startsWith(toLower(imageModelName), 'mai-') ? 'Microsoft' : 'OpenAI'

var openAIUser              = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var cognitiveServicesUser   = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var cognitiveServicesContrib = '25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68'   // Cognitive Services Contributor (grants listKeys/action)
var aiDeveloperRole         = '64702f94-c441-49e6-a78b-ef80e0188fee'
var aiUserRole              = '53ca6127-db72-4b80-b1b0-d745d6d5456d'        // Azure AI User (project-scope, runtime invoke)
var aiProjectManagerRole    = 'eadc314b-1a2d-4efa-be10-5d325db5065e'        // Azure AI Project Manager (project-scope, full data plane)

// ---- Account -------------------------------------------------------------
resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: names.foundryAccount
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: names.foundryAccount
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
    allowProjectManagement: true
  }
}

// ---- Project --------------------------------------------------------------
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: account
  name: names.foundryProject
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Interior Design Accelerator'
    description: 'Bathroom design accelerator project (catalog grounding + image generation).'
  }
}

// ---- Model deployments (chat first, image afterwards to avoid throttling) -
// NOTE: deployment NAMES (top-level `name`) are forced to lowercase because the
// OpenAI SDK lowercases the deployment segment when building the request URL,
// and the Azure data plane is case-sensitive on that segment. The MODEL IDs
// inside `properties.model.name` keep their original casing because that's
// how Microsoft has them registered in the model catalog (e.g. 'MAI-Image-2').
resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: account
  name: toLower(chatModelName)
  sku: { name: 'GlobalStandard', capacity: chatModelCapacity }
  properties: {
    model: empty(chatModelVersion)
      ? { format: chatModelFormat, name: chatModelName }
      : { format: chatModelFormat, name: chatModelName, version: chatModelVersion }
    raiPolicyName: 'Microsoft.DefaultV2'
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

resource imageDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: account
  name: toLower(imageModelName)
  sku: { name: 'GlobalStandard', capacity: imageModelCapacity }
  properties: {
    model: empty(imageModelVersion)
      ? { format: imageModelFormat, name: imageModelName }
      : { format: imageModelFormat, name: imageModelName, version: imageModelVersion }
    raiPolicyName: 'Microsoft.DefaultV2'
  }
  dependsOn: [ chatDeployment ]
}

// ---- RBAC: app + deployer get to call inference + agent APIs --------------
resource roleAppOpenAI 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, appUserAssignedIdentityPrincipalId, openAIUser)
  properties: {
    principalId: appUserAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAIUser)
  }
}

resource roleAppCog 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, appUserAssignedIdentityPrincipalId, cognitiveServicesUser)
  properties: {
    principalId: appUserAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUser)
  }
}

resource roleAppAIDev 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, appUserAssignedIdentityPrincipalId, aiDeveloperRole)
  properties: {
    principalId: appUserAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiDeveloperRole)
  }
}

resource roleDeployerAIDev 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, deployerObjectId, aiDeveloperRole)
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiDeveloperRole)
  }
}

// Required for the deployer to call the data plane of any Cognitive Services
// API exposed by the AIServices account: Document Intelligence (Phase 8d
// catalog extraction), OpenAI inference (smoke tests), Vision, etc. Without
// this role the deployer's AAD token to https://cognitiveservices.azure.com
// is accepted at the auth layer but rejected with 401 by the data plane.
// (The app's UAMI already has this role via roleAppCog above; this assignment
// gives the deployer the same data-plane access only at *account* scope, which
// is the minimum required for prebuilt-read OCR calls.)
resource roleDeployerCog 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, deployerObjectId, cognitiveServicesUser)
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUser)
  }
}

// Grants the deployer Microsoft.CognitiveServices/accounts/listKeys/action so
// deploy.ps1 Phase 8d can fetch the account key for one-shot Document
// Intelligence calls. Keys bypass the AAD STS data-plane claim cache (which
// can take 5-15 min to honor a fresh `Cognitive Services User` assignment),
// making the deploy deterministic. Runtime app traffic continues to use the
// UAMI's AAD path - keys are NOT used in production.
resource roleDeployerCogContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, deployerObjectId, cognitiveServicesContrib)
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesContrib)
  }
}

// ---- Capability host (REQUIRED for the New Foundry /agents data plane) -----
// Without this, the project's /agents endpoint returns 404 and you fall back
// to the legacy /assistants API (which shows as "Assistants" not "Agents" in portal).
resource capabilityHost 'Microsoft.CognitiveServices/accounts/capabilityHosts@2025-10-01-preview' = {
  parent: account
  name: 'agents'
  properties: {
    capabilityHostKind: 'Agents'
  }
  dependsOn: [ project ]
}
// ---- Project-level connections to Azure AI Search (one per brand index) ----
// These show up in Foundry portal under 'Knowledge' and are referenced by the
// catalog-search-agent's knowledge tool for agentic retrieval.
resource aiSearchConnJaguar 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!empty(searchServiceId)) {
  parent: project
  name: 'jaguar-catalog'
  properties: {
    category: 'CognitiveSearch'
    target: searchEndpoint
    authType: 'AAD'
    isSharedToAll: true
    metadata: {
      ApiType: 'Azure'
      ResourceId: searchServiceId
      IndexName: 'jaguar-catalog'
    }
  }
}

resource aiSearchConnParryware 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!empty(searchServiceId)) {
  parent: project
  name: 'parryware-catalog'
  properties: {
    category: 'CognitiveSearch'
    target: searchEndpoint
    authType: 'AAD'
    isSharedToAll: true
    metadata: {
      ApiType: 'Azure'
      ResourceId: searchServiceId
      IndexName: 'parryware-catalog'
    }
  }
}

// Grant the PROJECT system-assigned MI Search Index Data Reader on the search service
// so the agent can actually read the index when invoked.
// ---- PROJECT-scoped roles for the Foundry Agents data plane ---------------
// Account-scope Azure AI Developer is NOT enough for POST /assistants etc.
// Deployer needs Project Manager (create/delete agents/connections),
// app UAMI needs AI User (invoke agents at runtime).
resource roleDeployerProjectMgr 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: project
  name: guid(project.id, deployerObjectId, aiProjectManagerRole)
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiProjectManagerRole)
  }
}

resource roleAppProjectUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: project
  name: guid(project.id, appUserAssignedIdentityPrincipalId, aiUserRole)
  properties: {
    principalId: appUserAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiUserRole)
  }
}
var searchIndexDataReader = '1407120a-92aa-4202-b7e9-c0e197c71c8f'
var storageBlobDataReader  = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
resource roleProjectOnSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(searchServiceId)) {
  scope: resourceGroup()
  name: guid(project.id, searchServiceId, 'searchIndexDataReader')
  properties: {
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataReader)
  }
}
// Grant project MI Storage Blob Data Reader so vision/image agents can fetch
// blob URLs (e.g. catalog product images referenced in the search index).
resource roleProjectOnStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(storageAccountId)) {
  scope: resourceGroup()
  name: guid(project.id, storageAccountId, 'storageBlobDataReader')
  properties: {
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReader)
  }
}

output accountName string = account.name
output accountEndpoint string = account.properties.endpoint
output projectId string = project.id
output projectName string = project.name
output projectEndpoint string = '${account.properties.endpoint}api/projects/${project.name}'
output projectAgentsEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${project.name}'
output chatModelDeployment string = chatDeployment.name
output imageModelDeployment string = imageDeployment.name
output projectPrincipalId string = project.identity.principalId
output searchConnectionIdJaguar string    = !empty(searchServiceId) ? aiSearchConnJaguar.id    : ''
output searchConnectionIdParryware string = !empty(searchServiceId) ? aiSearchConnParryware.id : ''
output searchConnectionId string          = !empty(searchServiceId) ? aiSearchConnJaguar.id    : ''   // back-compat
output bicepVersion string = '2026-05-10-deployer-cog-contrib-v7'   // bump when bicep semantics change to invalidate state cache







