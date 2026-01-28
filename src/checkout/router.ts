import { Response, Router } from 'express';
import { withTransaction } from '../db';
import { AuthedRequest, requireAuth } from '../auth/tokens';
import { computeTotals } from './pricing';

export const checkoutRouter = Router();
checkoutRouter.use(requireAuth);

class CheckoutError extends Error {
  constructor(public status: number, message: string, public details?: Record<string, unknown>) {
    super(message);
  }
}

interface CartLine {
  product_id: number;
  name: string;
  price_cents: number;
  stock: number;
  quantity: number;
}

/** Checkout: turns the signed-in customer's cart into an order. */
checkoutRouter.post('/', async (req: AuthedRequest, res: Response) => {
  const userId = req.user!.id;

  try {
    const order = await withTransaction(async (client) => {
      const { rows: lines } = await client.query<CartLine>(
        `SELECT c.product_id, p.name, p.price_cents, p.stock, c.quantity
           FROM cart_items c JOIN products p ON p.id = c.product_id
          WHERE c.user_id = $1
          ORDER BY c.product_id`,
        [userId],
      );
      if (lines.length === 0) {
        throw new CheckoutError(400, 'cart is empty');
      }
      const short = lines.filter((l) => l.quantity > l.stock);
      if (short.length > 0) {
        throw new CheckoutError(409, 'not enough stock', {
          items: short.map((l) => ({ product_id: l.product_id, requested: l.quantity, available: l.stock })),
        });
      }

      const totals = computeTotals(lines);

      const { rows } = await client.query<{ id: number; created_at: Date }>(
        `INSERT INTO orders (user_id, subtotal_cents, tax_cents, total_cents)
         VALUES ($1, $2, $3, $4) RETURNING id, created_at`,
        [userId, totals.subtotal_cents, totals.tax_cents, totals.total_cents],
      );
      const orderId = rows[0].id;
      for (const l of lines) {
        await client.query(
          'INSERT INTO order_items (order_id, product_id, name, unit_price_cents, quantity) VALUES ($1, $2, $3, $4, $5)',
          [orderId, l.product_id, l.name, l.price_cents, l.quantity],
        );
        await client.query('UPDATE products SET stock = stock - $2, updated_at = now() WHERE id = $1', [l.product_id, l.quantity]);
      }
      await client.query('DELETE FROM cart_items WHERE user_id = $1', [userId]);

      return {
        id: orderId,
        status: 'placed',
        items: lines.map((l) => ({
          product_id: l.product_id,
          name: l.name,
          unit_price_cents: l.price_cents,
          quantity: l.quantity,
          line_total_cents: l.price_cents * l.quantity,
        })),
        ...totals,
        created_at: rows[0].created_at,
      };
    });
    res.status(201).json(order);
  } catch (err) {
    if (err instanceof CheckoutError) {
      res.status(err.status).json({ error: err.message, ...(err.details ?? {}) });
      return;
    }
    throw err;
  }
});
