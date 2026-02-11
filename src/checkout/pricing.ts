export const TAX_RATE = 0.08;

export interface PricedLine {
  price_cents: number;
  quantity: number;
}

export interface Totals {
  subtotal_cents: number;
  discount_cents: number;
  tax_cents: number;
  total_cents: number;
}

/** Order totals in integer cents. */
export function computeTotals(lines: PricedLine[], percentOff = 0): Totals {
  const subtotal = lines.reduce((sum, l) => sum + l.price_cents * l.quantity, 0);
  const discount = Math.floor((subtotal * percentOff) / 100);
  const tax = Math.round((subtotal - discount) * TAX_RATE);
  return {
    subtotal_cents: subtotal,
    discount_cents: discount,
    tax_cents: tax,
    total_cents: subtotal - discount + tax,
  };
}
