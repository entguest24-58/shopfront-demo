import { Response, Router } from 'express';
import { pool } from '../db';
import { AuthedRequest, requireAuth } from '../auth/tokens';

export const cartRouter = Router();
cartRouter.use(requireAuth);

interface CartLineRow {
  product_id: number;
  name: string;
  price_cents: number;
  quantity: number;
}

export async function loadCart(userId: number) {
  const { rows } = await pool.query<CartLineRow>(
    `SELECT c.product_id, p.name, p.price_cents, c.quantity
       FROM cart_items c JOIN products p ON p.id = c.product_id
      WHERE c.user_id = $1
      ORDER BY c.added_at, c.product_id`,
    [userId],
  );
  const items = rows.map((r) => ({
    product_id: r.product_id,
    name: r.name,
    unit_price_cents: r.price_cents,
    quantity: r.quantity,
    line_total_cents: r.price_cents * r.quantity,
  }));
  const subtotal = items.reduce((sum, i) => sum + i.line_total_cents, 0);
  return { items, item_count: items.reduce((n, i) => n + i.quantity, 0), subtotal_cents: subtotal };
}

cartRouter.get('/', async (req: AuthedRequest, res: Response) => {
  res.json(await loadCart(req.user!.id));
});

/** Adds a product to the signed-in customer's cart (merging with an existing line). */
cartRouter.post('/items', async (req: AuthedRequest, res: Response) => {
  const { product_id, quantity = 1 } = req.body ?? {};
  if (!Number.isInteger(product_id) || product_id <= 0) {
    res.status(400).json({ error: 'product_id must be a positive integer' });
    return;
  }
  if (!Number.isInteger(quantity) || quantity < 1) {
    res.status(400).json({ error: 'quantity must be a positive integer' });
    return;
  }

  const { rows } = await pool.query<{ id: number; stock: number }>(
    'SELECT id, stock FROM products WHERE id = $1 AND active = true',
    [product_id],
  );
  const product = rows[0];
  if (!product) {
    res.status(404).json({ error: 'product not found' });
    return;
  }
  if (quantity > product.stock) {
    res.status(409).json({ error: 'not enough stock', available: product.stock });
    return;
  }

  await pool.query(
    `INSERT INTO cart_items (user_id, product_id, quantity)
     VALUES ($1, $2, $3)
     ON CONFLICT (user_id, product_id) DO UPDATE SET quantity = cart_items.quantity + EXCLUDED.quantity`,
    [req.user!.id, product_id, quantity],
  );
  res.status(201).json(await loadCart(req.user!.id));
});

cartRouter.delete('/items/:productId', async (req: AuthedRequest, res: Response) => {
  const productId = Number(req.params.productId);
  const { rowCount } = await pool.query('DELETE FROM cart_items WHERE user_id = $1 AND product_id = $2', [req.user!.id, productId]);
  if (!rowCount) {
    res.status(404).json({ error: 'item not in cart' });
    return;
  }
  res.json(await loadCart(req.user!.id));
});
