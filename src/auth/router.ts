import bcrypt from 'bcryptjs';
import { Request, Response, Router } from 'express';
import { pool } from '../db';
import { normalizeEmail } from './email';
import { AuthedRequest, requireAuth, signToken } from './tokens';

export const authRouter = Router();

const BCRYPT_ROUNDS = 10;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MIN_PASSWORD_LENGTH = 8;

interface UserRow {
  id: number;
  email: string;
  name: string;
  role: string;
  password_hash: string;
  created_at: Date;
}

function publicUser(row: UserRow) {
  return { id: row.id, email: row.email, name: row.name, role: row.role, created_at: row.created_at };
}

authRouter.post('/register', async (req: Request, res: Response) => {
  const { email, password, name, role = 'customer' } = req.body ?? {};

  if (typeof email !== 'string' || !EMAIL_RE.test(email.trim())) {
    res.status(400).json({ error: 'a valid email is required' });
    return;
  }
  if (typeof password !== 'string' || password.length < MIN_PASSWORD_LENGTH) {
    res.status(400).json({ error: `password must be at least ${MIN_PASSWORD_LENGTH} characters` });
    return;
  }
  if (typeof name !== 'string' || name.trim().length === 0) {
    res.status(400).json({ error: 'name is required' });
    return;
  }

  const storedEmail = normalizeEmail(email);
  const passwordHash = await bcrypt.hash(password, BCRYPT_ROUNDS);
  try {
    const { rows } = await pool.query<UserRow>(
      `INSERT INTO users (email, name, password_hash, role)
       VALUES ($1, $2, $3, $4)
       RETURNING *`,
      [storedEmail, name.trim(), passwordHash, role],
    );
    res.status(201).json(publicUser(rows[0]));
  } catch (err) {
    if ((err as { code?: string }).code === '23505') {
      res.status(409).json({ error: 'an account with this email already exists' });
      return;
    }
    throw err;
  }
});

authRouter.get('/password-policy', (_req: Request, res: Response) => {
  res.json({ min_length: MIN_PASSWORD_LENGTH });
});

authRouter.post('/login', async (req: Request, res: Response) => {
  const { email, password } = req.body ?? {};
  if (typeof email !== 'string' || typeof password !== 'string') {
    res.status(400).json({ error: 'email and password are required' });
    return;
  }

  const { rows } = await pool.query<UserRow>('SELECT * FROM users WHERE email = $1', [normalizeEmail(email)]);
  const user = rows[0];
  const ok = user ? await bcrypt.compare(password, user.password_hash) : false;
  if (!user || !ok) {
    res.status(401).json({ error: 'invalid email or password' });
    return;
  }

  const token = signToken({ id: user.id, email: user.email, role: user.role });
  res.json({ token, token_type: 'Bearer', expires_in: 7200, user: publicUser(user) });
});

authRouter.get('/me', requireAuth, async (req: AuthedRequest, res: Response) => {
  const { rows } = await pool.query<UserRow>('SELECT * FROM users WHERE id = $1', [req.user!.id]);
  if (rows.length === 0) {
    res.status(404).json({ error: 'account not found' });
    return;
  }
  res.json(publicUser(rows[0]));
});

const PROFILE_READ_ONLY = ['id', 'password_hash', 'created_at'];

/** A signed-in customer updates their own profile. */
authRouter.patch('/me', requireAuth, async (req: AuthedRequest, res: Response) => {
  const changes = Object.entries(req.body ?? {}).filter(([field]) => !PROFILE_READ_ONLY.includes(field));
  if (changes.length === 0) {
    res.status(400).json({ error: 'nothing to update' });
    return;
  }
  if (changes.some(([field, value]) => !/^[a-z_]+$/.test(field) || typeof value !== 'string' || !value.trim())) {
    res.status(400).json({ error: 'profile fields must be non-empty text' });
    return;
  }
  const assignments = changes.map(([field], i) => `${field} = $${i + 2}`).join(', ');
  try {
    const { rows } = await pool.query<UserRow>(
      `UPDATE users SET ${assignments} WHERE id = $1 RETURNING *`,
      [req.user!.id, ...changes.map(([, value]) => (value as string).trim())],
    );
    res.json(publicUser(rows[0]));
  } catch (err) {
    if ((err as { code?: string }).code === '42703') {
      res.status(400).json({ error: 'unknown profile field' });
      return;
    }
    throw err;
  }
});
