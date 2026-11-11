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

function goodsTotal(lines: PricedLine[]): number {
  return lines.reduce((sum, l) => sum + l.price_cents * l.quantity, 0);
}

function percentOf(amount: number, percent: number): number {
  return Math.round((amount * percent) / 100);
}

function shippingFor(amount: number): number {
  return amount >= FREE_SHIPPING_MIN_CENTS ? 0 : SHIPPING_CENTS;
}

/** Order totals in integer cents. */
export function computeTotals(lines: PricedLine[], percentOff = 0): Totals {
  const subtotal = goodsTotal(lines);
  const tax = percentOf(subtotal, TAX_RATE * 100);
  const discount = percentOf(subtotal, percentOff);
  const shipping = shippingFor(subtotal - discount);
  return {
    subtotal_cents: subtotal,
    discount_cents: discount,
    shipping_cents: shipping,
    tax_cents: tax,
    total_cents: subtotal - discount + shipping + tax,
  };
}
