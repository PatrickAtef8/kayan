import chromium from '@sparticuz/chromium';
import puppeteer from 'puppeteer-core';
import pg from 'pg';

const BASE = 'http://localhost:3100';
const db = new pg.Pool({ connectionString: 'postgres://postgres:postgres@localhost:5432/kayan_ui' });
const U = { owner: '20000000-0000-0000-0000-000000000001', keeper: '20000000-0000-0000-0000-000000000002', rep: '20000000-0000-0000-0000-000000000003', rep2: '20000000-0000-0000-0000-000000000004' };
const EMAIL = { owner: 'owner@ui.test', keeper: 'keeper@ui.test', rep: 'rep@ui.test', rep2: 'rep2@ui.test' };
const ctx = (await db.query('select * from ui_ctx')).rows[0];
let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('  ok   -', m); } else { fail++; console.log('  FAIL -', m); } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// run SQL exactly as PostgREST would: role authenticated + the user's JWT claims
async function asUser(uid, sql, params = []) {
  const c = await db.connect();
  try {
    await c.query('begin'); await c.query('set local role authenticated');
    await c.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ sub: uid, role: 'authenticated', aud: 'authenticated' })]);
    const r = await c.query(sql, params); await c.query('commit'); return r.rows;
  } catch (e) { await c.query('rollback'); throw e; } finally { c.release(); }
}
const su = async (sql, p = []) => (await db.query(sql, p)).rows;
const mock = async (q) => (await fetch(`http://localhost:54321/__ctl?${q}`)).json();

const items = (n) => [{ product_id: ctx.p1, quantity: n, unit_price: 250, discount: 0 }, { product_id: ctx.p2, quantity: n * 2, unit_price: 40, discount: 0 }];
const sale = (uid, no, customer, n, rep = null) => asUser(uid, 'select create_sales_invoice($1,$2,$3,$4,$5,$6::jsonb,0,0,0,$7,null,$8) id', [ctx.org, customer, ctx.w, no, '2026-03-01', JSON.stringify(items(n)), 'نقدًا', rep]);

const browser = await puppeteer.launch({ args: [...chromium.args.filter((a) => a !== '--single-process' && a !== '--no-zygote'), '--lang=ar', '--no-sandbox'], executablePath: await chromium.executablePath(), headless: 'shell' });

async function open(role, viewport = { width: 1280, height: 800 }) {
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  await page.setViewport(viewport);
  const errors = []; page.on('pageerror', (e) => errors.push(String(e))); page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle2' });
  await page.type('input[type=email]', EMAIL[role]); await page.type('input[type=password]', 'test1234');
  await Promise.all([page.waitForFunction(() => location.pathname.startsWith('/dashboard'), { timeout: 30000 }), page.click('button[type=submit]')]);
  await page.waitForSelector('button[aria-haspopup="true"][aria-label^="الإشعارات"]', { timeout: 30000 });
  await page.evaluate(() => { window.__marker = 'no-reload'; });            // survives only while the page is NOT reloaded
  return { page, errors, context };
}
const bell = 'button[aria-haspopup="true"][aria-label^="الإشعارات"]';
const badge = async (page) => page.$eval(bell, (b) => { const s = b.querySelector('span'); return s ? s.textContent.trim() : null; });
const waitBadge = async (page, text, ms = 8000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if ((await badge(page)) === text) return true; await sleep(150); } return false; };
const stillSamePage = (page) => page.evaluate(() => window.__marker === 'no-reload');
const panelText = async (page) => page.evaluate(() => (document.querySelector('[aria-expanded="true"]')?.parentElement?.innerText) ?? '');
const shot = (page, name) => page.screenshot({ path: `/tmp/ui/shots/${name}.png` });
const dbRow = async (uid, type) => (await su('select * from notifications where recipient_user_id = $1 and type = $2 order by created_at desc limit 1', [uid, type]))[0];

