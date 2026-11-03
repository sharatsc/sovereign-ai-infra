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

@description('First day of the budget period (the first of a month). Azure cannot change a budget start date, so keep this fixed across redeployments.')
param budgetStartDate string = '2026-01-01'

@description('Web page that shows next steps for this deployment. The deployment appends its values to the URL fragment.')
param nextStepsBaseUrl string = 'https://brk-tech-sovereign-ai.azurewebsites.net/next-steps.html'

@description('Sovereign AI site endpoint that records when this deployment starts and finishes, so the site can follow it and list it under Your deployments. Sends the tenant, subscription, resource group and deployment names, your Entra object ID and the next-steps values. Leave empty to turn off.')
param reportUrl string = 'https://brk-tech-sovereign-ai.azurewebsites.net/api/deployments/report'

@description('Unique value for each run, so Azure fetches the report URL again on redeploys.')
param reportNonce string = newGuid()

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
// Start here: a workbook with live models, usage charts and actions, and a link to the next-steps
// web page. Azure has no post-deployment redirect, so these are the landing pages.
// ---------------------------------------------------------------------------
var gatewayEndpoint = 'https://${aiGateway.properties.?frontend.?defaultHostname ?? ''}/'
var chatUrl = '${gatewayEndpoint}default/models/openai/v1/chat/completions'
var tokenAudience = 'https://azure-api.net/aigateway'
var aliasNames = map(allAliases, a => a.name)
var firstModel = contains(aliasNames, 'gpt-latest') || empty(aliasNames) ? 'gpt-latest' : aliasNames[0]
var portalBase = 'https://portal.azure.com/#@${tenant().tenantId}'
// The Start here workbook is attached to the resource group, so it appears in the resource list
// and under the group's Workbooks menu. Its name is fixed so the next-steps link can point to it.
var startHereName = guid(resourceGroup().id, base, 'start-here')
var startHereUrl = '${portalBase}/resource${resourceId('Microsoft.Insights/workbooks', startHereName)}/workbook'
var decisionGatewayNames = map(filter(gatewayModelList, m => contains(m.?endpoints ?? [], '/providers/microsoft/v1/systemone')), m => m.?deploymentName ?? m.name)
var chatAliasNames = filter(aliasNames, a => !contains(decisionGatewayNames, a))
var nextStepsFragment = 'kind=aigateway&gateway=${uriComponent(take(gatewayEndpoint, length(gatewayEndpoint) - 1))}&aigw=${uriComponent(aiGateway.name)}&aigwId=${uriComponent(aiGateway.id)}&models=${uriComponent(join(chatAliasNames, ','))}&decision=${uriComponent(join(decisionGatewayNames, ','))}&foundry=${uriComponent(modelAccount.id)}&insights=${uriComponent(gatewayInsights.id)}&dashboard=${uriComponent(startHereUrl)}&budget=${monthlyBudget}&rg=${uriComponent(resourceGroup().id)}&tenant=${tenant().tenantId}'
var nextStepsUrl = '${nextStepsBaseUrl}#${nextStepsFragment}'
var startHereMarkdown = join([
  '## Your AI Gateway is ready'
  ''
  'Call models at **${gatewayEndpoint}** with your Microsoft Entra account. The account that deployed this stack already has access. Give others access with the **AI Gateway User** role.'
  ''
  '```bash'
  'TOKEN=$(az account get-access-token --resource ${tokenAudience} --query accessToken -o tsv)'
  'curl -s ${chatUrl} -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d \'{"model":"${firstModel}","messages":[{"role":"user","content":"Hello"}]}\''
  '```'
  ''
  'The **next steps** page has copy-ready calls for every model, including decision models. The monthly budget is **${monthlyBudget}** in your billing currency.'
], '\n')
var linkId = guid(resourceGroup().id, base, 'start-here-links')
var startHereLinks = [
  { id: '${linkId}-1', cellValue: nextStepsUrl, linkTarget: 'Url', linkLabel: 'Next steps and code', style: 'primary', icon: 'Info' }
  { id: '${linkId}-2', cellValue: aiGateway.id, linkTarget: 'ResourceOverview', subTarget: 'users', linkLabel: 'Grant access', style: 'secondary', icon: 'Security' }
  { id: '${linkId}-3', cellValue: gatewayInsights.id, linkTarget: 'ResourceOverview', subTarget: 'logs', linkLabel: 'Traces', style: 'secondary', icon: 'Search' }
  { id: '${linkId}-4', cellValue: resourceGroup().id, linkTarget: 'ResourceOverview', subTarget: 'costanalysis', linkLabel: 'Cost analysis', style: 'secondary', icon: 'Cost' }
  { id: '${linkId}-5', cellValue: 'https://ai.azure.com/resource/overview?wsid=${uriComponent(modelAccount.id)}&tid=${tenant().tenantId}', linkTarget: 'Url', linkLabel: 'Microsoft Foundry', style: 'secondary', icon: 'Info' }
  { id: '${linkId}-6', cellValue: 'https://ai.gateway.azure.com/ai-gateways', linkTarget: 'Url', linkLabel: 'AI Gateway portal', style: 'secondary', icon: 'Info' }
]
// Live list of the aliases callers can use, read from the gateway when the workbook opens.
var aliasesQuery = {
  version: 'ARMEndpoint/1.0'
  data: null
  headers: []
  method: 'GET'
  path: '${aiGateway.id}/workspaces/${workspaceName}/aliases'
  urlParams: [
    { key: 'api-version', value: '2025-09-01-preview' }
  ]
  batchDisabled: false
  transformers: [
    {
      type: 'jsonpath'
      settings: {
        tablePath: '$.value'
        columns: [
          { path: '$.name', columnid: 'Model' }
          { path: '$.properties.gatewayEndpoints[0].url', columnid: 'Endpoint' }
          { path: '$.properties.description', columnid: 'Description' }
        ]
      }
    }
  ]
}
var usageBase = 'requests | where name has "/default/models/" | extend Model = tostring(customDimensions["gen_ai.response.model"]), Tokens = toint(customMeasurements["gen_ai.usage.input_tokens"]) + toint(customMeasurements["gen_ai.usage.output_tokens"])'
var logsItem = {
  version: 'KqlItem/1.0'
  size: 0
  timeContextFromParameter: 'TimeRange'
  queryType: 0
  resourceType: 'microsoft.insights/components'
  crossComponentResources: [ gatewayInsights.id ]
}
var startHereData = {
  version: 'Notebook/1.0'
  items: [
    { type: 1, name: 'intro', content: { json: startHereMarkdown } }
    { type: 11, name: 'actions', content: { version: 'LinkItem/1.0', style: 'toolbar', links: startHereLinks } }
    {
      type: 3
      name: 'models'
      content: {
        version: 'KqlItem/1.0'
        query: string(aliasesQuery)
        size: 1
        title: 'Models you can call'
        noDataMessage: 'No models yet. Check that the deployment finished.'
        queryType: 12
        visualization: 'table'
      }
    }
    {
      type: 9
      name: 'time'
      content: {
        version: 'KqlParameterItem/1.0'
        style: 'pills'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        parameters: [
          {
            id: guid(resourceGroup().id, base, 'start-here-time')
            version: 'KqlParameterItem/1.0'
            name: 'TimeRange'
            label: 'Time range'
            type: 4
            isRequired: true
            value: { durationMs: 86400000 }
            typeSettings: {
              selectableValues: [
                { durationMs: 3600000 }
                { durationMs: 86400000 }
                { durationMs: 604800000 }
                { durationMs: 2592000000 }
              ]
              allowCustom: true
            }
          }
        ]
      }
    }
    {
      type: 3
      name: 'tokens'
      customWidth: '50'
      content: union(logsItem, {
        query: '${usageBase} | summarize Tokens = sum(Tokens) by bin(timestamp, {TimeRange:grain}), Model | render timechart'
        title: 'Tokens by model'
        noDataMessage: 'No calls in this time range yet.'
        visualization: 'timechart'
      })
    }
    {
      type: 3
      name: 'failures'
      customWidth: '50'
      content: union(logsItem, {
        query: 'requests | where name has "/default/models/" | summarize Calls = count(), Failed = countif(success == false) by bin(timestamp, {TimeRange:grain}) | render timechart'
        title: 'Calls and failures'
        noDataMessage: 'No calls in this time range yet.'
        visualization: 'timechart'
      })
    }
    {
      type: 3
      name: 'calls'
      content: union(logsItem, {
        query: '${usageBase} | summarize Calls = count(), Failed = countif(success == false), Tokens = sum(Tokens), AvgMs = round(avg(duration), 0) by Model, Operation = name | order by Calls desc'
        title: 'Calls by model'
        noDataMessage: 'No calls in this time range yet.'
        visualization: 'table'
      })
    }
  ]
  isLocked: false
  fallbackResourceIds: [ resourceGroup().id ]
}

