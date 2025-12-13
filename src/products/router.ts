import { Request, Response, Router } from 'express';
import { pool } from '../db';

export const productsRouter = Router();


interface ProductRow {
  id: number;
  sku: string;
  name: string;
  description: string;
  category: string;
  price_cents: number;
  stock: number;
  active: boolean;
  created_at: Date;
  updated_at: Date;
}

function toProduct(row: ProductRow) {
  return {
    id: row.id,
    sku: row.sku,
    name: row.name,
    description: row.description,
    category: row.category,
    price_cents: row.price_cents,
    stock: row.stock,
    in_stock: row.stock > 0,
  };
}

/** Catalog search. Only active products are listed. */
productsRouter.get('/', async (req: Request, res: Response) => {
  const where: string[] = ['active = true'];
  const params: unknown[] = [];

  const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  if (q) {
    params.push(`%${q}%`);
    where.push(`name LIKE $${params.length}`);
  }
  const { rows } = await pool.query<ProductRow>(
    `SELECT * FROM products WHERE ${where.join(' AND ')} ORDER BY name, id LIMIT 50`,
    params,
  );
  res.json({ items: rows.map(toProduct) });
});

productsRouter.get('/:id', async (req: Request, res: Response) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    res.status(400).json({ error: 'id must be a positive integer' });
    return;
  }
  const { rows } = await pool.query<ProductRow>('SELECT * FROM products WHERE id = $1 AND active = true', [id]);
  if (rows.length === 0) {
    res.status(404).json({ error: 'product not found' });
    return;
  }
  res.json(toProduct(rows[0]));
});
