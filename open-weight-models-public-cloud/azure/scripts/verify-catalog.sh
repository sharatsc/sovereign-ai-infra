#!/usr/bin/env bash
# Checks catalog.json against the azure-huggingface registry: every pinned model version and
# deployment template version resolves, each template's accelerator type and count match the
# catalog, and each template is one the model allows. Prints OK or MISMATCH per option and
# exits non-zero on any mismatch. Needs az CLI with the ml extension, signed in.
set -uo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
catalog="$here/catalog.json"
registry_api='https://eastus.api.azureml.ms/genericasset/v2.0/subscriptions/d4d34678-c0d7-4d69-a257-366e3cb4a7d8/resourceGroups/registry-builtin-azure-huggingface-eastus/providers/Microsoft.MachineLearningServices/registries/azure-huggingface/deploymenttemplates'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# One line per option: modelKey optionKey modelName modelVersion templateName templateVersion accelerator count
node -e '
const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const part = id => id.match(/\/([^/]+)\/versions\/(\d+)$/).slice(1).join(" ");
for (const [k, m] of Object.entries(c.models))
  for (const [o, v] of Object.entries(m.options))
    console.log([k, o, part(m.model), part(v.template), v.accelerator, v.count].join(" "));
' "$catalog" > "$tmp/options"

failed=0
while read -r key option model model_version template template_version accelerator count; do
  model_json="$tmp/model-$model-$model_version.json"
  if [ ! -s "$model_json" ]; then
    # The ml extension prints an experimental-class notice on stdout before the JSON.
    az ml model show --registry-name azure-huggingface -n "$model" -v "$model_version" -o json 2>/dev/null \
      | sed -n '/^{/,$p' > "$model_json"
  fi
  template_json="$tmp/template-$template-$template_version.json"
  az rest --resource https://ml.azure.com --method get \
    --url "$registry_api/$template/versions/$template_version?api-version=2026-05-01-preview" \
    -o json > "$template_json" 2>/dev/null

  problem=$(node -e '
const fs = require("fs");
const [modelFile, templateFile, template, accelerator, count] = process.argv.slice(1);
const read = f => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch { return null; } };
const m = read(modelFile), t = read(templateFile), out = [];
if (!m) out.push("model version not found");
if (!t) out.push("template version not found");
if (t) {
  const a = (t.acceleratorMaps || [])[0] || {};
  if (a.acceleratorType !== accelerator || String(a.numberOfAcceleratorsPerModelInstance) !== count)
    out.push(`template has ${a.acceleratorType} x ${a.numberOfAcceleratorsPerModelInstance}, catalog has ${accelerator} x ${count}`);
}
if (m) {
  const allowed = (m.allowed_deployment_templates || []).map(x => x.asset_id.split("/deploymenttemplates/")[1].split("/")[0]);
  if (!allowed.includes(template)) out.push("template not in the model allowed list");
}
console.log(out.join("; "));
' "$model_json" "$template_json" "$template" "$accelerator" "$count")

  if [ -z "$problem" ]; then
    echo "OK $key/$option"
  else
    echo "MISMATCH $key/$option: $problem"
    failed=1
  fi
done < "$tmp/options"

exit $failed
