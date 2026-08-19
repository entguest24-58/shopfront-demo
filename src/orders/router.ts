import { Response, Router } from 'express';
import { pool } from '../db';
import { AuthedRequest, requireAuth } from '../auth/tokens';

export const ordersRouter = Router();
ordersRouter.use(requireAuth);

/** The signed-in customer's orders, newest first. */
ordersRouter.get('/', async (req: AuthedRequest, res: Response) => {
  const { rows } = await pool.query(
    'SELECT id, status, total_cents, created_at FROM orders WHERE user_id = $1 ORDER BY created_at DESC, id DESC',
    [req.user!.id],
  );
  res.json({ items: rows });
});

ordersRouter.get('/:id', async (req: AuthedRequest, res: Response) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    res.status(400).json({ error: 'id must be a positive integer' });
    return;
  }
  const { rows } = await pool.query('SELECT * FROM orders WHERE id = $1', [id]);
  if (rows.length === 0) {
    res.status(404).json({ error: 'order not found' });
    return;
  }
  const items = await pool.query(
    'SELECT product_id, name, unit_price_cents, quantity, unit_price_cents * quantity AS line_total_cents FROM order_items WHERE order_id = $1 ORDER BY product_id',
    [id],
  );
  res.json({ ...rows[0], items: items.rows });
});

/** A customer can cancel their own order while it is still being prepared. */
ordersRouter.post('/:id/cancel', async (req: AuthedRequest, res: Response) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    res.status(400).json({ error: 'id must be a positive integer' });
    return;
  }
  const { rows } = await pool.query(
    "UPDATE orders SET status = 'cancelled', cancelled_at = now() WHERE id = $1 AND user_id = $2 RETURNING id, status, cancelled_at",
    [id, req.user!.id],
  );
  if (rows.length === 0) {
    res.status(404).json({ error: 'order not found' });
    return;
  }
  res.json(rows[0]);
});
