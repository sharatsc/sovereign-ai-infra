// Sovereign AI reference: frontier models on public cloud (Azure).
// Deploys an AI Gateway in front of Microsoft Foundry model deployments (OpenAI by default;
// Anthropic Claude is supported through the models parameter) with Application Insights
// traces. Based on Azure-Samples/AI-Gateway (labs/aigw-foundry-models) and
// Azure-Samples/simple-foundry-hosted-agent-python-aigateway, scoped to model access.
targetScope = 'resourceGroup'

@description('Region for Foundry and monitoring. Claude models need a region that offers them.')
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

@description('Optional extra Entra object ID (user, group or service principal) to grant access. The account that runs the deployment always gets access.')
param principalId string = ''

@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
@description('Type of principalId.')
param principalType string = 'User'

@description('Organization name sent to Anthropic. Needed only if models includes an Anthropic (Claude) deployment.')
param organizationName string = ''

@description('Industry sent to Anthropic. Needed only for Anthropic (Claude) deployments.')
param industry string = 'Financial Services'

@description('Two-letter country code sent to Anthropic. Needed only for Anthropic (Claude) deployments.')
param countryCode string = 'US'

@description('Foundry model deployments. Fields: name, format (OpenAI, Anthropic or Microsoft), version, capacity; optional deploymentName (defaults to name), sku (defaults to GlobalStandard), endpoints (gateway paths; defaults by format) and gateway (defaults to true; false deploys in Foundry only). Claude (Anthropic) deployments need a subscription that can buy the Anthropic Marketplace offer, plus organizationName.')
param models array = [
  { name: 'gpt-6.1-sol', format: 'OpenAI', version: '2026-09-29', capacity: 20 }
  { name: 'gpt-6-sol', format: 'OpenAI', version: '2026-09-22', capacity: 20 }
  { name: 'gpt-6-luna', format: 'OpenAI', version: '2026-09-22', capacity: 20 }
  { name: 'gpt-6-astra', format: 'OpenAI', version: '2026-09-03', capacity: 20 }
  // Decision models are reached through the gateway's passthrough at /providers/microsoft/v1/systemone.
  { name: 'Microsoft-Decision-1', deploymentName: 'decision-1', format: 'Microsoft', version: '1', capacity: 10, endpoints: [ '/providers/microsoft/v1/systemone' ] }
]

@description('Names (deploymentName or name) of the models entries to deploy. Empty deploys every entry in models. The portal form sets this from its model checklist.')
param selectedModels array = []

@minValue(0)
@description('If greater than 0, use this Global Standard capacity for every selected model instead of each entry\'s capacity.')
param capacityOverride int = 0

@description('Gateway aliases with failover. Each backend names a deployment from models. Backends whose model is not deployed are dropped, and aliases left with no backend are skipped.')
param aliases array = [
  {
    name: 'gpt-latest'
    description: 'Latest GPT model with failover to gpt-6-sol.'
    backends: [
      { model: 'gpt-6.1-sol', priority: 0 }
      { model: 'gpt-6-sol', priority: 1 }
    ]
  }
]

@description('Capture request and response payloads in gateway traces. Required for token usage (gen_ai.usage.*) and model attributes in traces. Stores prompt and completion text in Application Insights; turn off if policy forbids it.')
param payloadCapture bool = true

@minValue(1)
@description('Monthly budget for this resource group, in the billing currency. Alerts fire at 80% of actual spend and 100% of forecast spend.')
param monthlyBudget int = 100

@description('Optional email address for budget alerts. Resource group owners are always notified.')
param budgetAlertEmail string = ''

@description('First day of the budget period. Defaults to the first day of the current month.')
param budgetStartDate string = utcNow('yyyy-MM-01')

@description('Web page that shows next steps for this deployment. The deployment appends its values to the URL fragment.')
param nextStepsBaseUrl string = 'https://brk-tech-sovereign-ai.azurewebsites.net/next-steps.html'

