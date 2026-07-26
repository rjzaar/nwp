// ops#133 Phase 2 — browser e2e for the nwd <-> ssd daily-reset DEMO PAIR.
//
// DEV DDEV SITES ONLY. Proves, through a real chromium, the whole tester
// journey the proposal promises — and then proves that the nightly wipe does
// not break it:
//
//   1. an invited tester redeems ONE code at nwd /demo/join and is instantly
//      an account (zero PII: patron-saint name, @demo.invalid address);
//   2. that same tester walks into ssd over SSO — real authorization-code
//      round-trip against the nwd simple_oauth issuer;
//   3. the UID lock binds: mdl_user.idnumber === the tester's nwd account uuid
//      (the OIDC `sub`), with an auth_oauth2_linked_login row for our issuer;
//   4. art9_consent rides across as the auth_nwc_art9_consent preference — '1'
//      for a code-redeemed tester (nwc_demo_access grants Art.9 consent at
//      account creation), '0' for a Trialing member;
//   5. the tester self-enrols in a demo course and answers an inline quiz:
//      the write PERSISTS for the consenting tester and is EPHEMERAL (0 rows,
//      success:true — UX intact) for the non-consenting one;
//   6. `pl demo reset nwd --with-pair` restores BOTH halves to the golden cut:
//      the tester's account and their formation rows are gone from both sites,
//      the demo courses are back, the OIDC wiring still verifies —
//   7. and a FRESH code issued after the reset still works end-to-end.
//
// Prerequisites (run.sh does all of this): both ddev projects up, ssd rebuilt
// + wired + seeded, a paired golden captured, codes issued.

const { test, expect } = require('@playwright/test');
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const NWD_BASE = process.env.NWD_BASE || 'https://nwd-dev.ddev.site';
const SSD_BASE = process.env.SSD_BASE || 'https://ssd-dev.ddev.site';
const NWD_DIR  = process.env.NWD_DEV_DIR || `${process.env.HOME}/nwp/sites/nwd/dev`;
const SSD_DIR  = process.env.SSD_DEV_DIR || `${process.env.HOME}/nwp/sites/ssd/dev`;
const PL       = process.env.PL_BIN || `${process.env.HOME}/nwp/pl`;
const PROJECT_ROOT = process.env.PROJECT_ROOT || `${process.env.HOME}/nwp`;

// Codes + the seeded-member password are written by run.sh (0600).
const codes = JSON.parse(fs.readFileSync(path.join(__dirname, '.demo-codes.json'), 'utf8'));
const PASS  = fs.readFileSync(path.join(__dirname, '.demo-pass'), 'utf8').trim();

const TRIALING = { name: 'nwcdemo_trialing', mail: 'nwcdemo_trialing@demo.invalid' };
// Moodle renders the issuer button as the issuer NAME alone (not "Log in
// with <name>") inside .login-identityproviders.
const ISSUER_LINK = /nwd/i;
const DEMO_COURSE = 'demo_prayer';

function ddev(dir, args) {
  return execFileSync('ddev', args, { cwd: dir, encoding: 'utf8' });
}

/** SQL against the ssd Moodle DB (TSV, -N). */
function mysql(q) {
  return ddev(SSD_DIR, ['exec', `mysql -udb -pdb db -N -e ${JSON.stringify(q)}`])
      .split('\n').filter(l => !l.startsWith('PAGER set')).join('\n').trim();
}

/** nwd drush. */
function drush(args) {
  return ddev(NWD_DIR, ['exec', `drush ${args}`]);
}

/** pl, rooted at the worktree so it sees the Phase-2 code + pair contract. */
function pl(args) {
  return execFileSync('bash', [PL, ...args], {
    cwd: PROJECT_ROOT, encoding: 'utf8', env: { ...process.env, PROJECT_ROOT },
    maxBuffer: 32 * 1024 * 1024,
  });
}

function moodleUserId(uuid) {
  const id = mysql(`SELECT id FROM mdl_user WHERE idnumber='${uuid}' AND deleted=0`);
  return id ? parseInt(id, 10) : null;
}

