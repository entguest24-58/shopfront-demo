import { Response, Router } from 'express';
import { pool } from '../db';
import { AuthedRequest, requireAuth } from '../auth/tokens';

export const ordersRouter = Router();
ordersRouter.use(requireAuth);

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
