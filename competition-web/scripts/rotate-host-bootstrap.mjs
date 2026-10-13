import { randomBytes, createHash } from "node:crypto";
import { Pool } from "pg";

const databaseUrl = process.env.HOST_BOOTSTRAP_DB_URL;
const siteUrl = process.env.NEXT_PUBLIC_SITE_URL;
if (!databaseUrl || !siteUrl) throw new Error("Set HOST_BOOTSTRAP_DB_URL and NEXT_PUBLIC_SITE_URL.");
const token = randomBytes(32).toString("base64url");
const digest = createHash("sha256").update(token).digest();
const pool = new Pool({ connectionString: databaseUrl, max: 1 });
try {
  const db = await pool.connect();
  try {
    await db.query("begin");
    const host = await db.query(
      "select host_user_id from private.platform_config where singleton for update",
    );
    if (!host.rows[0]) throw new Error("The platform host is not configured.");
    await db.query("delete from private.host_bootstrap_tokens where redeemed_at is null");
    await db.query(
      "insert into private.host_bootstrap_tokens(token_digest,user_id,expires_at) values($1,$2,now()+interval '10 minutes')",
      [digest, host.rows[0].host_user_id],
    );
    await db.query(
      "insert into private.host_audit_log(actor_user_id,event_type) values($1,'host_bootstrap_token_rotated')",
      [host.rows[0].host_user_id],
    );
    await db.query("commit");
  } catch (error) {
    await db.query("rollback").catch(() => undefined);
    throw error;
  } finally {
    db.release();
  }
} finally {
  await pool.end();
}
console.log(`One-time host recovery link (expires in 10 minutes): ${new URL(`/host/bootstrap#${token}`, siteUrl)}`);