function nwdUuidOfNewestDemoAccount() {
  // Demo accounts are the only ones on @demo.invalid created by redemption;
  // the newest is the one this test just made.
  const out = drush(`sql:query "SELECT u.uuid FROM users u JOIN users_field_data d ON d.uid=u.uid ` +
    `WHERE d.mail LIKE '%@demo.invalid' AND d.name NOT LIKE 'nwcdemo%' ORDER BY d.created DESC LIMIT 1"`);
  const uuid = out.trim().split('\n').pop().trim();
  expect(uuid, 'a freshly created demo account uuid').toMatch(/^[0-9a-f-]{36}$/);
  return uuid;
}

function nwdUuidOf(username) {
  const out = drush(
    `sql:query "SELECT u.uuid FROM users u JOIN users_field_data d ON d.uid=u.uid WHERE d.name='${username}'"`);
  const uuid = out.trim().split('\n').pop().trim();
  expect(uuid).toMatch(/^[0-9a-f-]{36}$/);
  return uuid;
}

/** Redeem an invite code at nwd /demo/join. Leaves the page logged in on nwd. */
async function redeemCode(page, code) {
  await page.goto(`${NWD_BASE}/demo/join`);
  await page.waitForLoadState('domcontentloaded');
  // #edit-code, not a generic text input: the theme's site-search box also
  // matches input[type=text] and is the first one in the DOM.
  const field = page.locator('#edit-code');
  await expect(field, 'the /demo/join code field').toBeVisible();
  await field.fill(code);
  await page.locator('form#nwc-demo-access-join input[type="submit"], #edit-submit').first().click();
  await page.waitForLoadState('load');
  // Redemption creates the account AND logs it in, redirecting to the front
  // page. (Re-requesting /demo/join afterwards is NOT a usable probe: the
  // route is anonymous-only, and Drupal renders the 403 at the same URL.)
  expect(page.url(), 'redemption redirected off the join form').not.toMatch(/\/demo\/join/);
  const body = page.locator('body');
  await expect(body, 'logged in on nwd after redemption')
      .toHaveClass(/user-logged-in|logged-in/);
}

/** Password login on nwd (used for the seeded non-consenting member). */
async function passwordLoginNwd(page, user) {
  await page.goto(`${NWD_BASE}/user/login`);
  await page.waitForLoadState('domcontentloaded');
  const nameField = page.locator('input[name="name_or_mail"], input[name="name"]').first();
  await nameField.fill(user.name);
  await page.fill('input[name="pass"]', PASS);
  await page.press('input[name="pass"]', 'Enter');
  await page.waitForLoadState('load');
}

/**
 * Walk the SSO dance from ssd's login page. The nwd session already exists
 * (the tester just redeemed / logged in), so this is normally two clicks —
 * but Open Social can still interpose the data-policy agreement and the
 * "Discernment" examen gate, and simple_oauth shows a grant screen for a
 * third-party client, so we walk whatever we are served.
 */
async function ssoIntoSsd(page) {
  for (let attempt = 0; attempt < 4; attempt++) {
    await page.goto(`${SSD_BASE}/login/index.php`);
    await page.waitForLoadState('domcontentloaded');
    if (!page.url().includes('/login')) break;   // already in

    await page.locator('.login-identityproviders a, a[href*="/auth/oauth2/login.php"]')
        .filter({ hasText: ISSUER_LINK }).first().click();

    let stranded = false;
    for (let step = 0; step < 8 && !stranded; step++) {
      await page.waitForLoadState('domcontentloaded');
      const url = page.url();
      if (url.startsWith(SSD_BASE)) break;

      const policyForm = page.locator('form[id*="data-policy"], form[action*="data-policy"]');
      const examenBtn = page.getByRole('button', { name: /ready to work/ });
      const grantBtn = page.locator(
        'input[value="Grant"], input[value="Allow"], button:has-text("Grant"), button:has-text("Allow")');

      if (await examenBtn.count()) {
        await examenBtn.first().click();
        await page.waitForLoadState('load');
      } else if (await policyForm.count()) {
        for (const box of await page.locator('input[type="checkbox"]').all()) {
          if (await box.isVisible() && !(await box.isChecked())) await box.check({ force: true });
        }
        await page.locator('#edit-submit').first().click();
        await page.waitForLoadState('load');
      } else if (url.includes('/oauth/authorize') && await grantBtn.count()) {
        await grantBtn.first().click();
        await page.waitForLoadState('load');
      } else {
        stranded = true;
      }
    }
    if (page.url().startsWith(SSD_BASE)) break;
  }

  // Moodle forces profile completion when the IdP sends no family_name.
  // nwd's demo accounts carry none (nwc_demo_access sets no profile names) —
  // a REAL tester-UX defect, recorded in the Phase-2 report, not a test bug.
  await page.waitForLoadState('domcontentloaded');
  if (page.url().includes('/user/edit.php')) {
    const last = page.locator('#id_lastname');
    if (await last.count() && !(await last.inputValue())) await last.fill('Demo');
    await page.locator('#id_submitbutton').click();
    await page.waitForLoadState('load');
  }

  await page.goto(`${SSD_BASE}/my/`);
  await page.waitForLoadState('domcontentloaded');
  await expect(page.locator('body.notloggedin')).toHaveCount(0);
}

