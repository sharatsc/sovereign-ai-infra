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
    allowProjectManagement: false
    customSubDomainName: modelAccountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
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
// Outputs: what a consumer needs. Callers use an Entra token for the gateway audience plus an
// AI Gateway role.
// ---------------------------------------------------------------------------
var gatewayEndpoint = 'https://${aiGateway.properties.?frontend.?defaultHostname ?? ''}/'
var chatUrl = '${gatewayEndpoint}default/models/openai/v1/chat/completions'
var tokenAudience = 'https://azure-api.net/aigateway'

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
output deploymentTemplate string = option.template
output license string = selected.license
output huggingFaceModel string = selected.huggingFace
output deploymentScope string = 'Global'
output foundryEndpoint string = modelAccount.properties.endpoint
output aiGatewayName string = aiGateway.name
output aiGatewayId string = aiGateway.id
output aiGatewayEndpoint string = gatewayEndpoint
output grantAccessCommand string = 'az role assignment create --role "AI Gateway User" --assignee <object-id> --scope ${aiGateway.id}'