var chosenModels = empty(selectedModels) ? models : filter(models, m => contains(selectedModels, m.?deploymentName ?? m.name))
var effectiveModels = map(chosenModels, m => capacityOverride > 0 ? union(m, { capacity: capacityOverride }) : m)
var token = take(toLower(uniqueString(resourceGroup().id, namePrefix)), 6)
var base = '${toLower(namePrefix)}-${token}'
var gatewayName = 'aigw-${base}'
var modelAccountName = 'aimodels-${base}'
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
var gatewayModelList = filter(effectiveModels, m => m.?gateway ?? true)
var directAliases = [for m in gatewayModelList: {
  name: m.?deploymentName ?? m.name
  description: 'Direct access to ${m.name}.'
  backends: [
    { model: m.?deploymentName ?? m.name, priority: 0 }
  ]
}]
var gatewayModelNames = map(gatewayModelList, m => m.?deploymentName ?? m.name)
var availableAliases = filter(map(aliases, a => {
  name: a.name
  description: a.description
  backends: filter(a.backends, b => contains(gatewayModelNames, b.model))
}), a => length(a.backends) > 0)
var allAliases = concat(directAliases, availableAliases)
var apiFormatByFormat = {
  OpenAI: 'OpenAIChatCompletions'
  Anthropic: 'AnthropicMessages'
}

// Role definition IDs.
var foundryUserRole = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var cognitiveServicesUserRole = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var aiGatewayUserRole = 'caad7a21-134e-43f4-a550-c5ffc17e051c'

// The account that runs the deployment always gets access; principalId adds one more.
var deployerId = deployer().objectId
var grantExtraPrincipal = !empty(principalId) && principalId != deployerId

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
resource deployments 'Microsoft.CognitiveServices/accounts/deployments@2026-09-01' = [for m in effectiveModels: {
  parent: modelAccount
  name: m.?deploymentName ?? m.name
  sku: {
    name: m.?sku ?? 'GlobalStandard'
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

resource modelUserForDeployer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: modelAccount
  name: guid(modelAccount.id, cognitiveServicesUserRole, deployerId)
  properties: {
    principalId: deployerId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRole)
  }
}

resource modelUserForPrincipal 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantExtraPrincipal) {
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

// Connector gateway with the same name: the AI Gateway portal discovers gateways through it,
// because Azure Resource Graph indexes this type but not Microsoft.ApiManagement/aigateways.
#disable-next-line BCP081
resource connectorGateway 'Microsoft.Web/connectorGateways@2026-05-01-preview' = {
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
resource gatewayModels 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models@2025-09-01-preview' = [for (m, i) in effectiveModels: if (m.?gateway ?? true) {
  parent: foundryProvider
  name: m.?deploymentName ?? m.name
  properties: {
    displayName: m.name
    description: '${m.format} model ${m.name} (${m.version}) on ${modelAccountName}.'
    apiFormat: apiFormatByFormat[?m.format]
    supportedEndpoints: m.?endpoints ?? endpointsByFormat[?m.format] ?? endpointsByFormat.OpenAI
    deployment: {
      resourceId: deployments[i].id
      modelName: m.?deploymentName ?? m.name
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

resource gatewayUserForDeployer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: aiGateway
  name: guid(aiGateway.id, aiGatewayUserRole, deployerId)
  properties: {
    principalId: deployerId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiGatewayUserRole)
  }
}

resource gatewayUserForPrincipal 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantExtraPrincipal) {
  scope: aiGateway
  name: guid(aiGateway.id, aiGatewayUserRole, principalId)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiGatewayUserRole)
  }
}

