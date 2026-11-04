// Checks catalog.json: pinned versions, sovereignty fields, prices and the monthly estimate.
// Run: node --test 'open-weight-models-public-cloud/azure/test/*.test.mjs'
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { monthlyUsd } from '../scripts/cost.mjs';

const catalog = JSON.parse(readFileSync(new URL('../catalog.json', import.meta.url), 'utf8'));
const models = Object.entries(catalog.models);

test('every model has the four sovereignty fields', () => {
  for (const [key, m] of models) {
    assert.ok(m.license, `${key} license`);
    assert.match(m.licenseUrl, /^https:\/\//, `${key} licenseUrl`);
    assert.ok(m.huggingFace, `${key} huggingFace`);
    assert.match(m.model, /\/versions\/\d+$/, `${key} model`);
  }
});

test('every option is pinned and priced', () => {
  for (const [key, m] of models) {
    for (const [optionKey, o] of Object.entries(m.options)) {
      const name = `${key}/${optionKey}`;
      // Managed compute accepts only labels/latest templates; the tested version is recorded.
      assert.match(o.template, /\/deploymenttemplates\/[^/]+\/labels\/latest$/, `${name} template`);
      assert.ok(Number.isInteger(o.templateVersion) && o.templateVersion > 0, `${name} templateVersion`);
      assert.ok(Object.hasOwn(catalog.rateCentsPerAcceleratorHour, o.accelerator), `${name} accelerator`);
      assert.ok(o.count === 1 || o.count === 2, `${name} count`);
      assert.ok(o.context > 0, `${name} context`);
    }
  }
});

test('defaultOption exists and is the cheapest', () => {
  const cents = o => catalog.rateCentsPerAcceleratorHour[o.accelerator] * o.count;
  for (const [key, m] of models) {
    const d = m.options[m.defaultOption];
    assert.ok(d, `${key} defaultOption`);
    assert.equal(cents(d), Math.min(...Object.values(m.options).map(cents)), `${key} defaultOption cheapest`);
  }
});

test('exactly the four approved models', () => {
  assert.deepEqual(Object.keys(catalog.models).sort(), ['gemma-4-31b', 'gpt-oss-20b', 'muse-glimmer-30b', 'nemotron-35-lightning-30b']);
});

test('monthly estimate', () => {
  assert.equal(monthlyUsd(catalog, 'gpt-oss-20b', 'a100', 1), 2884);
  assert.equal(monthlyUsd(catalog, 'gemma-4-31b', '2xh100', 1), 11549);
  assert.equal(monthlyUsd(catalog, 'gpt-oss-20b', 'a100', 3), 8651);
});
