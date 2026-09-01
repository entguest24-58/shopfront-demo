import { Request, Response, Router } from 'express';
import { pool } from '../db';
import { AuthedRequest, requireAuth } from '../auth/tokens';

export const reviewsRouter = Router({ mergeParams: true });

function productId(req: Request): number | null {
  const id = Number(req.params.productId);
  return Number.isInteger(id) && id > 0 ? id : null;
}

reviewsRouter.get('/', async (req: Request, res: Response) => {
  const id = productId(req);
  if (!id) {
    res.status(400).json({ error: 'product id must be a positive integer' });
    return;
  }
  const { rows } = await pool.query(
    `SELECT r.id, r.rating, r.comment, r.created_at, u.name AS author
       FROM reviews r JOIN users u ON u.id = r.user_id
      WHERE r.product_id = $1
      ORDER BY r.created_at DESC, r.id DESC`,
    [id],
  );
  const average = rows.length ? Math.round((rows.reduce((sum, r) => sum + r.rating, 0) / rows.length) * 10) / 10 : null;
  res.json({ items: rows, count: rows.length, average_rating: average });
});

/** One review per customer per product, and only for products the customer has bought. */
reviewsRouter.post('/', requireAuth, async (req: AuthedRequest, res: Response) => {
  const id = productId(req);
  if (!id) {
    res.status(400).json({ error: 'product id must be a positive integer' });
    return;
  }
  const { rating, comment = '' } = req.body ?? {};
  if (!Number.isInteger(rating)) {
    res.status(400).json({ error: 'rating must be a whole number' });
    return;
  }
  const bought = await pool.query(
    `SELECT 1 FROM order_items oi JOIN orders o ON o.id = oi.order_id
      WHERE o.user_id = $1 AND oi.product_id = $2 LIMIT 1`,
    [req.user!.id, id],
  );
  if (bought.rows.length === 0) {
    res.status(403).json({ error: 'only customers who bought this product can review it' });
    return;
  }
  try {
    const { rows } = await pool.query(
      'INSERT INTO reviews (product_id, user_id, rating, comment) VALUES ($1, $2, $3, $4) RETURNING id, rating, comment, created_at',
      [id, req.user!.id, rating, String(comment)],
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    if ((err as { code?: string }).code === '23505') {
      res.status(409).json({ error: 'you have already reviewed this product' });
      return;
    }
    throw err;
  }
});
