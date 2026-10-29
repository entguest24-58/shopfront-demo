import { Response, Router } from 'express';
import { pool } from '../db';
import { AuthedRequest, requireAdmin, requireAuth } from '../auth/tokens';

export const adminRouter = Router();
adminRouter.use(requireAuth, requireAdmin);

const DEFAULT_LOW_STOCK = 5;

/** Products at or below the threshold, lowest stock first. */
adminRouter.get('/inventory/low-stock', async (req: AuthedRequest, res: Response) => {
  const raw = Number(req.query.threshold ?? DEFAULT_LOW_STOCK);
  const threshold = Number.isInteger(raw) && raw >= 0 ? raw : DEFAULT_LOW_STOCK;
  const { rows } = await pool.query(
    'SELECT id, sku, name, stock FROM products WHERE active = true AND stock <= $1 ORDER BY stock, name',
    [threshold],
  );
  res.json({ threshold, items: rows });
});