// ---------------------------------------------------------------------------
// Budget: monthly cost budget on this resource group.
// ---------------------------------------------------------------------------
var budgetContactEmails = empty(budgetAlertEmail) ? [] : [budgetAlertEmail]

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'budget-${base}'
  properties: {
    category: 'Cost'
    amount: monthlyBudget
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
    }
    notifications: {
      actual80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactRoles: [
          'Owner'
        ]
        contactEmails: budgetContactEmails
      }
      forecast100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
        contactRoles: [
          'Owner'
        ]
        contactEmails: budgetContactEmails
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Start here: a portal dashboard with next steps and live gateway charts, and a link to the
// next-steps web page. Azure has no post-deployment redirect, so these are the landing pages.
// ---------------------------------------------------------------------------
var gatewayEndpoint = 'https://${aiGateway.properties.?frontend.?defaultHostname ?? ''}/'
var chatUrl = '${gatewayEndpoint}default/models/openai/v1/chat/completions'
var tokenAudience = 'https://azure-api.net/aigateway'
var aliasNames = map(allAliases, a => a.name)
var firstModel = contains(aliasNames, 'gpt-latest') || empty(aliasNames) ? 'gpt-latest' : aliasNames[0]
var portalBase = 'https://portal.azure.com/#@${tenant().tenantId}'
var dashboardName = 'start-${base}'
var dashboardUrl = '${portalBase}/dashboard/arm${resourceGroup().id}/providers/Microsoft.Portal/dashboards/${dashboardName}'
var foundryOnlyNames = map(filter(effectiveModels, m => !(m.?gateway ?? true)), m => m.?deploymentName ?? m.name)
var decisionGatewayNames = map(filter(gatewayModelList, m => contains(m.?endpoints ?? [], '/providers/microsoft/v1/systemone')), m => m.?deploymentName ?? m.name)
var chatAliasNames = filter(aliasNames, a => !contains(decisionGatewayNames, a))
var nextStepsUrl = '${nextStepsBaseUrl}#kind=aigateway&gateway=${uriComponent(take(gatewayEndpoint, length(gatewayEndpoint) - 1))}&aigw=${uriComponent(aiGateway.name)}&aigwId=${uriComponent(aiGateway.id)}&models=${uriComponent(join(chatAliasNames, ','))}&decision=${uriComponent(join(decisionGatewayNames, ','))}&foundry=${uriComponent(modelAccount.id)}&insights=${uriComponent(gatewayInsights.id)}&dashboard=${uriComponent(dashboardUrl)}&budget=${monthlyBudget}&rg=${uriComponent(resourceGroup().id)}&tenant=${tenant().tenantId}'
var startHereMarkdown = join([
  '## Your AI Gateway is ready'
  ''
  'Call models at **${gatewayEndpoint}** with your Microsoft Entra account. The account that deployed this stack already has access.'
  ''
  '**Models:** ${join(aliasNames, ', ')}${empty(foundryOnlyNames) ? '' : ' (Foundry only: ${join(foundryOnlyNames, ', ')})'}'
  ''
  '### Next steps'
  '1. [Open the next-steps page](${nextStepsUrl}) for copy-ready calls and settings.'
  '2. Try a call from a terminal:'
  '```'
  'TOKEN=$(az account get-access-token --resource ${tokenAudience} --query accessToken -o tsv)'
  'curl -s ${chatUrl} -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d \'{"model":"${firstModel}","messages":[{"role":"user","content":"Hello"}]}\''
  '```'
  '3. Give others access: assign the **AI Gateway User** role on [the gateway resource](${portalBase}/resource${aiGateway.id}/users).'
  '4. See traces with token usage in [Application Insights](${portalBase}/resource${gatewayInsights.id}/logs).'
  '5. Track spend against the **${monthlyBudget} per month** budget in [Cost analysis](${portalBase}/resource${resourceGroup().id}/costanalysis).'
  '6. Manage models and policies in the [AI Gateway portal](https://ai.gateway.azure.com/ai-gateways) (preview). Gateways created from templates may not appear in its list yet.'
], '\n')

