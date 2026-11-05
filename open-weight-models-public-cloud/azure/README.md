# Open weight models on public cloud (Azure)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsharatsc%2Fsovereign-ai-infra%2Fmain%2Fopen-weight-models-public-cloud%2Fazure%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fsharatsc%2Fsovereign-ai-infra%2Fmain%2Fopen-weight-models-public-cloud%2Fazure%2FcreateUiDefinition.json)

This template is the reference implementation of the **open weight models on public
cloud** variant from the Sovereign AI briefing. One open weight model runs on dedicated
accelerators in Microsoft Foundry managed compute. Applications call it through an AI
Gateway, which controls access and traces every call. The gateway is the only way in.

The button opens a portal form. You pick the model and its hardware, and the form shows
the hourly and monthly cost before you deploy.

> **Global deployment: inference may run in any Azure region, including outside the United
> States, until Data Zone US is available.** See [issue #1](https://github.com/brk-tech-labs/sovereign-ai/issues/1).

## What it deploys

| Resource | Purpose |
|---|---|
| Azure AI Services account (Foundry), with one project | Hosts the model; local keys disabled |
| Managed compute deployment (Global, preview) | The model on dedicated accelerators, billed every hour it runs |
| AI Gateway (Standard, preview) | The only endpoint for the model, with Entra ID access control |
| Connector gateway with the same name | Pairs the gateway with the [AI Gateway portal](https://ai.gateway.azure.com/ai-gateways) |
| Application Insights | Gateway traces |
| Log Analytics workspace | Storage for the traces |
| Workbook "Start here" | Landing page in the Azure portal: model, cost, calls, failures and links |
| Cost Management budget | Monthly budget with alerts at 80% actual and 100% forecast spend |

The managed compute deployment needs a Foundry project when it is created. Without one it
reports success but returns 404 on every call, so the template creates the project first.

## Models

One model per deployment. The model and its hardware options come from
[`catalog.json`](catalog.json), which also generates the portal form.

| Model | Publisher | License | Hugging Face weights | Registry model |
|---|---|---|---|---|
| gpt-oss-20b | OpenAI | [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0) | [`openai/gpt-oss-20b`](https://huggingface.co/openai/gpt-oss-20b) | `openai--gpt-oss-20b` version 7 |
| Nemotron 3.5 Lightning 30B (NVFP4) | NVIDIA | [OpenMDW-1.1](https://openmdw.ai/license/1-1/) | [`nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4`](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4) | `nvidia--nvidia-nemotron-3.5-lightning-30b-a3b-nvfp4` version 3 |
| Muse Glimmer 30B | Meta | [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0) | [`meta-models/Muse-Glimmer-30B`](https://huggingface.co/meta-models/Muse-Glimmer-30B) | `meta-models--muse-glimmer-30b` version 2 |
| Gemma 4 31B | Google | [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0) | [`google/gemma-4-31B-it`](https://huggingface.co/google/gemma-4-31B-it) | `google--gemma-4-31b-it` version 7 |

## Cost

Managed compute bills every hour the deployment runs, whether or not it gets calls. The
rates are the Global per-accelerator-hour prices from the Azure retail prices API
(Foundry Models, Managed Compute, 2026-11-04): A100 80 GB 3.95 USD, H100 80 GB 7.91 USD,
MI300X 192 GB 7.91 USD. A month is 730 hours. For one instance:

| Model | `optionKey` | Hardware | USD an hour | USD a month |
|---|---|---|---|---|
| gpt-oss-20b | `a100` | 1 × NVIDIA A100 80 GB, 128K context | 3.95 | 2,884 |
| gpt-oss-20b | `h100` | 1 × NVIDIA H100 80 GB, 128K context | 7.91 | 5,775 |
| gpt-oss-20b | `mi300x` | 1 × AMD MI300X 192 GB, 128K context | 7.91 | 5,775 |
| Nemotron 3.5 Lightning 30B (NVFP4) | `a100` | 1 × NVIDIA A100 80 GB, 256K context | 3.95 | 2,884 |
| Nemotron 3.5 Lightning 30B (NVFP4) | `h100` | 1 × NVIDIA H100 80 GB, 256K context | 7.91 | 5,775 |
| Nemotron 3.5 Lightning 30B (NVFP4) | `2xa100` | 2 × NVIDIA A100 80 GB, 256K context | 7.90 | 5,767 |
| Nemotron 3.5 Lightning 30B (NVFP4) | `2xh100` | 2 × NVIDIA H100 80 GB, 256K context | 15.82 | 11,549 |
| Muse Glimmer 30B | `a100` | 1 × NVIDIA A100 80 GB, 64K context | 3.95 | 2,884 |
| Muse Glimmer 30B | `h100` | 1 × NVIDIA H100 80 GB, 64K context | 7.91 | 5,775 |
| Muse Glimmer 30B | `2xa100` | 2 × NVIDIA A100 80 GB, 128K context | 7.90 | 5,767 |
| Muse Glimmer 30B | `2xh100` | 2 × NVIDIA H100 80 GB, 128K context | 15.82 | 11,549 |
| Muse Glimmer 30B | `mi300x` | 1 × AMD MI300X 192 GB, 128K context | 7.91 | 5,775 |
| Gemma 4 31B | `a100` | 1 × NVIDIA A100 80 GB, 16K context | 3.95 | 2,884 |
| Gemma 4 31B | `h100` | 1 × NVIDIA H100 80 GB, 16K context | 7.91 | 5,775 |
| Gemma 4 31B | `2xa100` | 2 × NVIDIA A100 80 GB, 256K context | 7.90 | 5,767 |
| Gemma 4 31B | `2xh100` | 2 × NVIDIA H100 80 GB, 256K context | 15.82 | 11,549 |
| Gemma 4 31B | `mi300x` | 1 × AMD MI300X 192 GB, 256K context | 7.91 | 5,775 |

More instances multiply the cost. The gateway, monitoring and budget add little next to
the accelerators. The budget defaults to the monthly estimate plus 10%, rounded up to the
next 100; set `monthlyBudget` to change it.

## Use the deployment

Azure has no redirect after a deployment, so the template gives you two landing pages:

- **Start here workbook** (the `startHere` output). It shows the model, its license and
  scope, the cost, a ready-to-run call and the stop-billing command. It charts calls and
  failures from Application Insights, and links to the next-steps page, the gateway's
  access control, traces, cost analysis, Foundry and the AI Gateway portal.
- **Next-steps page** (the `nextStepsUrl` output). It has a ready-to-run call and links
  for this deployment.

If you start from the Deploy to Azure button on the Sovereign AI briefing site, the site
follows the deployment and opens the next-steps page when it finishes. The template
reports the start and the finish to the site, as described in the
[frontier models template](../../provider-models-public-cloud/azure/README.md#deployment-status-reports).
Clear **Report deployment status** in the form, or set `reportUrl` to an empty string, to
turn reports off.

The deployment's **Outputs** list what a consumer needs:

| Output | Use |
|---|---|
| `chatCompletionsUrl` | OpenAI Chat Completions endpoint on the gateway |
| `gatewayModelNames` | Value for the request's `model` field |
| `tokenAudience` | Audience for the Entra ID access token |
| `tryIt` | A ready-to-run curl call with an Entra token |
| `estimatedHourlyCost`, `estimatedMonthlyCost`, `monthlyBudget` | Cost in USD and the budget amount |
| `model`, `deploymentTemplate`, `license`, `huggingFaceModel`, `deploymentScope` | What runs, under which license, and where |
| `stopBillingCommand` | The commands that stop billing, in the order Azure needs |
| `nextStepsUrl`, `startHere` | Next-steps page and the Start here workbook |
| `grantAccessCommand` | Give another user, group or app access |

Call the model with Entra ID:

```bash
TOKEN=$(az account get-access-token --resource https://azure-api.net/aigateway --query accessToken -o tsv)
curl -s "<chatCompletionsUrl>" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"gpt-oss-20b","messages":[{"role":"user","content":"Hello"}]}'
```

The account that ran the deployment can call immediately. Grant others the
**AI Gateway User** role with `grantAccessCommand`, or the `principalId` parameter.

## Model sovereignty

The briefing's guidance for this variant, and how the template meets it:

- **Pinned releases.** Model weights are pinned to a tested release. The serving template
  (runtime, GPUs, context) follows Microsoft's latest; verify-catalog.sh flags when it moves
  from the tested version. The deployment uses `versionUpgradeOption: NoAutoUpgrade`, so
  Foundry doesn't move it to a newer model version. A new model release means a change to
  `catalog.json`, which is the approval step. Managed compute accepts only `labels/latest`
  deployment templates, so `catalog.json` records each tested `templateVersion`, and
  [`scripts/verify-catalog.sh`](scripts/verify-catalog.sh) reports a mismatch when the
  label moves. Run it before you deploy.
- **The gateway is the only way in.** The deployer and `principalId` get the AI Gateway
  User role and no role on the Foundry account. Local keys are disabled, so only the
  gateway's managed identity can call the model in Foundry. The gateway has one alias, with
  the model's own name and no fallback: if the model can't serve a request, the request
  fails rather than going to another model.
- **License and exit route.** The form, outputs, workbook and next-steps page show the
  license and the Hugging Face ID. The same weights run anywhere: to leave public cloud,
  take them from Hugging Face to the briefing's **open weight models on private cloud**
  variant.
- **Payload capture is off.** Traces keep timing, status and sizes, but no prompt or
  completion text. Token usage is still in Foundry metrics. Turn on `payloadCapture` only if
  your data policy allows storing prompts in Application Insights.
- **Preview status.** Managed compute and AI Gateway are both in preview. See
  [Preview status](#preview-status).

## Known gaps

- **No per-caller token limits.** AI Gateway has no policy resource yet, so the template
  can't set token or request limits per caller.
- **No private endpoint between the gateway and Foundry.** The gateway reaches Foundry over
  its public endpoint, with its managed identity.
- **No built-in content filtering.** Managed compute in preview doesn't apply Foundry content
  filters.
- **Global scope only.** Inference may run in any Azure region, including outside the United
  States. Data Zone US is tracked in [issue #1](https://github.com/brk-tech-labs/sovereign-ai/issues/1).

## Stop billing

The deployment is billed every hour it runs. Azure refuses to delete the resource group
while a managed compute deployment exists, and leaves the deployment billing. Delete the
managed compute deployment first, wait until it's gone, then delete the resource group and
purge the Foundry account. The `stopBillingCommand` output has the exact commands, in this
form:

```bash
az rest --method delete --url "https://management.azure.com<foundry account ID>/managedComputeDeployments/<model>?api-version=2026-11-01" && while az rest --method get --url "https://management.azure.com<foundry account ID>/managedComputeDeployments/<model>?api-version=2026-11-01" -o none 2>/dev/null; do sleep 30; done && az group delete --subscription <subscription ID> -n <resource group> && az cognitiveservices account purge --subscription <subscription ID> -l eastus2 -g <resource group> -n <account name>
```

`az group delete` asks you to confirm and shows the group name. You can also delete the
deployment in the Foundry portal under **Deployments**, then delete the group.

## Before you deploy

- You need Owner, or Contributor plus User Access Administrator, on the target resource
  group. The template creates role assignments.
- Check managed compute quota. It is Global, per accelerator family, 8 accelerators by
  default. Each instance uses the option's accelerator count. Not enough quota fails the
  deployment late, after the gateway exists:

  ```bash
  az rest --method get --url "https://management.azure.com/subscriptions/<subscription ID>/providers/Microsoft.CognitiveServices/locations/eastus2/managedComputeUsages?api-version=2026-11-01"
  ```
- Run `scripts/verify-catalog.sh` to check that each serving template is still the tested
  version.

## Deploy with the Azure CLI

```bash
az group create -n rg-sovai-open-weight -l eastus2
az deployment group create -g rg-sovai-open-weight -f main.bicep \
  -p modelKey=gpt-oss-20b optionKey=a100 instances=1
```

Parameters: `modelKey` (`gpt-oss-20b`, `nemotron-35-lightning-30b`, `muse-glimmer-30b` or
`gemma-4-31b`), `optionKey` (a hardware key from the cost table; empty uses the cheapest),
`instances` (1 to 4), `principalId`, `payloadCapture`, `monthlyBudget` and
`budgetAlertEmail`. A hardware key the model doesn't have fails validation, before anything
is created.

`azuredeploy.json` and `createUiDefinition.json` are generated:

```bash
node scripts/build.mjs
node --test 'test/*.test.mjs'
```

## Redeploy and switch models

Redeploying into the same resource group updates the stack. Azure can't change a budget's
start date, so in a later month pass the original one, for example
`budgetStartDate=2026-11-01`.

To switch models, delete the resource group or the old deployment first. Deployments are
incremental, so redeploying with another model adds a second managed compute deployment and
leaves the old one running and billed.

## Preview status

Foundry managed compute and AI Gateway are in public preview. Preview services have no SLA,
and their APIs and pricing can change. Review the preview terms before production use.
