// Sovereign AI reference: provider models in public cloud (Azure).
// Deploys an AI Gateway in front of Microsoft Foundry model deployments (OpenAI and
// Anthropic Claude), Application Insights telemetry for the gateway, and the Foundry
// project resources for hosted agents. Based on Azure-Samples/AI-Gateway
// (labs/aigw-foundry-models) and Azure-Samples/simple-foundry-hosted-agent-python-aigateway.
targetScope = 'resourceGroup'

@description('Region for Foundry, storage, container registry and monitoring. Claude models need a region that offers them.')
@allowed([
  'eastus2'
  'swedencentral'
])
param location string = 'eastus2'

@description('Region for the AI Gateway (preview regions only).')
@allowed([
  'eastus2'
  'swedencentral'
])
param aiGatewayLocation string = 'eastus2'

@minLength(3)
@maxLength(8)
@description('Short lowercase prefix for resource names.')
param namePrefix string = 'sovai'

@description('Optional Entra object ID of a user, group or service principal. It gets the AI Gateway User role (call models and tools) and Foundry developer access. Leave empty to skip.')
param principalId string = ''

@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
@description('Type of principalId.')
param principalType string = 'User'

@description('Create a gateway API key. Microsoft recommends Entra ID and Azure RBAC instead of keys for production callers.')
param createApiKey bool = false

@description('Organization name sent to Anthropic for Claude deployments (required by Foundry).')
param organizationName string

@description('Industry sent to Anthropic for Claude deployments (required by Foundry).')
param industry string = 'Financial Services'

@description('Two-letter country code sent to Anthropic for Claude deployments (required by Foundry).')
param countryCode string = 'US'

@description('Foundry model deployments. format is OpenAI or Anthropic; capacity is the Global Standard capacity.')
param models array = [
  { name: 'gpt-6.1-sol', format: 'OpenAI', version: '2026-09-29', capacity: 20 }
  { name: 'gpt-6-sol', format: 'OpenAI', version: '2026-09-22', capacity: 20 }
  { name: 'gpt-6-luna', format: 'OpenAI', version: '2026-09-22', capacity: 20 }
  { name: 'gpt-6-astra', format: 'OpenAI', version: '2026-09-03', capacity: 20 }
  { name: 'claude-opus-5-5', format: 'Anthropic', version: '2', capacity: 10 }
  { name: 'claude-sonnet-5-5', format: 'Anthropic', version: '2', capacity: 20 }
  { name: 'claude-haiku-5-5', format: 'Anthropic', version: '2', capacity: 20 }
]

@description('Gateway aliases with failover. Each backend names a deployment from models.')
param aliases array = [
  {
    name: 'gpt-latest'
    description: 'Latest GPT model with failover to gpt-6-sol.'
    backends: [
      { model: 'gpt-6.1-sol', priority: 0 }
      { model: 'gpt-6-sol', priority: 1 }
    ]
  }
  {
    name: 'claude-latest'
    description: 'Latest Claude model with failover to Sonnet.'
    backends: [
      { model: 'claude-opus-5-5', priority: 0 }
      { model: 'claude-sonnet-5-5', priority: 1 }
    ]
  }
]

@description('Deploy the Foundry project, storage and container registry for hosted agents.')
param deployAgentResources bool = true

@allowed([
  'Basic'
  'Standard'
  'Premium'
])
@description('Container registry SKU for hosted-agent images.')
param containerRegistrySku string = 'Basic'

@description('Capture prompt and completion payloads in gateway telemetry. Keep off unless policy permits it.')
param payloadCapture bool = false

var token = take(toLower(uniqueString(resourceGroup().id, namePrefix)), 6)
var base = '${toLower(namePrefix)}-${token}'
var gatewayName = 'aigw-${base}'
var modelAccountName = 'aimodels-${base}'
var agentAccountName = 'aiagents-${base}'
var projectName = 'proj-${base}'
var storageName = take('st${toLower(namePrefix)}${token}', 24)
var registryName = take('acr${toLower(namePrefix)}${token}', 50)
var tags = {
  'sovereign-ai-variant': 'provider-models-public-cloud'
}
var workspaceName = 'default'
var foundryProviderName = 'foundry'
var endpointsByFormat = {
  OpenAI: [
    '/openai/v1/chat/completions'
    '/openai/v1/responses'
  ]
  Anthropic: [
    '/anthropic/v1/messages'
  ]
}
// Callers reach models only through aliases, so every deployment also gets a direct alias
// with the model's own name, alongside the failover aliases.
var directAliases = [for m in models: {
  name: m.name
  description: 'Direct access to ${m.name}.'
  backends: [
    { model: m.name, priority: 0 }
  ]
}]
var allAliases = concat(directAliases, aliases)
var apiFormatByFormat = {
  OpenAI: 'OpenAIChatCompletions'
  Anthropic: 'AnthropicMessages'
}