resource startDashboard 'Microsoft.Portal/dashboards@2020-09-01-preview' = {
  name: dashboardName
  location: location
  tags: union(tags, {
    'hidden-title': 'Start here: ${gatewayName}'
  })
  properties: {
    lenses: [
      {
        order: 0
        parts: [
          {
            position: { x: 0, y: 0, colSpan: 8, rowSpan: 9 }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  settings: {
                    content: startHereMarkdown
                    title: 'Start here'
                    subtitle: gatewayName
                  }
                }
              }
            }
          }
          {
            position: { x: 8, y: 0, colSpan: 6, rowSpan: 4 }
            metadata: {
              inputs: [
                {
                  name: 'options'
                  isOptional: true
                  value: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: { id: gatewayInsights.id }
                          name: 'requests/count'
                          aggregationType: 7
                          namespace: 'microsoft.insights/components'
                          metricVisualization: { displayName: 'Gateway requests' }
                        }
                      ]
                      title: 'Gateway requests'
                      titleKind: 1
                      visualization: { chartType: 2 }
                      timespan: { relative: { duration: 86400000 }, showUTCTime: false, grain: 1 }
                    }
                  }
                }
                {
                  name: 'sharedTimeRange'
                  isOptional: true
                }
              ]
              #disable-next-line BCP036
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              settings: {}
            }
          }
          {
            position: { x: 8, y: 4, colSpan: 6, rowSpan: 4 }
            metadata: {
              inputs: [
                {
                  name: 'options'
                  isOptional: true
                  value: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: { id: gatewayInsights.id }
                          name: 'requests/failed'
                          aggregationType: 7
                          namespace: 'microsoft.insights/components'
                          metricVisualization: { displayName: 'Failed requests' }
                        }
                      ]
                      title: 'Failed requests'
                      titleKind: 1
                      visualization: { chartType: 2 }
                      timespan: { relative: { duration: 86400000 }, showUTCTime: false, grain: 1 }
                    }
                  }
                }
                {
                  name: 'sharedTimeRange'
                  isOptional: true
                }
              ]
              #disable-next-line BCP036
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              settings: {}
            }
          }
        ]
      }
    ]
    metadata: {
      model: {
        timeRange: {
          value: { relative: { duration: 24, timeUnit: 1 } }
          type: 'MsPortalFx.Composition.Configuration.ValueTypes.TimeRange'
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs: what a consumer needs. Production callers use an Entra token for the gateway
// audience plus an AI Gateway role. Every gateway also has a built-in "master" API key for
// testing; getApiKeyCommand reads it (the key itself is never output).
// ---------------------------------------------------------------------------

@description('Start here: portal dashboard with next steps and live gateway charts.')
output startHere string = dashboardUrl
@description('Next-steps web page with copy-ready calls for this deployment.')
output nextStepsUrl string = nextStepsUrl
output monthlyBudget int = monthlyBudget
output aiGatewayName string = aiGateway.name
output aiGatewayId string = aiGateway.id
output aiGatewayEndpoint string = gatewayEndpoint
output chatCompletionsUrl string = chatUrl
output responsesUrl string = '${gatewayEndpoint}default/models/openai/v1/responses'
output tokenAudience string = tokenAudience
output gatewayModelNames array = aliasNames
output foundryOnlyDeployments array = [for m in filter(effectiveModels, m => !(m.?gateway ?? true)): m.?deploymentName ?? m.name]
output decisionUrl string = '${gatewayEndpoint}default/models/providers/microsoft/v1/systemone'
output decisionModelNames array = decisionGatewayNames
output foundryEndpoint string = modelAccount.properties.endpoint
output accessGrantedTo array = grantExtraPrincipal ? [deployerId, principalId] : [deployerId]
output tryIt string = 'TOKEN=$(az account get-access-token --resource ${tokenAudience} --query accessToken -o tsv); curl -s ${chatUrl} -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d \'{"model":"${firstModel}","messages":[{"role":"user","content":"Hello"}]}\''
output getApiKeyCommand string = 'az rest --method post --url "${aiGateway.id}/apiKeys/master/listSecrets?api-version=2025-09-01-preview" --query primaryKey -o tsv'
output tryItWithKey string = 'curl -s ${chatUrl} -H "Api-Key: <key from getApiKeyCommand>" -H "Content-Type: application/json" -d \'{"model":"${firstModel}","messages":[{"role":"user","content":"Hello"}]}\''
output grantAccessCommand string = 'az role assignment create --role "AI Gateway User" --assignee <object-id> --scope ${aiGateway.id}'
output gatewayAppInsightsName string = gatewayInsights.name
@description('AI Gateway portal. Select this gateway in the list once; the portal remembers it.')
output aiGatewayPortalUrl string = 'https://ai.gateway.azure.com/ai-gateways'
output azurePortalUrl string = 'https://portal.azure.com/#@${tenant().tenantId}/resource${aiGateway.id}/overview'
