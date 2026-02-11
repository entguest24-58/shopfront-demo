export interface Coupon {
  code: string;
  percentOff: number;
  minSubtotalCents: number;
}

const COUPONS: Coupon[] = [
  { code: 'SAVE10', percentOff: 10, minSubtotalCents: 5000 },
  { code: 'WELCOME15', percentOff: 15, minSubtotalCents: 10000 },
];

export function normalizeCode(raw: unknown): string | null {
  return typeof raw === 'string' && raw.trim() ? raw.trim().toUpperCase() : null;
}

export function findCoupon(code: string): Coupon | undefined {
  return COUPONS.find((c) => c.code === code);
}