// Role definition IDs.
var foundryUserRole = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var cognitiveServicesUserRole = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var cognitiveServicesOpenAIUserRole = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var cognitiveServicesContributorRole = '25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68'
var storageBlobDataContributorRole = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var acrPullRole = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var aiGatewayUserRole = 'caad7a21-134e-43f4-a550-c5ffc17e051c'

// ---------------------------------------------------------------------------
// Gateway monitoring: Log Analytics and Application Insights.
// ---------------------------------------------------------------------------
resource gatewayLogs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${gatewayName}-logs'
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource gatewayInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${gatewayName}-insights'
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    IngestionMode: 'LogAnalytics'
    WorkspaceResourceId: gatewayLogs.id
  }
}

// ---------------------------------------------------------------------------
// Foundry model account and deployments.
// ---------------------------------------------------------------------------
resource modelAccount 'Microsoft.CognitiveServices/accounts@2026-09-01' = {
  name: modelAccountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: false
    customSubDomainName: modelAccountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

@batchSize(1)
resource deployments 'Microsoft.CognitiveServices/accounts/deployments@2026-09-01' = [for m in models: {
  parent: modelAccount
  name: m.name
  sku: {
    name: 'GlobalStandard'
    capacity: m.capacity
  }
  properties: union({
    model: {
      format: m.format
      name: m.name
      version: m.version
    }
  }, m.format == 'Anthropic' ? {
    modelProviderData: {
      organizationName: organizationName
      industry: industry
      countryCode: countryCode
    }
  } : {})
}]

resource modelUserForPrincipal 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: modelAccount
  name: guid(modelAccount.id, cognitiveServicesUserRole, principalId)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRole)
  }
}

// ---------------------------------------------------------------------------
// AI Gateway: model provider, model registrations, aliases, telemetry, API key.
// ---------------------------------------------------------------------------
#disable-next-line BCP081
resource aiGateway 'Microsoft.ApiManagement/aigateways@2025-09-01-preview' = {
  name: gatewayName
  location: aiGatewayLocation
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Premium'
  }
  properties: {}
}

#disable-next-line BCP081
resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' = {
  name: gatewayName
  location: aiGatewayLocation
  tags: tags
  properties: {}
  dependsOn: [
    aiGateway
  ]
}

#disable-next-line BCP081
resource gatewayWorkspace 'Microsoft.ApiManagement/aigateways/workspaces@2025-09-01-preview' existing = {
  parent: aiGateway
  name: workspaceName
}

resource gatewayFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: modelAccount
  name: guid(modelAccount.id, aiGateway.id, foundryUserRole)
  properties: {
    principalId: aiGateway.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRole)
  }
}

#disable-next-line BCP081
resource telemetryExporter 'Microsoft.ApiManagement/aigateways/workspaces/telemetryExporters@2025-09-01-preview' = {
  parent: gatewayWorkspace
  name: 'appinsights'
  properties: {
    kind: 'applicationInsights'
    payloadCapture: payloadCapture
    applicationInsights: {
      connectionString: gatewayInsights.properties.ConnectionString
      resourceId: gatewayInsights.id
    }
  }
}

#disable-next-line BCP081
resource foundryProvider 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders@2025-09-01-preview' = {
  parent: gatewayWorkspace
  name: foundryProviderName
  dependsOn: [
    gatewayFoundryUser
  ]
  properties: {
    kind: 'Foundry'
    displayName: 'Foundry'
    description: 'Foundry model account ${modelAccountName}, reached with the gateway managed identity.'
    foundry: {
      endpoint: modelAccount.properties.endpoint
      resourceIds: [
        modelAccount.id
      ]
      authentication: {
        kind: 'ManagedIdentity'
        managedIdentity: {
          resource: 'https://cognitiveservices.azure.com/'
        }
      }
    }
  }
}

#disable-next-line BCP081
resource gatewayModels 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models@2025-09-01-preview' = [for (m, i) in models: {
  parent: foundryProvider
  name: m.name
  properties: {
    displayName: m.name
    description: '${m.format} model ${m.name} (${m.version}) on ${modelAccountName}.'
    apiFormat: apiFormatByFormat[m.format]
    supportedEndpoints: endpointsByFormat[m.format]
    deployment: {
      resourceId: deployments[i].id
      modelName: m.name
      modelVersion: m.version
    }
  }
}]

#disable-next-line BCP081
resource gatewayAliases 'Microsoft.ApiManagement/aigateways/workspaces/aliases@2025-09-01-preview' = [for a in allAliases: {
  parent: gatewayWorkspace
  name: a.name
  dependsOn: [
    gatewayModels
  ]
  properties: {
    aliasName: a.name
    description: a.description
    backendModels: [for b in a.backends: {
      resourceId: resourceId('Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models', gatewayName, workspaceName, foundryProviderName, b.model)
      priority: b.priority
      weight: 100
    }]
  }
}]

