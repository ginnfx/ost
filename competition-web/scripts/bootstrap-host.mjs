import { randomBytes, createHash } from "node:crypto";
import { Pool } from "pg";
import { createClient } from "@supabase/supabase-js";

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
};

const supabaseUrl = required("SUPABASE_URL");
const serviceKey = required("SUPABASE_SERVICE_ROLE_KEY");
const databaseUrl = required("HOST_BOOTSTRAP_DB_URL");
const siteUrl = required("NEXT_PUBLIC_SITE_URL");
const supabase = createClient(supabaseUrl, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
const email = `host-${randomBytes(18).toString("hex")}@host.invalid`;
const { data, error } = await supabase.auth.admin.createUser({
  email,
  email_confirm: true,
  app_metadata: {},
});
if (error || !data.user) throw new Error("Could not create the host identity.");

const token = randomBytes(32).toString("base64url");
const digest = createHash("sha256").update(token).digest();
const pool = new Pool({ connectionString: databaseUrl, max: 1 });
try {
  const db = await pool.connect();
  try {
    await db.query("begin");
    const existing = await db.query("select 1 from private.platform_config");
    if (existing.rowCount) throw new Error("A platform host is already configured.");
    await db.query("insert into private.platform_config(singleton,host_user_id) values(true,$1)", [data.user.id]);
    await db.query(
      "insert into private.host_bootstrap_tokens(token_digest,user_id,expires_at) values($1,$2,now()+interval '10 minutes')",
      [digest, data.user.id],
    );
    await db.query("commit");
  } catch (cause) {
    await db.query("rollback").catch(() => undefined);
    throw cause;
  } finally {
    db.release();
  }
} catch (cause) {
  await supabase.auth.admin.deleteUser(data.user.id).catch(() => undefined);
  throw cause;
} finally {
  await pool.end();
}

console.log(`Host setup link (valid for 10 minutes; use once): ${new URL(`/host/bootstrap#${token}`, siteUrl)}`);
console.log("Host privileges were configured through the direct database connection. Do not share or save this link.");
