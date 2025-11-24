import { readFileSync } from 'fs';
import { join } from 'path';
import { Pool, PoolClient } from 'pg';

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  throw new Error('DATABASE_URL is required (e.g. postgresql://app:app@localhost:5432/shopfront)');
}

export const pool = new Pool({ connectionString });

/** Applies db/schema.sql (idempotent). Called once at startup. */
export async function migrate(): Promise<void> {
  const schemaPath = join(__dirname, '..', 'db', 'schema.sql');
  const sql = readFileSync(schemaPath, 'utf8');
  await pool.query(sql);
}