/** Self-enrol into a demo course and return its id + the depthcontent cmid. */
async function enterCourse(page, shortname) {
  const courseid = parseInt(mysql(`SELECT id FROM mdl_course WHERE shortname='${shortname}'`), 10);
  expect(courseid, `course ${shortname}`).toBeGreaterThan(0);
  await page.goto(`${SSD_BASE}/course/view.php?id=${courseid}`);
  await page.waitForLoadState('domcontentloaded');
  // Self-enrolment interstitial: one button.
  const enrolBtn = page.locator('input[value*="Enrol"], button:has-text("Enrol me")').first();
  if (await enrolBtn.count()) {
    await enrolBtn.click();
    await page.waitForLoadState('load');
  }
  const cmid = parseInt(mysql(
    `SELECT cm.id FROM mdl_course_modules cm
       JOIN mdl_modules m ON m.id = cm.module
      WHERE cm.course = ${courseid} AND m.name = 'depthcontent' LIMIT 1`), 10);
  expect(cmid, 'depthcontent cmid').toBeGreaterThan(0);
  return { courseid, cmid };
}

/** Fire the REAL gated write through Moodle's AJAX service. */
async function recordResponse(page, cmid) {
  await page.goto(`${SSD_BASE}/mod/depthcontent/view.php?id=${cmid}`);
  await page.waitForLoadState('domcontentloaded');
  return await page.evaluate(async (cmid) => {
    const r = await fetch(
      `${M.cfg.wwwroot}/lib/ajax/service.php?sesskey=${M.cfg.sesskey}&info=mod_depthcontent_record_response`,
      { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify([{ index: 0, methodname: 'mod_depthcontent_record_response',
          args: { cmid, quizitemid: 'q1', response: 'Lectio divina', correct: 1,
                  confidence: 3, latencyms: 1500, itemtype: 'multichoice',
                  cognition: 'recall', coreaccountable: 1, singletag: 1 } }]) });
    return await r.json();
  }, cmid);
}

function formationCounts(uid) {
  const q = (t) => parseInt(mysql(`SELECT COUNT(*) FROM mdl_${t} WHERE userid=${uid}`), 10);
  return { responses: q('depthcontent_responses'), sr: q('depthcontent_sr'),
           retrieval_log: q('depthcontent_retrieval_log'), mastery: q('depthcontent_mastery') };
}

function art9Pref(uid) {
  return mysql(`SELECT value FROM mdl_user_preferences WHERE userid=${uid} AND name='auth_nwc_art9_consent'`);
}

// ---------------------------------------------------------------------------

