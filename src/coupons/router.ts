import { Request, Response, Router } from 'express';
import { findCoupon, normalizeCode } from './catalog';

export const couponsRouter = Router();

/** Lets the storefront show what a code gives before checkout. */
couponsRouter.get('/:code', (req: Request, res: Response) => {
  const code = normalizeCode(req.params.code);
  const coupon = code ? findCoupon(code) : undefined;
  if (!coupon) {
    res.status(404).json({ error: 'unknown coupon code' });
    return;
  }
  res.json({ code: coupon.code, percent_off: coupon.percentOff, min_subtotal_cents: coupon.minSubtotalCents });
});
