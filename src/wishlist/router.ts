import { Response, Router } from 'express';
import { pool } from '../db';
import { AuthedRequest, requireAuth } from '../auth/tokens';

export const wishlistRouter = Router();
wishlistRouter.use(requireAuth);

async function loadWishlist(userId: number) {
  const { rows } = await pool.query(
    `SELECT p.id AS product_id, p.name, p.price_cents, p.stock > 0 AS in_stock, w.added_at
       FROM wishlist_items w JOIN products p ON p.id = w.product_id
      WHERE w.user_id = $1 AND p.active = true
      ORDER BY w.added_at DESC, p.id`,
    [userId],
  );
  return { items: rows, count: rows.length };
}

wishlistRouter.get('/', async (req: AuthedRequest, res: Response) => {
  res.json(await loadWishlist(req.user!.id));
});

/** Saves a product. Saving it again changes nothing. */
wishlistRouter.post('/items', async (req: AuthedRequest, res: Response) => {
  const { product_id } = req.body ?? {};
  if (!Number.isInteger(product_id) || product_id <= 0) {
    res.status(400).json({ error: 'product_id must be a positive integer' });
    return;
  }
  const product = await pool.query('SELECT 1 FROM products WHERE id = $1 AND active = true', [product_id]);
  if (product.rows.length === 0) {
    res.status(404).json({ error: 'product not found' });
    return;
  }
  await pool.query(
    'INSERT INTO wishlist_items (user_id, product_id) VALUES ($1, $2) ON CONFLICT (user_id, product_id) DO NOTHING',
    [req.user!.id, product_id],
  );
  res.status(201).json(await loadWishlist(req.user!.id));
});

wishlistRouter.delete('/items/:productId', async (req: AuthedRequest, res: Response) => {
  const productId = Number(req.params.productId);
  const { rowCount } = await pool.query('DELETE FROM wishlist_items WHERE user_id = $1 AND product_id = $2', [req.user!.id, productId]);
  if (!rowCount) {
    res.status(404).json({ error: 'product is not on the wishlist' });
    return;
  }
  res.json(await loadWishlist(req.user!.id));
});
