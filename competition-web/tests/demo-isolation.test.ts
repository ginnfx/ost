import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { createDemoState } from '../lib/demo/data';

const root=resolve(import.meta.dirname,'..');
function sources(path:string):string[]{return readdirSync(path,{withFileTypes:true}).flatMap(item=>item.isDirectory()?sources(join(path,item.name)):/\.(tsx?|jsx?)$/.test(item.name)?[join(path,item.name)]:[]);}

describe('demo isolation',()=>{
  it('ships ten fictional participants and 45 other submissions for the visitor to complete',()=>{
    const state=createDemoState();
    expect(state.participants).toHaveLength(10);
    expect(state.entries).toHaveLength(45);
    expect(state.entries.every(entry=>entry.submitterId!=='person-1')).toBe(true);
  });
  it('demo source cannot import or call real backend clients',()=>{
    const files=[...sources(join(root,'app/demo')),...sources(join(root,'components')).filter(file=>file.endsWith('demo-app.tsx')),...sources(join(root,'lib/demo'))];
    const forbidden=/from\s+['"][^'"]*(?:api-client|supabase-js|lib\/server|lib\/api|networking\/backend)|createClient\s*\(|\bfetch\s*\(/;
    for(const file of files) expect(readFileSync(file,'utf8'),file).not.toMatch(forbidden);
  });
  it('demo state adapter only uses sessionStorage',()=>{
    const adapter=readFileSync(join(root,'lib/demo/mock-api.ts'),'utf8');
    expect(adapter).toContain('sessionStorage');
    expect(adapter).not.toMatch(/localStorage|document\.cookie|fetch\s*\(/);
  });
});
