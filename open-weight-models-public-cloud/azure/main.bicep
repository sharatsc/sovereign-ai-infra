// Sovereign AI reference: open weight models on public cloud (Azure).
// Deploys an AI Gateway in front of one open-weight model on Microsoft Foundry managed compute.
// Model weights are pinned to a tested release. The model, its hardware options and the hourly
// rates come from catalog.json, which also generates the portal form.
// Managed compute and AI Gateway are in preview.
targetScope = 'resourceGroup'

@description('Region for Foundry and monitoring. Managed compute is Global: inference may run in any Azure region, including outside the United States, until Data Zone US is available.')
@allowed([
  'eastus2'
])
param location string = 'eastus2'

@description('Region for the AI Gateway (preview regions only).')
@allowed([
  'eastus2'
])
param aiGatewayLocation string = 'eastus2'

@minLength(3)
@maxLength(8)
@description('Short lowercase prefix for resource names.')
param namePrefix string = 'sovai'

@description('Model to deploy, a key of catalog.json models.')
@allowed([
  'gpt-oss-20b'
  'nemotron-35-lightning-30b'
  'muse-glimmer-30b'
  'gemma-4-31b'
])
param modelKey string = 'gpt-oss-20b'

@description('Hardware option for the model, a key of its catalog.json options (a100, h100, 2xa100, 2xh100 or mi300x). Empty uses the model\'s cheapest option.')
param optionKey string = ''

@minValue(1)
@maxValue(4)
@description('Model instances. Each instance is billed every hour for its accelerators. Global quota is 8 accelerators per family.')
param instances int = 1

@description('Optional extra Entra object ID (user, group or service principal) to grant access. The account that runs the deployment always gets access.')
param principalId string = ''

@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
@description('Type of principalId.')
param principalType string = 'User'

@description('Capture request and response payloads in gateway traces. Off by default, so prompt and completion text is not stored. Turning it on adds token usage (gen_ai.usage.*) and model attributes to traces and stores prompt and completion text in Application Insights.')
param payloadCapture bool = false

@minValue(0)
@description('Monthly budget for this resource group, in the billing currency. 0 uses the estimated monthly cost plus 10%, rounded up to the next 100. Alerts fire at 80% of actual spend and 100% of forecast spend.')
param monthlyBudget int = 0

@description('Optional email address for budget alerts. Resource group owners are always notified.')
param budgetAlertEmail string = ''

@description('First day of the budget period. New budgets must start in the current month, and Azure cannot change the start date later, so when you redeploy in a later month pass the original start date.')
param budgetStartDate string = utcNow('yyyy-MM-01')

@description('Web page that shows next steps for this deployment. The deployment appends its values to the URL fragment.')
param nextStepsBaseUrl string = 'https://brk-tech-sovereign-ai.azurewebsites.net/next-steps.html'

@description('Sovereign AI site endpoint that records when this deployment starts and finishes, so the site can follow it and list it under Your deployments. Sends the tenant, subscription, resource group and deployment names, your Entra object ID and the next-steps values. Leave empty to turn off.')
param reportUrl string = 'https://brk-tech-sovereign-ai.azurewebsites.net/api/deployments/report'

@description('Reports are sent only for deployments in this Entra tenant (BRK Commons), so deployments elsewhere send nothing.')
param reportTenantId string = '1bda714c-00fe-4c7e-aa71-875d787e9d77'

@description('Unique value for each run, so Azure fetches the report URL again on redeploys.')
param reportNonce string = newGuid()

// The catalog pins every model to a /versions/N release, so a deployment runs exactly the weights
// that were tested and approved; a new release needs a catalog change. Managed compute accepts only
// labels/latest deployment templates, so the serving template (runtime, GPUs, context) follows
// Microsoft's latest. The catalog records the tested templateVersion, and scripts/verify-catalog.sh
// flags when labels/latest moves from it.
var catalog = loadJsonContent('catalog.json')
var selected = catalog.models[modelKey]
// Index without a fallback: an option key the model doesn't have fails template validation,
// before anything is created.
var option = selected.options[empty(optionKey) ? selected.defaultOption : optionKey]

