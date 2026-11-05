// Checks the generated portal form against the template and the catalog.
// Run: node scripts/build.mjs && node --test 'test/*.test.mjs'
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { costTable, uiCost } from '../scripts/cost.mjs';

const read = f => JSON.parse(readFileSync(new URL(`../${f}`, import.meta.url), 'utf8'));
const catalog = read('catalog.json');
const template = read('azuredeploy.json');
const form = read('createUiDefinition.json').parameters;
const modelStep = form.steps.find(s => s.name === 'model');
const elements = modelStep.elements;
const optionName = key => `option_${key.replace(/[-.]/g, '_')}`;
const textOf = e => e.options?.text ?? e.text ?? '';
const costBox = () => {
  const boxes = elements.filter(e => ['Microsoft.Common.InfoBox', 'Microsoft.Common.TextBlock'].includes(e.type) && textOf(e).includes('per month'));
  assert.equal(boxes.length, 1, 'one cost box');
  return textOf(boxes[0]);
};

test('form outputs are template parameters', () => {
  const outputs = Object.keys(form.outputs);
  for (const key of outputs) assert.ok(Object.hasOwn(template.parameters, key), `${key} is a template parameter`);
  for (const key of ['modelKey', 'optionKey', 'instances', 'monthlyBudget']) assert.ok(outputs.includes(key), `${key} is a form output`);
});

test('one hardware dropdown per model', () => {
  const rates = catalog.rateCentsPerAcceleratorHour;
  for (const [key, m] of Object.entries(catalog.models)) {
    const visible = `[equals(steps('model').modelKey, '${key}')]`;
    const drops = elements.filter(e => e.type === 'Microsoft.Common.DropDown' && e.visible === visible);
    assert.equal(drops.length, 1, `${key} has one hardware dropdown`);
    const [drop] = drops;
    assert.equal(drop.name, optionName(key));
    const allowed = drop.constraints.allowedValues;
    assert.deepEqual(allowed.map(v => v.value), Object.keys(m.options), `${key} options in catalog order`);
    // A single-select DropDown's defaultValue is the label of the default item.
    assert.equal(allowed.find(v => v.label === drop.defaultValue)?.value, m.defaultOption, `${key} default`);
    for (const v of allowed) {
      const o = m.options[v.value];
      const cents = rates[o.accelerator] * o.count;
      const hourly = `${Math.floor(cents / 100)}.${String(cents % 100).padStart(2, '0')}`;
      assert.ok(v.label.includes(o.label), `${key}/${v.value} label has accelerator and context`);
      assert.ok(v.label.includes(`$${hourly}/hour per instance`), `${key}/${v.value} label has hourly cost`);
    }
  }
});

test('cost box', () => {
  const text = costBox();
  for (const s of [
    '730',
    'per month',
    'Global deployment: inference may run in any Azure region, including outside the United States, until Data Zone US is available.',
    'To switch models, delete the resource group or the old deployment first',
    'az rest --method get',
    'subscription().subscriptionId',
    '/providers/Microsoft.CognitiveServices/locations/eastus2/managedComputeUsages?api-version=2026-11-01',
  ]) assert.ok(text.includes(s), `cost box has ${s}`);
});

test('cost per instance', () => {
  const text = costBox();
  for (const row of costTable(catalog)) {
    const re = new RegExp(`equals\\(steps\\('model'\\)\\.${optionName(row.modelKey)}, '${row.optionKey}'\\), (\\d+)`, 'g');
    const found = [...text.matchAll(re)].map(x => Number(x[1]));
    assert.ok(found.length > 0, `${row.modelKey}/${row.optionKey} in cost expression`);
    for (const cents of found) assert.equal(cents, row.hourlyCents, `${row.modelKey}/${row.optionKey} cents`);
  }
  assert.ok(text.includes("steps('model').instances"), 'cost scales with instances');
  assert.deepEqual(uiCost(395, 3), { hourly: '11.85', monthly: 8651 });
  assert.deepEqual(uiCost(1582, 2), { hourly: '31.64', monthly: 23098 });
});

test('cost acknowledgement', () => {
  const required = elements.filter(e => e.type === 'Microsoft.Common.CheckBox' && e.constraints?.required === true);
  assert.equal(required.length, 1, 'one required acknowledgement');
  // Azure won't delete the group while the managed compute deployment exists, so the order matters.
  assert.equal(required[0].label, 'I understand this deployment is billed every hour it runs, as estimated above, and that to stop billing I delete the model deployment first and then the resource group.');
});

test('payload capture off and region fixed', () => {
  const capture = form.steps.flatMap(s => s.elements).find(e => e.name === 'payloadCapture');
  assert.equal(capture.type, 'Microsoft.Common.CheckBox');
  assert.equal(capture.defaultValue, false);
  const region = form.basics.find(e => e.name === 'region');
  assert.deepEqual(region.constraints.allowedValues.map(v => v.value), ['eastus2']);
});
