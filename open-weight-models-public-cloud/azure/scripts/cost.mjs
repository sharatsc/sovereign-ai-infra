// Cost math for the catalog. Rates are in cents per accelerator-hour; a month is hoursPerMonth hours.

export function monthlyUsd(catalog, modelKey, optionKey, instances) {
  const o = catalog.models[modelKey].options[optionKey];
  const cents = catalog.rateCentsPerAcceleratorHour[o.accelerator];
  return Math.ceil(cents * o.count * instances * catalog.hoursPerMonth / 100);
}

// One row per model and option, for one instance: hourly cents and the monthly estimate in USD.
export function costTable(catalog) {
  return Object.entries(catalog.models).flatMap(([modelKey, m]) =>
    Object.entries(m.options).map(([optionKey, o]) => ({
      modelKey,
      optionKey,
      hourlyCents: catalog.rateCentsPerAcceleratorHour[o.accelerator] * o.count,
      monthlyUsd: monthlyUsd(catalog, modelKey, optionKey, 1),
    })));
}

// Mirrors the portal form's integer math: hourly as dollars and cents, monthly rounded up.
export function uiCost(hourlyCents, instances, hoursPerMonth = 730) {
  const cents = hourlyCents * instances;
  return {
    hourly: `${Math.floor(cents / 100)}.${String(cents % 100).padStart(2, '0')}`,
    monthly: Math.floor((cents * hoursPerMonth + 99) / 100),
  };
}
