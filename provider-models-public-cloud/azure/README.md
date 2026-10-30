# Provider models in public cloud (Azure)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsharatsc%2Fsovereign-ai-infra%2Fmain%2Fprovider-models-public-cloud%2Fazure%2Fazuredeploy.json)

This template is the reference implementation of the **provider models in public
cloud** variant from the Sovereign AI briefing. Applications call provider-hosted
models in Microsoft Foundry through one AI Gateway endpoint. The gateway applies access control and records telemetry.

It follows Azure-Samples [AI-Gateway `aigw-foundry-models`](https://github.com/Azure-Samples/AI-Gateway/tree/main/labs/aigw-foundry-models)
and [simple-foundry-hosted-agent-python-aigateway](https://github.com/Azure-Samples/simple-foundry-hosted-agent-python-aigateway),
deployed into one resource group.

## What it deploys

| Component | Resources |
|---|---|
| AI Gateway | AI Gateway (Premium, preview), connector namespace, Application Insights, Log Analytics workspace |
| Foundry models | Azure AI Services account with local keys disabled, one Global Standard deployment per model |
| Foundry agents | Azure AI Services account, Foundry project, storage account, container registry, Application Insights, Log Analytics workspace |

Default models:

| Provider | Deployments | Reached through |
|---|---|---|
| OpenAI | gpt-6.1-sol, gpt-6-sol, gpt-6-luna, gpt-6-astra | AI Gateway |
| Microsoft | Microsoft-Decision-1 (preview), deployed as `decision-1` | Foundry endpoint only |

AI Gateway registers chat, Responses, completions, embeddings, image and Anthropic
Messages models. It does not route decision models yet, so `decision-1` is called on
the Foundry model account endpoint (output `modelAccountEndpoint`) with Microsoft
Entra ID. Set `gateway: false` on any other model you want in Foundry only.

Anthropic Claude models are not deployed by default. To add them, see
[Add Claude models](#add-claude-models).

Callers reach models only through gateway aliases. Every deployment gets an alias
with its own name, such as `gpt-6-luna`. The alias `gpt-latest` fails over from
gpt-6.1-sol to gpt-6-sol when the first is unavailable or out of quota.

## How access works

- **Inbound.** Callers authenticate to the gateway with Microsoft Entra ID. Request a
  token for the audience `https://azure-api.net/aigateway` and grant the caller an
  AI Gateway role (AI Gateway User, AI Gateway Models User or AI Gateway Tools User).
  The `principalId` parameter assigns AI Gateway User to one user, group or service
  principal. A gateway API key is created only when `createApiKey` is true.
- **Outbound.** The gateway reaches Foundry with its system-assigned managed
  identity, which holds the Foundry User role on the model account. No provider
  keys are stored.
- **Telemetry.** The gateway exports OpenTelemetry-based request, token and latency
  telemetry to its Application Insights resource. Payload capture is off by default.

## Before you deploy

- You need Owner, or Contributor plus User Access Administrator, on the target
  resource group. The template creates role assignments.
- Pick a region with AI Gateway preview support and the models you want: East US 2
  or Sweden Central.
- Check Global Standard quota for each model in that region. Lower a model's
  `capacity`, or remove it from `models`, if quota is short.

## Deploy with the Azure CLI

```bash
az group create -n rg-sovai-provider-cloud -l eastus2
az deployment group create -g rg-sovai-provider-cloud -f main.bicep \
  -p principalId="$(az ad signed-in-user show --query id -o tsv)"
```

`azuredeploy.json` is compiled from `main.bicep`. After editing the Bicep, rebuild it:

```bash
az bicep build -f main.bicep --outfile azuredeploy.json
```

## Call a model

```bash
TOKEN=$(az account get-access-token --resource https://azure-api.net/aigateway --query accessToken -o tsv)
curl "<aiGatewayEndpoint>default/models/openai/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"gpt-latest","messages":[{"role":"user","content":"Hello"}]}'
```

## Add Claude models

Add entries with `format: Anthropic` to `models`, for example
`{ "name": "claude-sonnet-5-5", "format": "Anthropic", "version": "2", "capacity": 20 }`,
and set `organizationName` (plus `industry` and `countryCode` if the defaults don't
fit). Foundry sends these three values to Anthropic.

The subscription must be able to buy the Anthropic offer in Azure Marketplace. If a
deployment fails with `MarketplaceSubscriptionCannotBeCompleted`, ask Microsoft to
allowlist the subscription. Claude models are called with the Anthropic Messages
protocol at `<aiGatewayEndpoint>default/models/anthropic/v1/messages`.

## Preview status

AI Gateway is in public preview. Preview services have no SLA, and their APIs and
pricing can change. Review the preview terms before production use.
