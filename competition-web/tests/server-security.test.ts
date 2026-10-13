import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root=resolve(import.meta.dirname,'..');
const auth=readFileSync(resolve(root,'lib/server/auth.ts'),'utf8');
const database=readFileSync(resolve(root,'lib/server/database.ts'),'utf8');
const storage=readFileSync(resolve(root,'lib/server/storage.ts'),'utf8');
const http=readFileSync(resolve(root,'lib/server/http.ts'),'utf8');

describe('server-only access boundary',()=>{
  it('verifies sessions through Supabase Auth and sets secure, HTTP-only cookies',()=>{
    expect(auth).toContain('supabase.auth.getUser()');
    expect(auth).toContain('httpOnly:true');
    expect(auth).toContain("sameSite:'lax'");
    expect(auth).toContain("secure:process.env.NODE_ENV==='production'");
  });
  it('executes database work under a non-owner role and verified identity',()=>{
    expect(database).toContain('verifiedCurrentUser()');
    expect(database).toContain('set local role ost_web_app');
    expect(database).toContain("set_config('request.jwt.claim.sub'");
    expect(database).toContain('private.is_platform_host()');
    expect(database).not.toContain('SUPABASE_SERVICE_ROLE_KEY');
  });
  it('routes all private media through a server-only storage abstraction',()=>{
    expect(storage).toContain('interface PrivateObjectStore');
    expect(storage).toContain('SUPABASE_SERVICE_ROLE_KEY');
    expect(storage).toContain('createSignedUrl');
    expect(storage).toContain('assertOpaqueStorageKey');
  });
  it('requires same-origin mutations and gives no-store generic private responses',()=>{
    expect(http).toContain("request.headers.get('origin')");
    expect(http).toContain("'Cache-Control':'private, no-store, max-age=0'");
    expect(http).toContain("{error:'This item is not available.'}");
    expect(http).not.toMatch(/stack|sqlstate|postgres/i);
  });
});