try {
  console.log('\n[1] owner signs in: no notifications -> no red dot');
  const owner = await open('owner');
  ok((await badge(owner.page)) === null, 'bell has no badge/red dot when nothing is unread');
  await owner.page.click(bell); await sleep(300);
  ok((await panelText(owner.page)).includes('لا توجد إشعارات بعد'), 'empty state is shown');
  ok(await owner.page.$eval('button[role=tab][aria-selected=true]', (e) => e.textContent) === 'الكل', 'tabs are present (Arabic, RTL)');
  await owner.page.click(bell);

  console.log('\n[2] the REP posts a sale -> owner sees the red dot WITHOUT refreshing');
  const keeper = await open('keeper'); const rep = await open('rep');
  await sale(U.rep, 'UI-1', ctx.c1, 10);
  ok(await waitBadge(owner.page, '١'), 'owner: red badge "١" appeared live');
  ok(await stillSamePage(owner.page), 'owner: page was NOT reloaded');
  ok(await waitBadge(keeper.page, '١'), 'storekeeper: badge "١" appeared live (dispatch task)');
  ok((await badge(rep.page)) === null, 'rep: no badge for his own action');

  console.log('\n[3] owner opens the bell: content, then reads it');
  await owner.page.click(bell); await sleep(400);
  let txt = await panelText(owner.page);
  ok(txt.includes('فاتورة بيع جديدة UI-1'), 'owner: title shown');
  ok(txt.includes('مطعم الأمل') && txt.includes('ج.م'), 'owner: customer and amount shown');
  ok(txt.includes('أحمد المندوب'), 'owner: who did it');
  ok((await badge(owner.page)) === '١', 'opening the panel alone does not mark anything read');
  await shot(owner.page, '01-owner-bell-desktop');
  const href = await owner.page.$eval('[aria-expanded="true"]', (b) => b.parentElement.querySelector('a')?.getAttribute('href'));
  ok(href === '/dashboard/sales?q=UI-1', 'owner: item links to the invoice list');
  await owner.page.click('[aria-expanded="true"] ~ div a');
  await owner.page.waitForFunction(() => location.pathname === '/dashboard/sales', { timeout: 15000 });
  ok(await waitBadge(owner.page, null), 'owner: clicking the item clears the red dot');
  ok((await dbRow(U.owner, 'sales_invoice_created')).read_at !== null, 'owner: read_at saved in the database');
  await owner.page.reload({ waitUntil: 'networkidle2' }); await owner.page.waitForSelector(bell);
  await owner.page.evaluate(() => { window.__marker = 'no-reload'; });
  ok((await badge(owner.page)) === null, 'owner: after a full reload the dot is STILL gone (persisted)');
  await owner.page.click(bell); await sleep(300);
  txt = await panelText(owner.page);
  ok(txt.includes('فاتورة بيع جديدة UI-1'), 'owner: the read notification stays in the history');
  await owner.page.click(bell);

  console.log('\n[4] storekeeper: items and quantities, no money; reading ≠ done');
  await keeper.page.click(bell); await sleep(400);
  txt = await panelText(keeper.page);
  ok(txt.includes('زيت عباد الشمس') && txt.includes('سكر'), 'keeper: both items listed');
  ok(txt.includes('المطلوب ١٠') && txt.includes('المطلوب ٢٠'), 'keeper: ordered quantities (10 and 20)');
  ok(txt.includes('بانتظار التنفيذ'), 'keeper: card says "waiting to be done"');
  ok(!txt.includes('ج.م') && !txt.includes('٢٥٠') && !txt.includes('مطعم'), 'keeper: no money, price or customer anywhere in the panel');
  await shot(keeper.page, '02-keeper-task');
  await keeper.page.keyboard.press('Escape'); await sleep(200);
  await keeper.page.click(bell); await sleep(200);
  const kc = await keeper.page.$('[aria-expanded="true"] ~ div a'); await kc.evaluate((a) => a.addEventListener('click', (e) => e.preventDefault(), { once: true }));
  await kc.click();                                                            // mark read (navigation prevented for this check)
  ok(await waitBadge(keeper.page, null), 'keeper: badge cleared after opening the task');
  const kr = await dbRow(U.keeper, 'warehouse_dispatch_needed');
  ok(kr.read_at !== null && kr.resolved_at === null, 'keeper: READ in the DB but the task is still OPEN');
  ok((await su("select dispatch_status from sales_invoices where invoice_number = 'UI-1'"))[0].dispatch_status === 'pending', 'and the invoice still waits for dispatch');

  console.log('\n[5] partial dispatch -> keeper card updates live (remaining), owner + rep are told');
  const line = (await asUser(U.keeper, "select (l->>'line_id') lid from warehouse_sales_orders($1,'open','UI-1') o, jsonb_array_elements(o.lines) l where l->>'product_name' = 'زيت عباد الشمس'", [ctx.org]))[0].lid;
  await asUser(U.keeper, 'select confirm_sales_dispatch($1,$2,$3::jsonb,$4)', [ctx.org, (await su("select id from sales_invoices where invoice_number='UI-1'"))[0].id, JSON.stringify([{ line_id: line, quantity: 6 }]), 'دفعة أولى']);
  ok(await waitBadge(owner.page, '١'), 'owner: red dot returns live for the dispatch');
  ok(await waitBadge(rep.page, '١'), 'rep: told his invoice was partly dispatched');
  await keeper.page.click(bell); await sleep(500);
  txt = await panelText(keeper.page);
  ok(txt.includes('المتبقي ٤'), 'keeper: his open card (already read) now shows the remaining 4, no refresh');
  ok((await badge(keeper.page)) === null, 'keeper: a colleague-free partial by himself does not raise his own dot');
  await keeper.page.click(bell);
  await owner.page.click(bell); await sleep(400);
  txt = await panelText(owner.page);
  ok(txt.includes('تم صرف جزء من فاتورة البيع UI-1') && txt.includes('متبقي ٤'), 'owner: partial dispatch with remaining quantity');
  await shot(owner.page, '03-owner-partial-dispatch');
  await owner.page.click(bell);
  await rep.page.click(bell); await sleep(400);
  txt = await panelText(rep.page);
  ok(txt.includes('تم صرف جزء من فاتورة البيع UI-1'), 'rep: dispatch update shown');
  await shot(rep.page, '04-rep-bell');
  await rep.page.click(bell);

  console.log('\n[6] complete dispatch -> keeper task closes ("تم") while read state is independent');
  await asUser(U.keeper, 'select confirm_sales_dispatch($1,$2)', [ctx.org, (await su("select id from sales_invoices where invoice_number='UI-1'"))[0].id]);
  await sleep(1200);
  await keeper.page.click(bell); await sleep(400);
  txt = await panelText(keeper.page);
  ok(txt.includes('اكتملت المهمة') && !txt.includes('بانتظار التنفيذ'), 'keeper: card shows the task is DONE');
  await shot(keeper.page, '05-keeper-done');
  await keeper.page.click(bell);

  console.log('\n[7] isolation between reps, and cross-role visibility in the browser');
  const rep2 = await open('rep2');
  ok((await badge(rep2.page)) === null, 'rep 2: nothing about rep 1\'s business');
  await sale(U.owner, 'UI-2', ctx.c1, 3, ctx.rep1);                              // owner posts for rep 1
  ok(await waitBadge(rep.page, '٢'), 'rep 1: told about an invoice posted for him (count 2 with the dispatch update)');
  await sleep(800);
  ok((await badge(rep2.page)) === null, 'rep 2: still nothing');
  ok((await badge(owner.page)) === '٢', 'owner: no notification for his own invoice (still 2: the two dispatch updates)');

  console.log('\n[8] mark all as read + unread filter');
  await sale(U.rep, 'UI-3', ctx.c1, 2);
  ok(await waitBadge(owner.page, '٣'), 'owner: count is now 3 (UI-3 arrived live)');
  await owner.page.click(bell); await sleep(400);
  await owner.page.evaluate(() => [...document.querySelectorAll('button[role=tab]')].find((b) => b.textContent.includes('غير المقروءة')).click()); await sleep(300);
  txt = await panelText(owner.page);
  ok(txt.includes('UI-3') && txt.includes('جزء من فاتورة البيع UI-1') && txt.includes('تم صرف فاتورة البيع UI-1'), 'owner: unread tab lists the three unread');
  ok(!txt.includes('فاتورة بيع جديدة UI-1'), 'owner: and not the already-read one');
  await owner.page.evaluate(() => [...document.querySelectorAll('button')].find((b) => b.textContent.includes('تحديد الكل كمقروء')).click());
  ok(await waitBadge(owner.page, null), 'owner: "mark all as read" clears the dot');
  ok((await su('select count(*)::int c from notifications where recipient_user_id = $1 and read_at is null', [U.owner]))[0].c === 0, 'owner: DB agrees, nothing unread');
  ok((await su('select count(*)::int c from notifications where recipient_user_id = $1 and read_at is null', [U.rep]))[0].c >= 1, 'rep 1: his own unread rows were NOT touched');
  await owner.page.evaluate(() => [...document.querySelectorAll('button[role=tab]')].find((b) => b.textContent.includes('الكل')).click()); await sleep(300);
  ok((await panelText(owner.page)).includes('UI-3'), 'owner: history still there under "all"');
  await owner.page.click(bell);

  console.log('\n[9] connection drop: nothing is lost, it catches up on reconnect');
  const before = await mock('a=state');
  await mock('a=drop&block=1');                                                  // kill every socket, refuse reconnects
  await sleep(500);
  await sale(U.rep, 'UI-4', ctx.c1, 1);                                          // happens while the owner is "offline"
  await sleep(1500);
  ok((await badge(owner.page)) === null, 'owner: while the live channel is down the dot has not appeared yet');
  await mock('a=allow');
  ok(await waitBadge(owner.page, '١', 30000), 'owner: after reconnect the missed notification appears (catch-up refetch)');
  ok(await stillSamePage(owner.page), 'owner: still no page reload');

  console.log('\n[10] payments & a failure that is retried');
  await asUser(U.owner, 'select record_customer_collection($1,$2,null,150,$3,$4,null,null)', [ctx.org, ctx.c1, '2026-03-02', 'نقدًا']);
  ok(await waitBadge(rep.page, '٤', 10000), 'rep 1: told about a payment from HIS customer (count 4)');
  ok((await su("select count(*)::int c from notifications where type='rep_payment' and recipient_user_id = $1", [U.rep]))[0].c === 1 && (await su("select count(*)::int c from notifications where type='rep_payment' and recipient_user_id = $1", [U.rep2]))[0].c === 0, 'rep 1 got it, rep 2 did not (DB)');
  await su('alter table notifications add constraint tmp_break check (false) not valid');
  await sale(U.rep, 'UI-5', ctx.c1, 1);
  await su('alter table notifications drop constraint tmp_break');
  ok((await su("select count(*)::int c from sales_invoices where invoice_number='UI-5'"))[0].c === 1, 'sale UI-5 was posted although notifications were broken');
  ok((await su("select count(*)::int c from notification_failures where done_at is null"))[0].c === 1, 'the failure is recorded');
  await keeper.page.reload({ waitUntil: 'networkidle2' }); await keeper.page.waitForSelector(bell);   // any bell load/refresh runs the retry
  await sleep(1500);
  ok((await su("select count(*)::int c from notification_failures where done_at is null"))[0].c === 0, 'the bell\'s retry delivered it');
  ok((await su("select count(*)::int c from notifications where payload->>'invoice_number' = 'UI-5' and type = 'warehouse_dispatch_needed'"))[0].c === 1, 'the keeper task for UI-5 exists, exactly once');

  console.log('\n[11] mobile layout');
  const m = await open('owner', { width: 390, height: 780 });
  await sale(U.rep, 'UI-6', ctx.c1, 1); await waitBadge(m.page, '٢'); 
  await m.page.click(bell); await sleep(500);
  const box = await m.page.$eval('[aria-expanded="true"] ~ div', (d) => { const r = d.getBoundingClientRect(); return { l: r.left, r: r.right, w: innerWidth }; });
  ok(box.l >= 0 && box.r <= box.w, `mobile: panel fits inside the screen (${Math.round(box.l)}–${Math.round(box.r)} of ${box.w})`);
  await shot(m.page, '06-owner-mobile');

  const allErrors = [owner.errors, keeper.errors, rep.errors, m.errors].flat().filter((e) => !/favicon|font|Failed to load resource|net::ERR|WebSocket connection to .* failed/i.test(e));
  ok(allErrors.length === 0, 'no JavaScript errors in any browser (the refused WebSocket reconnects of step 9 are expected and excluded)' + (allErrors.length ? ': ' + allErrors.slice(0, 3).join(' | ') : ''));
  console.log('\nmock stats:', JSON.stringify(await mock('a=state')));
} catch (e) { fail++; console.log('  FAIL - exception:', e.stack || e); }
await browser.close(); await db.end();
console.log(`\n${fail === 0 ? 'UI TEST PASSED' : 'UI TEST FAILED'}  (${pass} ok, ${fail} failed)`);
process.exit(fail ? 1 : 0);
