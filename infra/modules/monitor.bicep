param location string
param tags object
param names object

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: names.logAnalytics
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: names.appInsights
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output lawId string = law.id
output lawCustomerId string = law.properties.customerId
#disable-next-line outputs-should-not-contain-secrets
output lawSharedKey string = law.listKeys().primarySharedKey
output appInsightsConnectionString string = appi.properties.ConnectionString
