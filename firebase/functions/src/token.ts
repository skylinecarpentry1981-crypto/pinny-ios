/**
 * Push-token de-duplication decision for onUserTokenWritten.
 *
 * Kept pure (no firebase-admin initialisation) so it can be unit-tested:
 * test/token.test.mjs runs against the compiled lib/token.js.
 */

/** The slice of pushTokens/{uid} the decision needs (PushTokenDoc satisfies it). */
export interface TokenDoc {
  token?: string | null;
}

/**
 * True when the write set `token` to a new non-empty string (doc created,
 * or the token was replaced). Then any other account still holding that
 * token is stale — one phone, one account — and loses it.
 *
 * False for everything else, which is also the loop guard: the clean-up
 * deletes the other pushTokens docs (after = undefined), and a rewrite of
 * the same token (updatedAt only) or a delete (sign-out, dead-token
 * clean-up, account deletion) changes nothing.
 */
export function tokenChanged(
  before: TokenDoc | undefined,
  after: TokenDoc | undefined,
): boolean {
  const next = after?.token;
  if (typeof next !== "string" || next.length === 0) return false;
  return next !== before?.token;
}
