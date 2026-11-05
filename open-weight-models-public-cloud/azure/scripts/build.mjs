// Generates createUiDefinition.json from catalog.json, then compiles main.bicep to azuredeploy.json.
// Run: node scripts/build.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { costTable } from './cost.mjs';

const dir = fileURLToPath(new URL('..', import.meta.url));
const catalog = JSON.parse(readFileSync(`${dir}catalog.json`, 'utf8'));
const models = Object.entries(catalog.models);
const hours = catalog.hoursPerMonth;

const globalNotice = 'Global deployment: inference may run in any Azure region, including outside the United States, until Data Zone US is available.';
const pinningNotice = "Model weights are pinned to a tested release. The serving template (runtime, GPUs, context) follows Microsoft's latest; verify-catalog.sh flags when it moves from the tested version.";
const switchNotice = 'To switch models, delete the resource group or the old deployment first. Redeploying with another model adds it and leaves the old one running and billed.';
const quotaUrlSuffix = '/providers/Microsoft.CognitiveServices/locations/eastus2/managedComputeUsages?api-version=2026-11-01';
const reportUrl = 'https://brk-tech-sovereign-ai.azurewebsites.net/api/deployments/report';

const optionName = key => `option_${key.replace(/[-.]/g, '_')}`;
const modelSel = "steps('model').modelKey";
const optionSel = key => `steps('model').${optionName(key)}`;
const dollars = cents => `${Math.floor(cents / 100)}.${String(cents % 100).padStart(2, '0')}`;
const cents = new Map(costTable(catalog).map(r => [`${r.modelKey}/${r.optionKey}`, r.hourlyCents]));

// Nested if(equals(...)) over a list, with a final fallback. Form expressions have no lookups.
const choose = (selector, entries, fallback) =>
  entries.reduceRight((rest, [key, value]) => `if(equals(${selector}, '${key}'), ${value}, ${rest})`, fallback);

// Hourly cents per instance for the selected model and option, times instances.
const optionCents = choose(modelSel, models.map(([key, m]) =>
  [key, choose(optionSel(key), Object.keys(m.options).map(o => [o, cents.get(`${key}/${o}`)]), '0')]), '0');
const hourlyCents = `mul(${optionCents}, steps('model').instances)`;
const monthly = `div(add(mul(${hourlyCents}, ${hours}), 99), 100)`;
// Integer formatting: 1185 -> 11.85, 23098 -> 23,098. Mirrored by uiCost in cost.mjs.
const hourlyText = `concat(string(div(${hourlyCents}, 100)), '.', if(less(mod(${hourlyCents}, 100), 10), '0', ''), string(mod(${hourlyCents}, 100)))`;
const monthlyText = `if(less(${monthly}, 1000), string(${monthly}), concat(string(div(${monthly}, 1000)), ',', if(less(mod(${monthly}, 1000), 10), '00', if(less(mod(${monthly}, 1000), 100), '0', '')), string(mod(${monthly}, 1000))))`;
const costText = `[concat('Estimated cost: $', ${hourlyText}, ' an hour, about $', ${monthlyText}, ' per month (${hours} hours) while deployed. Billed every hour it runs, whether or not it gets calls. To stop billing, delete the model deployment first and then the resource group: Azure refuses to delete the group while the deployment exists. ${globalNotice} ${switchNotice} Check managed compute quota first (Global, 8 accelerators per family by default): az rest --method get --url https://management.azure.com/subscriptions/', subscription().subscriptionId, '${quotaUrlSuffix}')]`;

const modelElements = [
  {
    name: 'modelInfo',
    type: 'Microsoft.Common.InfoBox',
    options: {
      style: 'Info',
      text: `One open weight model runs on dedicated accelerators in Foundry managed compute, behind an AI Gateway. ${pinningNotice} Managed compute and AI Gateway are in preview. ${globalNotice}`,
    },
  },
  {
    name: 'modelKey',
    type: 'Microsoft.Common.DropDown',
    label: 'Model',
    toolTip: 'One model per deployment. Model weights are pinned to a tested release.',
    defaultValue: `${catalog.models['gpt-oss-20b'].label} (${catalog.models['gpt-oss-20b'].publisher})`,
    constraints: {
      allowedValues: models.map(([key, m]) => ({ label: `${m.label} (${m.publisher})`, description: `${m.summary} · ${m.license}`, value: key })),
      required: true,
    },
  },
  ...models.map(([key, m]) => ({
    name: optionName(key),
    type: 'Microsoft.Common.DropDown',
    label: 'Hardware',
    toolTip: 'Accelerators for each model instance, and the context length the deployment template sets.',
    defaultValue: `${m.options[m.defaultOption].label} · $${dollars(cents.get(`${key}/${m.defaultOption}`))}/hour per instance`,
    visible: `[equals(${modelSel}, '${key}')]`,
    constraints: {
      allowedValues: Object.entries(m.options).map(([o, v]) => ({ label: `${v.label} · $${dollars(cents.get(`${key}/${o}`))}/hour per instance`, value: o })),
      required: true,
    },
  })),
  {
    name: 'instances',
    type: 'Microsoft.Common.Slider',
    label: 'Instances',
    subLabel: 'model instances',
    toolTip: 'Each instance runs on its own accelerators and is billed every hour. More instances serve more calls at once.',
    min: 1,
    max: 4,
    step: 1,
    defaultValue: 1,
    showStepMarkers: true,
    constraints: { required: true },
  },
  {
    name: 'cost',
    type: 'Microsoft.Common.InfoBox',
    options: { style: 'Warning', text: costText },
  },
  {
    name: 'costAcknowledged',
    type: 'Microsoft.Common.CheckBox',
    label: 'I understand this deployment is billed every hour it runs, as estimated above, and that to stop billing I delete the model deployment first and then the resource group.',
    constraints: { required: true, validationMessage: 'Confirm to continue.' },
  },
];

