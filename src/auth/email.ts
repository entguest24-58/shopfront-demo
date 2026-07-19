/** One place for how an email address is stored and looked up. */
export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}