test.describe.serial('nwd <-> ssd demo pair: one code, two sites, nightly wipe', () => {
  const state = {};

  test('1. invited tester redeems ONE code on nwd and is instantly a member', async ({ browser }) => {
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await ctx.newPage();
    await redeemCode(page, codes.member);
    state.uuid = nwdUuidOfNewestDemoAccount();
    console.log(`    tester uuid: ${state.uuid}`);
    state.ctx = ctx; state.page = page;   // keep the session for step 2
  });

  test('2. the same tester walks into ssd over SSO — UID lock binds', async () => {
    await ssoIntoSsd(state.page);
    const uid = moodleUserId(state.uuid);
    expect(uid, `mdl_user.idnumber == ${state.uuid} (the OIDC sub)`).not.toBeNull();
    state.uid = uid;
    const linked = parseInt(mysql(
      `SELECT COUNT(*) FROM mdl_auth_oauth2_linked_login WHERE userid=${uid}`), 10);
    expect(linked, 'linked_login row for our issuer').toBeGreaterThan(0);
    console.log(`    ssd uid=${uid} idnumber=${state.uuid}`);
  });

  test('3. ssd shows the demo posture: banner, noindex, report-a-problem back to nwd', async () => {
    const html = await state.page.content();
    expect(html, 'demo banner').toContain('nwp-demo-banner');
    expect(html, 'report-a-problem affordance').toContain('Report a problem');
    expect(html, 'link back to the provider feedback form').toContain(`${NWD_BASE}/feedback/submit`);
    const robots = mysql(`SELECT value FROM mdl_config WHERE name='allowindexing'`);
    expect(robots, 'allowindexing=2 (noindex everywhere)').toBe('2');
    const mail = mysql(`SELECT value FROM mdl_config WHERE name='noemailever'`);
    expect(mail, 'outbound mail killed').toBe('1');
  });

  test('4. art9_consent rides across: code-redeemed tester = consenting', async () => {
    expect(art9Pref(state.uid), 'auth_nwc_art9_consent').toBe('1');
  });

  test('5. tester enters a real course and the gated write PERSISTS', async () => {
    const { cmid } = await enterCourse(state.page, DEMO_COURSE);
    state.cmid = cmid;
    const before = formationCounts(state.uid);
    const resp = await recordResponse(state.page, cmid);
    expect(resp[0].error, JSON.stringify(resp)).toBeFalsy();
    const after = formationCounts(state.uid);
    console.log(`    before=${JSON.stringify(before)} after=${JSON.stringify(after)}`);
    expect(after.responses).toBeGreaterThan(before.responses);
    expect(after.retrieval_log).toBeGreaterThan(before.retrieval_log);
    expect(after.mastery).toBeGreaterThan(0);
    await state.ctx.close();
  });

  test('6. non-consenting member: identical write is EPHEMERAL (0 rows, success:true)', async ({ browser }) => {
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await ctx.newPage();
    await passwordLoginNwd(page, TRIALING);
    await ssoIntoSsd(page);
    const uuid = nwdUuidOf(TRIALING.name);
    const uid = moodleUserId(uuid);
    expect(uid, 'trialing member landed on ssd').not.toBeNull();
    expect(art9Pref(uid), 'auth_nwc_art9_consent').toBe('0');

    await enterCourse(page, DEMO_COURSE);
    const resp = await recordResponse(page, state.cmid);
    expect(resp[0].error, JSON.stringify(resp)).toBeFalsy();
    expect(resp[0].data.success, 'UX intact — the answer is acknowledged').toBe(true);
    expect(formationCounts(uid)).toEqual({ responses: 0, sr: 0, retrieval_log: 0, mastery: 0 });
    await ctx.close();
  });

  test('7. PAIRED RESET returns BOTH halves to the golden cut', () => {
    const out = pl(['demo', 'reset', 'nwd', '--with-pair', '--force']);
    console.log(out.split('\n').filter(l => l.trim()).slice(-12).join('\n'));
    expect(out, 'paired reset completed').toMatch(/Paired demo reset complete/);

    // The tester is gone from BOTH halves — that is the nightly promise.
    expect(moodleUserId(state.uuid), 'tester wiped from ssd').toBeNull();
    const stillOnNwd = drush(
      `sql:query "SELECT COUNT(*) FROM users u WHERE u.uuid='${state.uuid}'"`).trim().split('\n').pop().trim();
    expect(stillOnNwd, 'tester wiped from nwd').toBe('0');

    // And the demo is intact: courses back, wiring still verifies.
    const courses = parseInt(mysql(
      `SELECT COUNT(*) FROM mdl_course WHERE shortname LIKE 'demo_%'`), 10);
    expect(courses, 'demo catalogue restored').toBeGreaterThanOrEqual(3);
  });

  test('8. a FRESH code issued after the reset still works end-to-end', async ({ browser }) => {
    const issued = pl(['demo', 'codes', 'nwd', 'issue', 'tester-member', '--expires=1d']);
    const m = issued.match(/([A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5})/);
    expect(m, 'a fresh plaintext code was printed once').not.toBeNull();

    const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await ctx.newPage();
    await redeemCode(page, m[1]);
    const uuid = nwdUuidOfNewestDemoAccount();
    expect(uuid).not.toBe(state.uuid);
    await ssoIntoSsd(page);
    const uid = moodleUserId(uuid);
    expect(uid, 'post-reset tester reached ssd over SSO').not.toBeNull();
    expect(art9Pref(uid)).toBe('1');
    console.log(`    post-reset tester uuid=${uuid} ssd uid=${uid}`);
    await ctx.close();
  });
});
