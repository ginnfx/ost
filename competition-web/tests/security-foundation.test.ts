import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root=resolve(import.meta.dirname,'..');
const migration=readFileSync(resolve(root,'supabase/migrations/20261013170000_competition_security_foundation.sql'),'utf8');
const config=readFileSync(resolve(root,'supabase/config.toml'),'utf8');

describe('security foundation invariants',()=>{
  it('keeps the private schema out of PostgREST and GraphQL schemas',()=>{
    expect(config).toMatch(/schemas\s*=\s*\["public"\]/);
    expect(config).not.toContain('graphql_public');
  });
  it('forces RLS and revokes direct data table grants',()=>{
    expect(migration).toContain('enable row level security');
    expect(migration).toContain('force row level security');
    expect(migration).toContain('revoke all on private.%I from public, anon, authenticated, ost_web_app');
  });
  it('keeps security-definer functions in private with an empty search_path',()=>{
    const functions=[...migration.matchAll(/create or replace function private\.([\w_]+)[\s\S]*?security definer[\s\S]*?set search_path=''/g)];
    expect(functions.map(match=>match[1])).toContain('is_platform_host');
    expect(functions.map(match=>match[1])).toContain('require_platform_host');
    expect(functions.length).toBeGreaterThanOrEqual(2);
  });
  it('keeps uploads in private storage with no participant object policy',()=>{
    expect(migration).toMatch(/values \('competition-media','competition-media',false/);
    expect(migration).not.toMatch(/create policy[\s\S]*storage\.objects/);
  });
  it('blocks audit mutation and scored snapshot updates',()=>{
    expect(migration).toMatch(/before update or delete on private\.host_audit_log/);
    expect(migration).toMatch(/before update on private\.score_snapshots/);
  });
});