// Cost, in integer cents so the portal form can show the same numbers.
var hourlyCents = catalog.rateCentsPerAcceleratorHour[option.accelerator] * option.count * instances
var estimatedHourlyCost = '${hourlyCents / 100}.${padLeft(string(hourlyCents % 100), 2, '0')}'
var estimatedMonthlyCost = (hourlyCents * catalog.hoursPerMonth + 99) / 100
var effectiveBudget = monthlyBudget > 0 ? monthlyBudget : ((estimatedMonthlyCost * 110 / 100) + 99) / 100 * 100

var token = take(toLower(uniqueString(resourceGroup().id, namePrefix)), 6)
var base = '${toLower(namePrefix)}-${token}'
var gatewayName = 'aigw-${base}'
var modelAccountName = 'aimodels-${base}'
var tags = {
  'sovereign-ai-variant': 'open-weight-models-public-cloud'
}
var workspaceName = 'default'
var foundryProviderName = 'foundry'
var deploymentName = selected.deploymentName
var modelVersion = last(split(selected.model, '/'))

// Role definition IDs.
var foundryUserRole = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
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
// Foundry account and the managed compute deployment.
// ---------------------------------------------------------------------------
#disable-next-line BCP081
resource modelAccount 'Microsoft.CognitiveServices/accounts@2026-11-01' = {
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
    allowProjectManagement: true
    customSubDomainName: modelAccountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

// A managed compute deployment serves only if the account has a project when the deployment is
// created. Without one, the deployment reports Succeeded but every route returns 404 "The
// specified endpoint does not exist" (route_not_found), and adding a project later doesn't fix it.
#disable-next-line BCP081
resource project 'Microsoft.CognitiveServices/accounts/projects@2026-11-01' = {
  parent: modelAccount
  name: '${modelAccountName}-project'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Open weight model'
    description: 'Project for the managed compute deployment of ${selected.label}.'
  }
}

// One model on dedicated accelerators, billed every hour it runs. NoAutoUpgrade keeps the pinned
// model release: Foundry doesn't move the deployment to a newer model version.
#disable-next-line BCP081
resource managedDeployment 'Microsoft.CognitiveServices/accounts/managedComputeDeployments@2026-11-01' = {
  parent: modelAccount
  name: deploymentName
  sku: {
    name: 'GlobalManagedCompute'
    capacity: instances
  }
  properties: {
    model: selected.model
    deploymentTemplate: option.template
    acceleratorType: option.accelerator
    versionUpgradeOption: 'NoAutoUpgrade'
  }
  dependsOn: [
    project
  ]
}

// No Cognitive Services User role for the deployer or principalId on the Foundry account: the
// gateway is the only way in. With local keys disabled, nobody but the gateway's managed identity
// can call the model directly.

// ---------------------------------------------------------------------------
// AI Gateway: model provider, model registration, alias and access.
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
    name: 'Standard'
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

// Payload capture is off by default, so prompt and completion text stays out of Application
// Insights. Traces keep timing, status and sizes.
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
resource gatewayModel 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models@2025-09-01-preview' = {
  parent: foundryProvider
  name: deploymentName
  properties: {
    displayName: selected.label
    description: '${selected.label} (${selected.huggingFace}, version ${modelVersion}) on managed compute in ${modelAccountName}.'
    apiFormat: 'OpenAIChatCompletions'
    supportedEndpoints: [
      '/openai/v1/chat/completions'
    ]
    deployment: {
      resourceId: managedDeployment.id
      modelName: deploymentName
      modelVersion: modelVersion
    }
  }
}