resource gatewayUserForPrincipal 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: aiGateway
  name: guid(aiGateway.id, aiGatewayUserRole, principalId)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiGatewayUserRole)
  }
}

#disable-next-line BCP081
resource gatewayApiKey 'Microsoft.ApiManagement/aigateways/apiKeys@2025-09-01-preview' = if (createApiKey) {
  parent: aiGateway
  name: 'default'
  properties: {
    displayName: 'Default application key'
  }
}

// ---------------------------------------------------------------------------
// Foundry project and hosted-agent resources.
// ---------------------------------------------------------------------------
resource agentLogs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (deployAgentResources) {
  name: '${agentAccountName}-logs'
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource agentInsights 'Microsoft.Insights/components@2020-02-02' = if (deployAgentResources) {
  name: '${agentAccountName}-insights'
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    IngestionMode: 'LogAnalytics'
    WorkspaceResourceId: agentLogs.id
  }
}

resource agentAccount 'Microsoft.CognitiveServices/accounts@2026-09-01' = if (deployAgentResources) {
  name: agentAccountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: agentAccountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = if (deployAgentResources) {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = if (deployAgentResources) {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: containerRegistrySku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource agentInsightsConnection 'Microsoft.CognitiveServices/accounts/connections@2026-09-01' = if (deployAgentResources) {
  parent: agentAccount
  name: '${agentAccountName}-insights'
  properties: {
    category: 'AppInsights'
    authType: 'ApiKey'
    isSharedToAll: false
    target: agentInsights.id
    credentials: {
      key: agentInsights!.properties.ConnectionString
    }
    metadata: {
      ApiType: 'Azure'
      ResourceId: agentInsights.id
    }
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-09-01' = if (deployAgentResources) {
  parent: agentAccount
  name: projectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Sovereign AI provider models'
    description: 'Foundry project for hosted agents that call models through the AI Gateway.'
  }
}

resource projectStorageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-09-01' = if (deployAgentResources) {
  parent: project
  name: storageName
  properties: {
    category: 'AzureStorageAccount'
    target: storage!.properties.primaryEndpoints.blob
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: storage.id
      location: location
    }
  }
}

resource projectRegistryConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-09-01' = if (deployAgentResources) {
  parent: project
  name: '${registryName}-conn'
  dependsOn: [
    projectAcrPull
  ]
  properties: {
    category: 'ContainerRegistry'
    target: registry!.properties.loginServer
    authType: 'ManagedIdentity'
    isSharedToAll: true
    credentials: {
      clientId: project!.identity.principalId
      resourceId: registry.id
    }
    metadata: {
      ResourceId: registry.id
    }
  }
}

resource projectCognitiveServicesUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAgentResources) {
  scope: agentAccount
  name: guid(agentAccountName, projectName, cognitiveServicesUserRole)
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRole)
  }
}

resource projectOpenAIUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAgentResources) {
  scope: agentAccount
  name: guid(agentAccountName, projectName, cognitiveServicesOpenAIUserRole)
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAIUserRole)
  }
}

resource projectContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAgentResources) {
  scope: agentAccount
  name: guid(agentAccountName, projectName, cognitiveServicesContributorRole)
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesContributorRole)
  }
}

resource projectBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAgentResources) {
  scope: storage
  name: guid(storageName, projectName, storageBlobDataContributorRole)
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRole)
  }
}

resource projectAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAgentResources) {
  scope: registry
  name: guid(registryName, projectName, acrPullRole)
  properties: {
    principalId: project!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRole)
  }
}

resource agentUserForPrincipal 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAgentResources && !empty(principalId)) {
  scope: agentAccount
  name: guid(agentAccountName, foundryUserRole, principalId)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRole)
  }
}

// ---------------------------------------------------------------------------
// Outputs. Callers get an Entra token for audience https://azure-api.net/aigateway and need an
// AI Gateway role. If createApiKey is true, read the key (it is never output) with:
// az rest --method post --url "https://management.azure.com<aiGatewayId>/apiKeys/default/listSecrets?api-version=2025-09-01-preview".
// ---------------------------------------------------------------------------
output aiGatewayName string = aiGateway.name
output aiGatewayId string = aiGateway.id
output aiGatewayEndpoint string = 'https://${aiGateway.properties.?frontend.?defaultHostname ?? ''}/'
output modelAccountName string = modelAccount.name
output modelDeployments array = [for m in models: m.name]
output aliases array = [for a in allAliases: a.name]
output gatewayAppInsightsName string = gatewayInsights.name
output foundryProjectEndpoint string = deployAgentResources ? 'https://${agentAccountName}.services.ai.azure.com/api/projects/${projectName}' : ''
output containerRegistryLoginServer string = deployAgentResources ? registry!.properties.loginServer : ''
