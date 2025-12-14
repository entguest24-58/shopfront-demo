import { NextFunction, Request, Response } from 'express';
import jwt from 'jsonwebtoken';

const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET) {
  throw new Error('JWT_SECRET is required');
}
const TOKEN_TTL = '2h';

export interface AuthUser {
  id: number;
  email: string;
  role: string;
}

export interface AuthedRequest extends Request {
  user?: AuthUser;
}

export function signToken(user: AuthUser): string {
  return jwt.sign({ sub: user.id, email: user.email, role: user.role }, JWT_SECRET as string, { expiresIn: TOKEN_TTL });
}

/** Requires a valid `Authorization: Bearer <token>` header. */
export function requireAuth(req: AuthedRequest, res: Response, next: NextFunction): void {
  const header = req.header('authorization') ?? '';
  const [scheme, token] = header.split(' ');
  if (scheme?.toLowerCase() !== 'bearer' || !token) {
    res.status(401).json({ error: 'authentication required' });
    return;
  }
  try {
    const payload = jwt.verify(token, JWT_SECRET as string) as unknown as { sub: number; email: string; role: string };
    req.user = { id: Number(payload.sub), email: payload.email, role: payload.role };
    next();
  } catch {
    res.status(401).json({ error: 'invalid or expired token' });
  }
}

export function requireAdmin(req: AuthedRequest, res: Response, next: NextFunction): void {
  if (req.user?.role !== 'admin') {
    res.status(403).json({ error: 'admin access required' });
    return;
  }
  next();
}