// One alias with the model's own name and no fallback: a request is served by this model or
// rejected, never routed to a different model.
#disable-next-line BCP081
resource gatewayAlias 'Microsoft.ApiManagement/aigateways/workspaces/aliases@2025-09-01-preview' = {
  parent: gatewayWorkspace
  name: deploymentName
  dependsOn: [
    gatewayModel
  ]
  properties: {
    aliasName: deploymentName
    description: 'Direct access to ${selected.label}.'
    backendModels: [
      {
        resourceId: resourceId('Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models', gatewayName, workspaceName, foundryProviderName, deploymentName)
        priority: 0
        weight: 100
      }
    ]
  }
}

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
// Budget: monthly cost budget on this resource group, by default the estimate plus 10%.
// ---------------------------------------------------------------------------
var budgetContactEmails = empty(budgetAlertEmail) ? [] : [budgetAlertEmail]

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'budget-${base}'
  properties: {
    category: 'Cost'
    amount: effectiveBudget
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
// Start here: a workbook with the model, cost, usage charts and actions, and a link to the
// next-steps web page. Azure has no post-deployment redirect, so these are the landing pages.
// ---------------------------------------------------------------------------
var gatewayEndpoint = 'https://${aiGateway.properties.?frontend.?defaultHostname ?? ''}/'
var chatUrl = '${gatewayEndpoint}default/models/openai/v1/chat/completions'
var tokenAudience = 'https://azure-api.net/aigateway'
var portalBase = 'https://portal.azure.com/#@${tenant().tenantId}'
// The Start here workbook is attached to the resource group, so it appears in the resource list
// and under the group's Workbooks menu. Its name is fixed so the next-steps link can point to it.
var startHereName = guid(resourceGroup().id, base, 'start-here')
var startHereUrl = '${portalBase}/resource${resourceId('Microsoft.Insights/workbooks', startHereName)}/workbook'
var globalNotice = 'Global deployment: inference may run in any Azure region, including outside the United States, until Data Zone US is available.'
var pinningNotice = 'Model weights are pinned to a tested release. The serving template (runtime, GPUs, context) follows Microsoft\'s latest; verify-catalog.sh flags when it moves from the tested version.'
// Azure won't delete the account, and so the resource group, while a managed compute deployment
// exists, and the deployment keeps billing. So the deployment goes first, then the group, then the
// purge that frees the account name. The next-steps page builds the same command from its values,
// character for character, so the host stays literal.
#disable-next-line no-hardcoded-env-urls
var managedDeploymentUrl = 'https://management.azure.com${modelAccount.id}/managedComputeDeployments/${deploymentName}?api-version=2026-11-01'
var stopBillingCommand = 'az rest --method delete --url "${managedDeploymentUrl}" && while az rest --method get --url "${managedDeploymentUrl}" -o none 2>/dev/null; do sleep 30; done && az group delete --subscription ${subscription().subscriptionId} -n ${resourceGroup().name} && az cognitiveservices account purge --subscription ${subscription().subscriptionId} -l ${location} -g ${resourceGroup().name} -n ${modelAccountName}'
// license and hf stay plain text: the briefing site rejects URL values outside Azure hosts.
var nextStepsFragment = 'kind=aigateway&gateway=${uriComponent(take(gatewayEndpoint, length(gatewayEndpoint) - 1))}&aigw=${uriComponent(aiGateway.name)}&aigwId=${uriComponent(aiGateway.id)}&models=${uriComponent(deploymentName)}&foundry=${uriComponent(modelAccount.id)}&insights=${uriComponent(gatewayInsights.id)}&dashboard=${uriComponent(startHereUrl)}&budget=${effectiveBudget}&rg=${uriComponent(resourceGroup().id)}&tenant=${tenant().tenantId}&variant=open-weight&hourly=${estimatedHourlyCost}&monthly=${estimatedMonthlyCost}&scope=Global&license=${uriComponent(selected.license)}&hf=${uriComponent(selected.huggingFace)}'
var nextStepsUrl = '${nextStepsBaseUrl}#${nextStepsFragment}'
var startHereMarkdown = join([
  '## Your open weight model is ready'
  ''
  '**${selected.label}** (${selected.publisher}) runs on Foundry managed compute: ${option.label}, ${instances} instance(s). License: **${selected.license}**. Weights: **${selected.huggingFace}** on Hugging Face.'
  ''
  pinningNotice
  ''
  'Deployment scope: **Global**. ${globalNotice} Managed compute and AI Gateway are in preview.'
  ''
  'Cost: **${estimatedHourlyCost} USD an hour, about ${estimatedMonthlyCost} USD a month while deployed**. The monthly budget is **${effectiveBudget}** in your billing currency.'
  ''
  'Call the model at **${gatewayEndpoint}** with your Microsoft Entra account. The account that deployed this stack already has access. Give others access with the **AI Gateway User** role. The gateway is the only way in: nobody has a direct role on the model in Foundry.'
  ''
  '```bash'
  'TOKEN=$(az account get-access-token --resource ${tokenAudience} --query accessToken -o tsv)'
  'curl -s ${chatUrl} -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d \'{"model":"${deploymentName}","messages":[{"role":"user","content":"Hello"}]}\''
  '```'
  ''
  '### Stop billing'
  ''
  'The deployment is billed every hour it runs. Azure refuses to delete the resource group while the managed compute deployment exists, and leaves the deployment billing. Delete the deployment first, wait until it is gone, then delete the resource group and purge the Foundry account:'
  ''
  '```bash'
  stopBillingCommand
  '```'
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
        noDataMessage: 'No token data. Traces record tokens only with payload capture, which is off by default; Foundry metrics show token usage.'
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
  dependsOn: [ gatewayAlias ]
}

// ---------------------------------------------------------------------------
// Deployment reports: Azure has no redirect after a deployment, so the briefing site follows it.
// Azure fetches each report URL as an empty linked template: once at the start, and once after
// everything else with the next-steps values. The site matches reports to the signed-in user by
// Entra object ID. Reports go only from the site's own tenant (reportTenantId). Set reportUrl to ''
// to turn this off.
// ---------------------------------------------------------------------------
var sendReports = !empty(reportUrl) && tenant().tenantId == reportTenantId
var reportQuery = 'tenant=${tenant().tenantId}&sub=${subscription().subscriptionId}&rg=${uriComponent(resourceGroup().name)}&deployment=${uriComponent(deployment().name)}&oid=${deployerId}&n=${reportNonce}'

// A module can't take a template URL built at deployment time, so this stays a deployments resource.
#disable-next-line no-deployments-resources
resource reportStarted 'Microsoft.Resources/deployments@2022-09-01' = if (sendReports) {
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
resource reportFinished 'Microsoft.Resources/deployments@2022-09-01' = if (sendReports) {
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
    gatewayModel
    managedDeployment
    gatewayUserForDeployer
    reportStarted
  ]
}

// ---------------------------------------------------------------------------
// Outputs: what a consumer needs. Callers use an Entra token for the gateway audience plus an
// AI Gateway role.
// ---------------------------------------------------------------------------

@description('Start here: workbook in the Azure portal with the model, cost, usage charts and next steps.')
output startHere string = startHereUrl
@description('Next-steps web page with copy-ready calls for this deployment.')
output nextStepsUrl string = nextStepsUrl
output chatCompletionsUrl string = chatUrl
output gatewayModelNames array = [
  deploymentName
]
output tokenAudience string = tokenAudience
output tryIt string = 'TOKEN=$(az account get-access-token --resource ${tokenAudience} --query accessToken -o tsv); curl -s ${chatUrl} -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d \'{"model":"${deploymentName}","messages":[{"role":"user","content":"Hello"}]}\''
@description('Estimated cost in USD for every hour the deployment runs, at Global managed compute rates.')
output estimatedHourlyCost string = estimatedHourlyCost
@description('Estimated cost in USD for a month (730 hours) of running.')
output estimatedMonthlyCost int = estimatedMonthlyCost
output monthlyBudget int = effectiveBudget
output model string = selected.model
@description('Serving template. Managed compute takes only labels/latest; the catalog records the tested version.')
output deploymentTemplate string = option.template
output license string = selected.license
output huggingFaceModel string = selected.huggingFace
output deploymentScope string = 'Global'
output foundryEndpoint string = modelAccount.properties.endpoint
output aiGatewayName string = aiGateway.name
output aiGatewayId string = aiGateway.id
output aiGatewayEndpoint string = gatewayEndpoint
output grantAccessCommand string = 'az role assignment create --role "AI Gateway User" --assignee <object-id> --scope ${aiGateway.id}'
@description('Stops billing: deletes the managed compute deployment, waits until it is gone, then deletes the resource group and purges the Foundry account. Azure refuses to delete the group while the deployment exists.')
output stopBillingCommand string = stopBillingCommand
