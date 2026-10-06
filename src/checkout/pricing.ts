export const TAX_RATE = 0.08;
export const FREE_SHIPPING_MIN_CENTS = 5000;
export const SHIPPING_CENTS = 599;

export interface PricedLine {
  price_cents: number;
  quantity: number;
}

export interface Totals {
  subtotal_cents: number;
  discount_cents: number;
  shipping_cents: number;
  tax_cents: number;
  total_cents: number;
}

/** Order totals in integer cents. */
export function computeTotals(lines: PricedLine[], percentOff = 0): Totals {
  let subtotal = 0;
  for (const l of lines) {
    subtotal += l.price_cents * l.quantity;
  }
  const discount = Math.round((subtotal * percentOff) / 100);
  const shipping = subtotal - discount >= FREE_SHIPPING_MIN_CENTS ? 0 : SHIPPING_CENTS;
  const tax = Math.round((subtotal - discount) * TAX_RATE);
  return {
    subtotal_cents: subtotal,
    discount_cents: discount,
    shipping_cents: shipping,
    tax_cents: tax,
    total_cents: subtotal - discount + shipping + tax,
  };
}
