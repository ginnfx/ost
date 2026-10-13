import { expect, test } from '@playwright/test';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
const require=createRequire(import.meta.url);
const axeSource=readFileSync(require.resolve('axe-core/axe.min.js'),'utf8');

test('demo advertises isolation and stays within phone width',async({page})=>{
  await page.goto('/demo');
  await expect(page.getByText('Nothing here is saved or real.')).toBeVisible();
  await expect(page.getByRole('heading',{name:'Glass Harbor Trial'})).toBeVisible();
  await expect(page.locator('html')).toHaveAttribute('lang','en');
  const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>document.documentElement.clientWidth);
  expect(overflow).toBe(false);
});

test('participant can upload, preview, confirm, wait, and enter listening',async({page})=>{
  await page.goto('/demo');
  for(let i=1;i<=5;i++){
    await page.getByLabel('Anime or franchise').fill(`Glass Harbor ${i}`);
    await page.getByLabel('OST title').fill(`First Light ${i}`);
    await page.getByLabel('Video clip').setInputFiles({ name: `clip-${i}.mp4`, mimeType: 'video/mp4', buffer: Buffer.from('demo placeholder only') });
    await page.getByRole('button',{name:'Upload video'}).click();
    await expect(page.getByText('Upload processed. Preview the anonymous audio, then confirm it.')).toBeVisible();
    await page.getByRole('button',{name:'Preview processed audio'}).last().click();
    await page.getByRole('button',{name:'Confirm entry'}).last().click();
  }
  await page.getByRole('button',{name:'Finish submissions'}).click();
  await page.getByLabel('Participant area').getByRole('button',{name:'Skip to listening'}).click();
  await expect(page.getByRole('heading',{name:'Batch 1 of 5'})).toBeVisible();
});

test('layout reflows at 320px, iPhone portrait, and landscape under throttled requests',async({page,context})=>{
  await context.route('**/*',async route=>{await new Promise(resolve=>setTimeout(resolve,120));await route.continue();});
  for(const viewport of [{width:320,height:700},{width:375,height:812},{width:844,height:390}]){
    await page.setViewportSize(viewport);
    await page.goto('/demo');
    await expect(page.getByText('Nothing here is saved or real.')).toBeVisible();
    const overflow=await page.evaluate(()=>({scroll:document.documentElement.scrollWidth,client:document.documentElement.clientWidth,items:[...document.querySelectorAll('body *')].filter(e=>e.getBoundingClientRect().right>document.documentElement.clientWidth+1).slice(0,8).map(e=>({tag:e.tagName,cls:(e as HTMLElement).className,right:e.getBoundingClientRect().right,width:e.getBoundingClientRect().width}))}));
    expect(overflow.scroll<=overflow.client,JSON.stringify(overflow)).toBe(true);
  }
});

test('public pages have no automated WCAG A/AA axe violations in dark or light mode',async({page})=>{
  for(const route of ['/','/how-it-works','/demo']) for(const colorScheme of ['dark','light'] as const){
    await page.emulateMedia({colorScheme});await page.goto(route);
    await page.evaluate((source)=>{eval(source);},axeSource);
    const report=await page.evaluate(async()=>{
      const axe=(window as unknown as Window & {axe:{run:(document:Document,options:unknown)=>Promise<{violations:{id:string;help:string;nodes:{target:string[]}[]}[]}>}}).axe;
      return axe.run(document,{runOnly:{type:'tag',values:['wcag2a','wcag2aa','wcag21a','wcag21aa','wcag22aa']}});
    });
    expect(report.violations.map(v=>`${v.id}: ${v.help} (${v.nodes.map(n=>n.target.join(',')).join('; ')})`)).toEqual([]);
  }
});

test('responses use fresh strict CSP nonces and privacy headers',async({request})=>{
  const first=await request.get('/demo');
  const second=await request.get('/demo');
  const csp=first.headers()['content-security-policy']??'';
  expect(csp).toContain("script-src 'self' 'nonce-");
  expect(csp).toContain("'strict-dynamic'");
  expect(csp).not.toContain("'unsafe-inline'");
  const nonceOne=csp.match(/'nonce-([^']+)'/)?.[1];
  const nonceTwo=(second.headers()['content-security-policy']??'').match(/'nonce-([^']+)'/)?.[1];
  expect(nonceOne).toBeTruthy();expect(nonceTwo).toBeTruthy();expect(nonceTwo).not.toBe(nonceOne);
  expect(first.headers()['x-robots-tag']).toContain('noindex');
  expect(first.headers()['x-content-type-options']).toBe('nosniff');
  expect(first.headers()['referrer-policy']).toBe('no-referrer');
});

test('host explores review, progress, recovery, scoring, and per-entry passkey-gated reveals',async({page})=>{
  await page.goto('/demo');
  await page.getByRole('button',{name:'Host'}).click();
  await page.getByRole('tab',{name:'Submissions'}).click();
  await page.getByRole('button',{name:/Flagged audio/}).click();
  await page.getByRole('tab',{name:'Progress'}).click();
  await page.getByRole('tabpanel').getByRole('button',{name:'Fast-forward friends'}).click();
  await page.getByRole('tab',{name:'Reopen ratings'}).click();
  await page.getByRole('button',{name:'Reopen ratings'}).click();
  await page.getByRole('tab',{name:'Credentials'}).click();
  await page.getByRole('button',{name:'Generate recovery codes'}).click();
  const code=(await page.locator('.recovery-codes').textContent())?.split('\n')[0]??'';
  await page.getByLabel('Use one demo recovery code').fill(code);
  await page.getByRole('button',{name:'Use code and revoke sessions'}).click();
  await expect(page.getByRole('button',{name:'Register replacement passkey'})).toBeVisible();
  await page.getByRole('button',{name:'Register replacement passkey'}).click();
  await page.getByRole('tab',{name:'Score'}).click();
  await page.getByRole('button',{name:'Score and freeze round'}).click();
  await page.getByRole('tab',{name:'Publish results'}).click();
  for(let entry=1;entry<=50;entry++){
    const button=page.getByRole('button',{name:'Hold to publish next soundtrack'});
    if(entry===1){
    await button.scrollIntoViewIfNeeded();
    const box=await button.boundingBox();if(!box)throw new Error('Publish control is not visible.');
    await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.waitForTimeout(1750);await page.mouse.up();
    }else await page.getByRole('button',{name:'Reveal next soundtrack'}).click();
    await page.getByRole('button',{name:'Simulate passkey verification'}).click();
    if(entry<50) await expect(page.getByText(`Participant preview: ${entry} soundtracks visible.`)).toBeVisible();
  }
  await page.getByRole('button',{name:'Participant'}).click();
  await expect(page.getByRole('heading',{name:'The round is complete'})).toBeVisible();
});
