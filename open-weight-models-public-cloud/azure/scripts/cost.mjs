// Cost math for the catalog. Rates are in cents per accelerator-hour; a month is hoursPerMonth hours.

export function monthlyUsd(catalog, modelKey, optionKey, instances) {
  const o = catalog.models[modelKey].options[optionKey];
  const cents = catalog.rateCentsPerAcceleratorHour[o.accelerator];
  return Math.ceil(cents * o.count * instances * catalog.hoursPerMonth / 100);
}
