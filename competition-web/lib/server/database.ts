import "server-only";
import { Pool, type PoolClient } from "pg";
import { verifiedCurrentUser } from "./auth";

let pool: Pool | undefined;
function databasePool(): Pool {
  if (!pool) {
    const connectionString = process.env.SUPABASE_DB_URL;
    if (!connectionString)
      throw new Error("Server database configuration is missing.");
    pool = new Pool({
      connectionString,
      max: 5,
      idleTimeoutMillis: 15_000,
      connectionTimeoutMillis: 5_000,
      application_name: "ost-competition-web",
    });
    pool.on("error", () => {
      /* Deliberately omit query, connection, and user data from logs. */
    });
  }
  return pool;
}

export class SignInRequired extends Error {}
export class SafeDatabaseError extends Error {}
export class StaleRatingError extends Error {}

/**
 * Verify the Supabase session with Auth first, then execute private-schema
 * functions under a non-owner DB role with the verified subject attached.
 * The browser never receives the database connection string or service key.
 */
export async function withCurrentUser<T>(
  operation: (
    db: PoolClient,
    userId: string,
    accessToken: string,
  ) => Promise<T>,
): Promise<T> {
  const identity = await verifiedCurrentUser();
  if (!identity) throw new SignInRequired();
  return withAppRole(
    (db) => operation(db, identity.user.id, identity.accessToken),
    identity.user.id,
  );
}

export async function withAppRole<T>(
  operation: (db: PoolClient) => Promise<T>,
  userId?: string,
): Promise<T> {
  const client = await databasePool().connect();
  try {
    await client.query("begin");
    await client.query("set local role ost_web_app");
    const claims = JSON.stringify(
      userId ? { sub: userId, role: "authenticated" } : { role: "anon" },
    );
    await client.query(
      "select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claim.role',$2,true),set_config('request.jwt.claims',$3,true)",
      [userId ?? "", userId ? "authenticated" : "anon", claims],
    );
    const result = await operation(client);
    await client.query("commit");
    return result;
  } catch (error) {
    await client.query("rollback").catch(() => undefined);
    if (
      error instanceof HostAccessDenied ||
      error instanceof SafeDatabaseError ||
      error instanceof StaleRatingError
    )
      throw error;
    const code =
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      typeof error.code === "string"
        ? error.code
        : "unknown";
    console.error(JSON.stringify({ event: "database_operation_failed", code }));
    throw new Error("The request could not be completed.");
  } finally {
    client.release();
  }
}

export async function withHost<T>(
  operation: (db: PoolClient, userId: string) => Promise<T>,
): Promise<T> {
  return withCurrentUser(async (db, userId) => {
    const { rows } = await db.query<{ authorized: boolean }>(
      "select private.is_platform_host() as authorized",
    );
    if (rows[0]?.authorized !== true) throw new HostAccessDenied();
    return operation(db, userId);
  });
}

export class HostAccessDenied extends Error {}