// optionKey: the hardware dropdown of the selected model.
const optionKeyOutput = `[${choose(modelSel, models.map(([key]) => [key, optionSel(key)]), "''")}]`;

const form = {
  $schema: 'https://schema.management.azure.com/schemas/0.1.2-preview/CreateUIDefinition.MultiVm.json#',
  handler: 'Microsoft.Azure.CreateUIDef',
  version: '0.1.2-preview',
  parameters: {
    config: {
      basics: {
        description: `Deploy the **open weight models on public cloud** reference: an AI Gateway in front of one open weight model on Foundry managed compute, with Application Insights traces and a monthly budget. You get access automatically; callers sign in with Microsoft Entra ID. ${globalNotice}`,
        location: {
          label: 'Resource group region',
          toolTip: 'Region of the resource group itself. Resources use the Deployment region below.',
          resourceTypes: ['Microsoft.CognitiveServices/accounts'],
        },
      },
    },
    basics: [
      {
        name: 'region',
        type: 'Microsoft.Common.DropDown',
        label: 'Deployment region',
        toolTip: 'Foundry, AI Gateway and monitoring are in East US 2. Inference runs on Global managed compute.',
        defaultValue: 'East US 2',
        constraints: {
          allowedValues: [{ label: 'East US 2', value: 'eastus2' }],
          required: true,
        },
      },
      {
        name: 'namePrefix',
        type: 'Microsoft.Common.TextBox',
        label: 'Name prefix',
        defaultValue: 'sovai',
        toolTip: 'Short prefix for resource names. A unique suffix is added.',
        constraints: {
          required: true,
          regex: '^[a-z][a-z0-9]{2,7}$',
          validationMessage: 'Use 3 to 8 lowercase letters or digits, starting with a letter.',
        },
      },
    ],
    steps: [
      { name: 'model', label: 'Model', elements: modelElements },
      {
        name: 'access',
        label: 'Access',
        elements: [
          {
            name: 'accessInfo',
            type: 'Microsoft.Common.InfoBox',
            options: {
              style: 'Info',
              text: 'You (the account running this deployment) get the AI Gateway User role automatically, so you can call the model with an Entra token. Nobody gets a direct role on the model in Foundry: the gateway is the only way in. Optionally grant one more user, group or service principal. To find an object ID, run: az ad user show --id <email> --query id -o tsv',
            },
          },
          {
            name: 'principalId',
            type: 'Microsoft.Common.TextBox',
            label: 'Additional object ID (optional)',
            toolTip: 'Entra object ID of another user, group or service principal to grant the AI Gateway User role.',
            constraints: {
              required: false,
              regex: '^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
              validationMessage: 'Enter an object ID (GUID) or leave it empty.',
            },
          },
          {
            name: 'principalType',
            type: 'Microsoft.Common.OptionsGroup',
            label: 'Object type',
            defaultValue: 'User',
            visible: "[not(empty(steps('access').principalId))]",
            constraints: {
              allowedValues: [
                { label: 'User', value: 'User' },
                { label: 'Group', value: 'Group' },
                { label: 'Service principal', value: 'ServicePrincipal' },
              ],
            },
          },
        ],
      },
      {
        name: 'telemetry',
        label: 'Telemetry',
        elements: [
          {
            name: 'telemetryInfo',
            type: 'Microsoft.Common.InfoBox',
            options: {
              style: 'Info',
              text: 'Every call is traced to Application Insights. Payload capture is off by default, so prompt and completion text is not stored; token usage is still in Foundry metrics. Turning it on adds token usage and the serving model to traces, and stores request and response text.',
            },
          },
          {
            name: 'payloadCapture',
            type: 'Microsoft.Common.CheckBox',
            label: 'Capture request and response payloads in traces (adds token usage and model to traces; stores prompt and completion text)',
            defaultValue: false,
          },
          {
            name: 'reportStatus',
            type: 'Microsoft.Common.CheckBox',
            label: 'Report deployment status to the Sovereign AI site, so it can follow this deployment and open its next steps (sends tenant, subscription, resource group and deployment names, your Entra object ID and the next-steps links)',
            defaultValue: true,
          },
        ],
      },
    ],
    outputs: {
      location: "[basics('region')]",
      aiGatewayLocation: "[basics('region')]",
      namePrefix: "[basics('namePrefix')]",
      modelKey: `[${modelSel}]`,
      optionKey: optionKeyOutput,
      instances: "[steps('model').instances]",
      principalId: "[steps('access').principalId]",
      principalType: "[if(empty(steps('access').principalId), 'User', steps('access').principalType)]",
      payloadCapture: "[steps('telemetry').payloadCapture]",
      monthlyBudget: 0,
      reportUrl: `[if(steps('telemetry').reportStatus, '${reportUrl}', '')]`,
    },
  },
};

writeFileSync(`${dir}createUiDefinition.json`, `${JSON.stringify(form, null, 2)}\n`);
execFileSync('az', ['bicep', 'build', '-f', `${dir}main.bicep`, '--outfile', `${dir}azuredeploy.json`], { stdio: 'inherit' });