resource startHere 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: startHereName
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'Start here: ${gatewayName}'
    category: 'workbook'
    sourceId: toLower(resourceGroup().id)
    serializedData: string(startHereData)
    version: 'Notebook/1.0'
  }
  dependsOn: [ gatewayAliases ]
}

// ---------------------------------------------------------------------------
// Deployment reports: Azure has no redirect after a deployment, so the briefing site follows it.
// Azure fetches each report URL as an empty linked template: once at the start, and once after
// everything else with the next-steps values. The site matches reports to the signed-in user by
// Entra object ID. Set reportUrl to '' to turn this off.
// ---------------------------------------------------------------------------
var reportQuery = 'tenant=${tenant().tenantId}&sub=${subscription().subscriptionId}&rg=${uriComponent(resourceGroup().name)}&deployment=${uriComponent(deployment().name)}&oid=${deployerId}&n=${reportNonce}'

// A module can't take a template URL built at deployment time, so this stays a deployments resource.
#disable-next-line no-deployments-resources
resource reportStarted 'Microsoft.Resources/deployments@2022-09-01' = if (!empty(reportUrl)) {
  name: 'report-started-${base}'
  properties: {
    mode: 'Incremental'
    templateLink: {
      uri: '${reportUrl}?event=started&${reportQuery}'
    }
  }
}

// A module can't take a template URL built at deployment time, so this stays a deployments resource.
#disable-next-line no-deployments-resources
resource reportFinished 'Microsoft.Resources/deployments@2022-09-01' = if (!empty(reportUrl)) {
  name: 'report-finished-${base}'
  properties: {
    mode: 'Incremental'
    templateLink: {
      uri: '${reportUrl}?event=finished&${reportQuery}&gateway=${uriComponent(aiGateway.name)}&next=${uriComponent(nextStepsFragment)}'
    }
  }
  dependsOn: [
    startHere
    budget
    telemetryExporter
    gatewayModels
    gatewayUserForDeployer
    modelUserForDeployer
    reportStarted
  ]
}

// ---------------------------------------------------------------------------
// Outputs: what a consumer needs. Production callers use an Entra token for the gateway
// audience plus an AI Gateway role. Every gateway also has a built-in "master" API key for
// testing; getApiKeyCommand reads it (the key itself is never output).
// ---------------------------------------------------------------------------

@description('Start here: workbook in the Azure portal with live models, usage charts and next steps.')
output startHere string = startHereUrl
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
