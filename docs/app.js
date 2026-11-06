// OntoPop ↔ ELSST collaborative review — client app.
//
// Static data (terms, candidates, gpt-4o assignments) comes from review.json,
// built by scripts/07_build_review.R. Reviewer profiles and votes live in a
// shared store:
//   - Firestore (when config.json has a Firebase apiKey + projectId), shared
//     live between all reviewers; or
//   - "local demo mode" (no config, or ?local in the URL): the same data model
//     kept in this browser's localStorage, for trying the site out.
//
// Data model (both stores):
//   reviewers/{rid}      { name, affiliation, created }
//   vote_shards/s{NNN}   { v: { "<code>|<elsstUuid>": { <rid>: {t, n, c, u} } } }
// One shard document per OntoPop section (the NNN in code NNN-M, ~210 docs),
// so a page load costs ~210 Firestore reads however many votes exist, well
// inside the free tier. t = match type ('none' = reject), n = note,
// c / u = created / updated time.

const FIREBASE_VERSION = '10.12.2';
const PREFS_KEY = 'elsst_review_prefs_v2';
const LOCAL_DB_KEY = 'elsst_review_localdb_v1';
const NOTE_MAX = 1000;
const TYPES = ['exactMatch','closeMatch','broadMatch','narrowMatch','relatedMatch','none'];
const typeLabel = t => t === 'none' ? 'reject' : t;

const $ = s => document.querySelector(s);
const esc = s => (s == null ? '' : String(s)).replace(/[&<>"']/g,
  c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

// ── Static data ─────────────────────────────────────────────────────────────
let DATA = [], CTX = {}, XREF = {}, META = {};
const CODE_INDEX = {}, CHILDREN = {}, PARENTS = {};
let ROOTS = [];

// ── Shared (store) state ────────────────────────────────────────────────────
let STORE = null;
let REVIEWERS = {};          // rid -> {name, affiliation, created}
let SHARDS = {};             // sid -> { pk -> { rid -> vote } }
let reviewersLoaded = false;
let SYNC = { state: 'connecting', msg: 'Connecting…' };

// ── Per-browser state ───────────────────────────────────────────────────────
const PREF_DEFAULTS = { reviewerId: null, filter: 'all', hideReviewed: false,
                        hideRejected: false, expanded: [], lastCode: null };
const prefs = loadPrefs();
const EXP = new Set(prefs.expanded);  // expanded tree nodes (by code)
let cur = null;                       // code of the term on screen
const DRAFTS = {};                    // pk -> {t, n, editing}: unsaved form state
const STICKY = new Set();             // pks voted on this visit: keep visible
let coldOpen = false;                 // "gpt-4o rejected" section expanded?
let TSTATS = {}, TOTALS = {}, MATCH = {}, SUB = {};

function loadPrefs(){
  try { return Object.assign({}, PREF_DEFAULTS, JSON.parse(localStorage.getItem(PREFS_KEY)) || {}); }
  catch { return { ...PREF_DEFAULTS }; }
}
function savePrefs(){
  prefs.expanded = [...EXP];
  try { localStorage.setItem(PREFS_KEY, JSON.stringify(prefs)); } catch {}
}

// ── Keys ────────────────────────────────────────────────────────────────────
const sidOf  = code => 's' + code.split('-')[0];
const uuidOf = eid  => eid.slice(eid.lastIndexOf('/') + 1);
const pkOf   = (code, eid) => code + '|' + uuidOf(eid);

function humanVotes(code, eid){
  const m = SHARDS[sidOf(code)]?.[pkOf(code, eid)];
  if (!m) return [];
  return Object.entries(m)
    .filter(([, v]) => v && v.t)
    .map(([rid, v]) => ({ rid, ...v }))
    .sort((a, b) => (a.c || 0) - (b.c || 0));
}
// The signed-in reviewer id, or null. Before the profile list has loaded we
// trust the remembered id so the page doesn't flash a signed-out state.
function me(){
  const r = prefs.reviewerId;
  return r && (REVIEWERS[r] || !reviewersLoaded) ? r : null;
}

// ════════════════════════════════════════════════════════════════════════════
// Stores
// ════════════════════════════════════════════════════════════════════════════
const tsMillis = x => x == null ? null
  : typeof x === 'number' ? x
  : typeof x.toMillis === 'function' ? x.toMillis() : null;

async function makeFirebaseStore(fbConfig, onChange){
  const base = `https://www.gstatic.com/firebasejs/${FIREBASE_VERSION}`;
  const { initializeApp } = await import(`${base}/firebase-app.js`);
  const fs = await import(`${base}/firebase-firestore.js`);
  const app = initializeApp(fbConfig);
  const db = fs.getFirestore(app);

  let votesPending = false, revPending = false, fromCache = true, gotServer = false, slow = false;
  const status = () => {
    if (!gotServer && slow) return { state: 'error', msg: 'Can’t reach the shared database — check your connection (or the Firebase settings in config.json). Votes made now are saved once it connects, if this tab stays open.' };
    if (votesPending || revPending) return { state: 'saving', msg: 'Saving…' };
    if (!gotServer) return { state: 'connecting', msg: 'Connecting…' };
    if (fromCache)  return { state: 'offline', msg: 'Offline — changes will sync when reconnected' };
    return { state: 'live', msg: 'Live · shared' };
  };
  const fail = what => err => {
    console.error(what, err);
    onChange({ sync: { state: 'error', msg: `Sync error (${what}): ${err.code || err.message}` } });
  };

  fs.onSnapshot(fs.collection(db, 'reviewers'), { includeMetadataChanges: true }, snap => {
    const out = {};
    snap.forEach(d => {
      const x = d.data({ serverTimestamps: 'estimate' });
      out[d.id] = { name: x.name, affiliation: x.affiliation, created: tsMillis(x.created) };
    });
    revPending = snap.metadata.hasPendingWrites;
    onChange({ reviewers: out, reviewersLoaded: !snap.metadata.fromCache, sync: status() });
  }, fail('reviewers'));

  fs.onSnapshot(fs.collection(db, 'vote_shards'), { includeMetadataChanges: true }, snap => {
    const out = {};
    snap.forEach(d => {
      const v = d.data({ serverTimestamps: 'estimate' }).v || {};
      const shard = {};
      for (const [pk, byRid] of Object.entries(v)) {
        shard[pk] = {};
        for (const [rid, x] of Object.entries(byRid || {})) {
          if (x && x.t) shard[pk][rid] = { t: x.t, n: x.n || '', c: tsMillis(x.c), u: tsMillis(x.u) };
        }
      }
      out[d.id] = shard;
    });
    votesPending = snap.metadata.hasPendingWrites;
    fromCache = snap.metadata.fromCache;
    if (!fromCache) gotServer = true;
    onChange({ shards: out, sync: status() });
  }, fail('votes'));

  setTimeout(() => { slow = true; if (!gotServer) onChange({ sync: status() }); }, 15000);

  const shardRef = code => fs.doc(db, 'vote_shards', sidOf(code));
  const report = what => err => {
    console.error(what, err);
    toast(`Could not ${what}: ${err.code || err.message}`, true);
  };
  return {
    mode: 'firebase',
    addReviewer({ name, affiliation }){
      const ref = fs.doc(fs.collection(db, 'reviewers'));   // id assigned locally
      fs.setDoc(ref, { name, affiliation, created: fs.serverTimestamp() })
        .catch(report('create the reviewer profile'));
      return ref.id;
    },
    setVote(code, eid, rid, t, n, isNew){
      const vote = { t, n, u: fs.serverTimestamp() };
      if (isNew) vote.c = fs.serverTimestamp();
      // merge:true deep-merges nested maps, so other reviewers' votes (and
      // this vote's original `c` on edits) are left untouched.
      return fs.setDoc(shardRef(code), { v: { [pkOf(code, eid)]: { [rid]: vote } } }, { merge: true })
        .catch(report('save your vote'));
    },
    deleteVote(code, eid, rid){
      return fs.setDoc(shardRef(code), { v: { [pkOf(code, eid)]: { [rid]: fs.deleteField() } } }, { merge: true })
        .catch(report('delete your vote'));
    },
  };
}

function makeLocalStore(onChange){
  const read = () => {
    try { return JSON.parse(localStorage.getItem(LOCAL_DB_KEY)) || { reviewers: {}, shards: {} }; }
    catch { return { reviewers: {}, shards: {} }; }
  };
  let db = read();
  const persist = () => {
    try { localStorage.setItem(LOCAL_DB_KEY, JSON.stringify(db)); }
    catch { toast('Could not save to this browser’s storage.', true); }
  };
  const msg = 'Local demo mode — votes are saved in this browser only';
  const emit = () => onChange({
    reviewers: structuredClone(db.reviewers), reviewersLoaded: true,
    shards: structuredClone(db.shards), sync: { state: 'local', msg } });
  // Keep several open tabs in sync, like the shared store would.
  window.addEventListener('storage', e => { if (e.key === LOCAL_DB_KEY) { db = read(); emit(); } });
  queueMicrotask(emit);
  return {
    mode: 'local',
    addReviewer({ name, affiliation }){
      const id = 'r' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
      db.reviewers[id] = { name, affiliation, created: Date.now() };
      persist(); emit(); return id;
    },
    setVote(code, eid, rid, t, n, isNew){
      const sid = sidOf(code), pk = pkOf(code, eid), now = Date.now();
      const shard = db.shards[sid] ??= {};
      const byRid = shard[pk] ??= {};
      byRid[rid] = { t, n, c: isNew || !byRid[rid] ? now : byRid[rid].c, u: now };
      persist(); emit();
    },
    deleteVote(code, eid, rid){
      const byRid = db.shards[sidOf(code)]?.[pkOf(code, eid)];
      if (byRid) { delete byRid[rid]; persist(); emit(); }
    },
  };
}

function onStoreChange(ch){
  if (ch.reviewers) REVIEWERS = ch.reviewers;
  if (ch.reviewersLoaded) {
    const first = !reviewersLoaded;
    reviewersLoaded = true;
    // A remembered profile that no longer exists (e.g. local data cleared).
    if (prefs.reviewerId && !REVIEWERS[prefs.reviewerId]) { prefs.reviewerId = null; savePrefs(); }
    if (first && !prefs.reviewerId) openWho();
  }
  if (ch.shards) SHARDS = ch.shards;
  if (ch.sync) SYNC = ch.sync;
  if ($('#whoDlg').open) fillWhoSelect();
  if (DATA.length) renderAll();
}

// ════════════════════════════════════════════════════════════════════════════
// Derived state: review stats, filters, tree visibility
// ════════════════════════════════════════════════════════════════════════════
const isProposal = c => c.match_type && c.match_type !== 'none';

function computeStats(){
  const rid = me();
  let all = 0, allRev = 0, prop = 0, propRev = 0;
  TSTATS = {};
  for (const t of DATA) {
    const s = { total: 0, rev: 0, prop: 0, propRev: 0, needMine: 0 };
    for (const c of t.candidates) {
      const hv = humanVotes(t.code, c.elsst_id);
      s.total++; if (hv.length) s.rev++;
      if (isProposal(c)) {
        s.prop++; if (hv.length) s.propRev++;
        if (!rid || !hv.some(v => v.rid === rid)) s.needMine++;
      }
    }
    TSTATS[t.code] = s;
    all += s.total; allRev += s.rev; prop += s.prop; propRev += s.propRev;
  }
  TOTALS = { all, allRev, prop, propRev };
}

const FILTERS = [
  ['all',        'All terms',                         () => true],
  ['strong',     'gpt-4o proposed exact/close',       t => t.candidates.some(c => c.match_type === 'exactMatch' || c.match_type === 'closeMatch')],
  ['labelmatch', 'Phase 1 label match',               t => t.candidates.some(c => (c.provenance || '').includes('phase1'))],
  ['unreviewed', 'Unreviewed gpt-4o proposals',       t => TSTATS[t.code].propRev < TSTATS[t.code].prop],
  ['mine',       'Proposals I haven’t voted on',      t => TSTATS[t.code].needMine > 0],
  ['humanvotes', 'Has human votes',                   t => TSTATS[t.code].rev > 0],
];
const filterFn = key => (FILTERS.find(f => f[0] === key) || FILTERS[0])[2];

// MATCH[code]: term passes the filter. SUB[code]: it or a descendant does
// (so the branch stays visible in the tree). The hierarchy is a DAG, so memoise.
function computeVisibility(){
  const fn = filterFn(prefs.filter);
  MATCH = {}; SUB = {};
  for (const t of DATA) MATCH[t.code] = fn(t);
  const busy = new Set();
  const sub = code => {
    if (code in SUB) return SUB[code];
    if (busy.has(code)) return MATCH[code];      // cycle guard
    busy.add(code);
    let v = MATCH[code];
    for (const k of CHILDREN[code]) if (sub(k)) v = true;   // visit all to memoise
    busy.delete(code);
    return (SUB[code] = v);
  };
  for (const t of DATA) sub(t.code);
}

function termDot(code){
  const s = TSTATS[code];
  const done = s.prop ? s.propRev === s.prop : (s.total > 0 && s.rev === s.total);
  const cls = done ? 'd2' : s.rev ? 'd1' : '';
  const tip = `${s.rev} of ${s.total} links human-reviewed · ${s.propRev} of ${s.prop} gpt-4o proposals`;
  return `<i class="dot ${cls}" title="${tip}"></i>`;
}

// ════════════════════════════════════════════════════════════════════════════
// Rendering
// ════════════════════════════════════════════════════════════════════════════
function renderAll(opts = {}){
  computeStats();
  computeVisibility();
  renderHeader();
  renderTree(opts.scrollTree);
  renderMain();
}

function renderHeader(){
  const { all, allRev, prop, propRev } = TOTALS;
  const pct = all ? 100 * allRev / all : 0;
  $('#prog').style.width = pct + '%';
  $('#progtxt').textContent =
    `${allRev.toLocaleString()} / ${all.toLocaleString()} links reviewed (${
      pct > 0 && pct < 0.1 ? '<0.1' : pct < 10 ? pct.toFixed(1).replace(/\.0$/, '') : Math.round(pct)}%)`;
  $('#progsub').textContent = `gpt-4o proposals: ${propRev.toLocaleString()} / ${prop.toLocaleString()}`;

  const sync = $('#sync');
  sync.className = 'sync ' + SYNC.state;
  sync.textContent = SYNC.state === 'local' ? 'Local demo mode'
    : SYNC.state === 'error' ? '⚠ Not connected' : SYNC.msg;
  sync.title = SYNC.msg;

  const rid = me(), btn = $('#whoBtn');
  if (rid) {
    const r = REVIEWERS[rid];
    btn.textContent = r ? `👤 ${r.name}${r.affiliation ? ' · ' + r.affiliation : ''}` : '👤 …';
    btn.title = 'Reviewing as ' + (r ? `${r.name} (${r.affiliation})` : 'you') + ' — click to switch';
    btn.classList.remove('none');
  } else {
    btn.textContent = 'Choose reviewer profile';
    btn.title = 'Pick or create a reviewer profile to vote';
    btn.classList.add('none');
  }

  const sel = $('#filter');
  FILTERS.forEach((f, k) => {
    const n = DATA.reduce((a, t) => a + (f[2](t) ? 1 : 0), 0);
    sel.options[k].text = `${f[1]} (${n.toLocaleString()})`;
  });
  sel.value = prefs.filter;
}

function renderTree(scrollToCur){
  const box = $('#tree'), scroller = $('#treeScroll');
  const filtered = prefs.filter !== 'all';
  const rows = [];
  let maxDepth = 0;
  const walk = (code, depth, anc) => {
    if (filtered && !SUB[code]) return;
    const kids = CHILDREN[code].filter(k => !anc.has(k) && (!filtered || SUB[k]));
    const open = kids.length > 0 && EXP.has(code);
    const t = DATA[CODE_INDEX[code]];
    maxDepth = Math.max(maxDepth, depth);
    rows.push(`<div class="tn${code === cur ? ' cur' : ''}${filtered && !MATCH[code] ? ' dim' : ''}" data-code="${esc(code)}" style="padding-left:${4 + depth * 14}px">` +
      `<span class="tw${kids.length ? ' has' : ''}" data-act="toggle">${kids.length ? (open ? '▾' : '▸') : ''}</span>` +
      termDot(code) +
      `<span class="tl">${esc(t.label)}</span><span class="tc">${esc(code)}</span></div>`);
    if (open) { anc.add(code); for (const k of kids) walk(k, depth + 1, anc); anc.delete(code); }
  };
  for (const r of ROOTS) walk(r, 0, new Set());

  const top = scroller.scrollTop, left = scroller.scrollLeft;
  box.innerHTML = rows.length ? rows.join('') : '<div class="side-empty">No terms match this filter.</div>';
  box.style.minWidth = (maxDepth * 14 + 200) + 'px';
  scroller.scrollTop = top; scroller.scrollLeft = left;

  const nMatch = DATA.reduce((a, t) => a + (MATCH[t.code] ? 1 : 0), 0);
  $('#sideCount').textContent = filtered ? `· ${nMatch.toLocaleString()} matching` : `· ${DATA.length.toLocaleString()} terms`;
  $('#expandMatches').hidden = !filtered;

  if (scrollToCur) {
    const el = box.querySelector('.tn.cur');
    if (el) el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }
}

// Whether a link card is hidden by the reviewer's view options. Links the
// reviewer voted on during this visit stay visible so they can see/edit them.
function linkHidden(pk, hv){
  if (STICKY.has(pk) || !hv.length) return false;
  if (prefs.hideReviewed) return true;
  if (prefs.hideRejected && hv.every(v => v.t === 'none')) return true;
  return false;
}

function fmtTime(ms){
  if (!ms) return '';
  const d = new Date(ms);
  const sameYear = d.getFullYear() === new Date().getFullYear();
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', ...(sameYear ? {} : { year: 'numeric' }) });
}

function voteRow(v, { model = false, mine = false } = {}){
  const badge = `<span class="badge b-${esc(v.t)}">${esc(typeLabel(v.t))}</span>`;
  let who;
  if (model) {
    who = `<span class="who">gpt-4o <span class="model-tag">model</span></span>`;
  } else {
    const r = REVIEWERS[v.rid];
    const edited = v.u && v.c && v.u - v.c > 1000;
    const when = v.c ? `<span class="vtime" title="${esc(new Date(v.u || v.c).toLocaleString())}">${fmtTime(v.c)}${edited ? ' · edited' : ''}</span>` : '';
    who = `<span class="who">${esc(r ? r.name : 'Unknown reviewer')}${mine ? ' (you)' : ''}` +
          `${r && r.affiliation ? `<span class="aff">${esc(r.affiliation)}</span>` : ''}${when}</span>`;
  }
  const note = v.n ? `<span class="vnote">${esc(v.n)}` : `<span class="vnote none">no comment`;
  const acts = mine ? `<span class="vact"><button class="linkbtn" data-act="edit">edit</button>` +
                      `<button class="linkbtn danger" data-act="delete">delete</button></span>` : '';
  return `<div class="vote${mine ? ' mine' : ''}${model ? ' model' : ''}"><span>${badge}</span>${who}${note}${acts}</span></div>`;
}

function voteForm(pk, mine){
  const rid = me();
  if (!rid) return `<div class="vform signin">Choose a reviewer profile to add your vote.
      <button data-act="signin">Choose reviewer profile</button></div>`;
  const draft = DRAFTS[pk];
  if (mine && !draft?.editing) return '';           // already voted: edit via the vote row
  const selT = draft?.t ?? mine?.t ?? null;
  const note = draft?.n ?? mine?.n ?? '';
  const dirty = draft && !mine && (draft.t || draft.n);
  return `<div class="vform">
    <div class="vf-head"><span class="label">${mine ? 'Edit your vote' : 'Your vote'}</span>
      ${dirty ? '<span class="vf-draft">not submitted yet</span>' : ''}</div>
    <div class="decide">${TYPES.map(tp =>
      `<button type="button" data-act="pick" data-v="${tp}" class="t-${tp}${tp === selT ? ' sel' : ''}" title="${esc(META.type_defs?.[tp] || '')}">${typeLabel(tp)}</button>`).join('')}</div>
    <textarea maxlength="${NOTE_MAX}" rows="1" placeholder="Optional comment… (Ctrl+Enter to submit)">${esc(note)}</textarea>
    <div class="vf-actions">
      <button data-act="submit" class="primary"${selT ? '' : ' disabled'}>${mine ? 'Save changes' : 'Add vote'}</button>
      ${mine ? '<button data-act="cancel">Cancel</button>' : ''}
    </div></div>`;
}

function card(t, c){
  const pk = pkOf(t.code, c.elsst_id);
  const hv = humanVotes(t.code, c.elsst_id);
  const rid = me();
  const mine = rid ? hv.find(v => v.rid === rid) : null;
  const n = hv.length;
  const rbadge = n
    ? `<span class="rbadge rb-yes${n > 1 ? ' multi' : ''}" title="${n} human reviewer${n > 1 ? 's have' : ' has'} voted on this link">${n} reviewer${n > 1 ? 's' : ''}</span>`
    : `<span class="rbadge rb-no" title="No human votes yet">unreviewed</span>`;
  const hrej = n && hv.every(v => v.t === 'none');

  const p1badge = c.phase1_tier === 'exact'
    ? ` <span class="badge b-phase1exact" title="Also an exact label match (Phase 1) — verify, exact matches are sometimes false positives">exact-label</span>`
    : c.phase1_tier === 'stem'
    ? ` <span class="badge b-phase1stem" title="Also a stemmed label match (Phase 1) — heuristic, more false-positive prone">stem-label</span>`
    : '';
  const defTxt = c.elsst_def
    ? `<div class="field"><span class="label">ELSST definition</span><div>${esc(c.elsst_def)}</div></div>`
    : `<div class="field empty">No ELSST definition — follow the link for context.</div>`;
  const ctx = CTX[c.elsst_id] || { asc: [], narr: [] };
  const cbits = [];
  if (ctx.asc && ctx.asc.length)   cbits.push(`<span class="label">Broader</span>${ctx.asc.map(esc).join('<span class="hsep">›</span>')}`);
  if (ctx.narr && ctx.narr.length) cbits.push(`<span class="label">Narrower</span>${ctx.narr.map(esc).join(', ')}`);
  const hier = cbits.length ? `<div class="candctx">${cbits.join('<br>')}</div>` : '';
  const xref = (XREF[c.elsst_id] || []).filter(p => p.code !== t.code);
  // Generic ELSST concepts can be matched to 100+ terms; show the first few
  // and fold the rest so the votes stay near the top of the card.
  const XREF_SHOW = 8;
  const xItem = p => `<a class="plink" data-code="${esc(p.code)}">${esc(p.label)}</a> <span class="badge b-${esc(p.match_type)}">${esc(p.match_type)}</span>`;
  const xrefHtml = xref.length
    ? `<div class="partners">ℹ gpt-4o also matched this ELSST concept to ${xref.length} other OntoPop term${xref.length > 1 ? 's' : ''}: ${
        xref.slice(0, XREF_SHOW).map(xItem).join(' &nbsp; ')}${
        xref.length > XREF_SHOW
          ? ` <details class="xmore"><summary>show ${xref.length - XREF_SHOW} more</summary>${xref.slice(XREF_SHOW).map(xItem).join(' &nbsp; ')}</details>`
          : ''}</div>` : '';

  const votes = [voteRow({ t: c.match_type || 'none', n: c.rationale }, { model: true })]
    .concat(hv.map(v => voteRow(v, { mine: v.rid === rid })));

  return `<div class="cand${hrej ? ' hrej' : ''}" data-pk="${esc(pk)}" data-eid="${esc(c.elsst_id)}">
    <div class="cand-head">
      <h3><a href="${esc(c.elsst_id)}" target="_blank" rel="noopener">${esc(c.elsst_label)} ↗</a></h3>
      ${rbadge}
    </div>
    <div class="meta">JW ${c.jw_sim == null ? '—' : c.jw_sim.toFixed(3)}
      &nbsp;·&nbsp; cosine ${c.cos_sim == null ? '—' : c.cos_sim.toFixed(3)}
      &nbsp;·&nbsp; ${esc(c.provenance)}${p1badge}</div>
    ${hier}${xrefHtml}${defTxt}
    <div class="votes"><span class="label">Votes</span>${votes.join('')}</div>
    ${voteForm(pk, mine)}
  </div>`;
}

function renderMain(){
  const wrap = $('#wrap');
  if (!cur) { wrap.innerHTML = '<div class="term empty">Select a term in the hierarchy.</div>'; return; }
  const t = DATA[CODE_INDEX[cur]];

  // Preserve an in-progress comment's focus/caret across re-renders (remote
  // votes arriving re-render the page while someone may be typing).
  const ae = document.activeElement;
  let focus = null;
  if (ae && ae.matches('.vform textarea')) {
    focus = { pk: ae.closest('.cand').dataset.pk, s: ae.selectionStart, e: ae.selectionEnd };
  }
  const coldEl = wrap.querySelector('details.cold');
  if (coldEl) coldOpen = coldEl.open;

  const items = t.candidates.map(c => {
    const pk = pkOf(t.code, c.elsst_id);
    return { c, pk, hidden: linkHidden(pk, humanVotes(t.code, c.elsst_id)) };
  });
  const shown = items.filter(x => !x.hidden);
  const hot  = shown.filter(x => isProposal(x.c));
  const cold = shown.filter(x => !isProposal(x.c));
  const nHidden = items.length - shown.length;

  const hlink = (list, sep) => list.map(p =>
    p.code != null && CODE_INDEX[p.code] != null
      ? `<a class="plink" data-code="${esc(p.code)}">${esc(p.label)}</a>`
      : `<span>${esc(p.label)}</span>`).join(sep);
  const ontoHier =
    (t.asc && t.asc.length ? `<div class="field"><span class="label">Broader (OntoPop, nearest first)</span>
        <div class="hier">${hlink(t.asc, '<span class="hsep">›</span>')}</div></div>` : '') +
    (t.chl && t.chl.length ? `<div class="field"><span class="label">Narrower (OntoPop)</span>
        <div class="hier">${hlink(t.chl, ', ')}</div></div>` : '');
  const s = TSTATS[t.code];

  const nProp = items.filter(x => isProposal(x.c)).length;
  wrap.innerHTML = `
    <div class="term">
      <div class="code">${esc(t.code)}</div>
      <h2>${esc(t.label)}</h2>
      <div class="field"><span class="label">OntoPop gloss (term-specific)</span>
        <div class="gloss">${esc(t.gloss)}</div></div>
      <details><summary>Show full definedInContext paragraph</summary>
        <div class="context">${esc(t.context)}</div></details>
      ${ontoHier}
      <div class="termstat">${s.total} candidate links · ${s.rev} reviewed by at least one human ·
        ${s.propRev} of ${s.prop} gpt-4o proposals reviewed</div>
    </div>
    ${nHidden ? `<div class="hidden-note">${nHidden} link${nHidden > 1 ? 's' : ''} hidden by your view options (top right).</div>` : ''}
    ${hot.length ? hot.map(x => card(t, x.c)).join('')
      : nProp ? '' : '<div class="cand empty">gpt-4o rated every candidate “none”. Check the rejected list below.</div>'}
    ${cold.length ? `<details class="cold"${coldOpen ? ' open' : ''}><summary>Show ${cold.length} candidate${cold.length > 1 ? 's' : ''} gpt-4o rejected (“none”)</summary>
        ${cold.map(x => card(t, x.c)).join('')}</details>` : ''}`;

  if (focus) {
    const ta = wrap.querySelector(`.cand[data-pk="${CSS.escape(focus.pk)}"] .vform textarea`);
    if (ta) { ta.focus({ preventScroll: true }); ta.setSelectionRange(focus.s, focus.e); }
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Interaction
// ════════════════════════════════════════════════════════════════════════════
function toast(msg, isErr = false){
  const el = document.createElement('div');
  el.className = 'toast' + (isErr ? ' err' : '');
  el.textContent = msg;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), isErr ? 6000 : 2500);
}

// Expand the ancestors along one path (nearest-first parents, lowest code
// first) so the term is visible in the tree.
function reveal(code){
  const seen = new Set([code]);
  let p = PARENTS[code]?.[0];
  while (p && !seen.has(p)) { EXP.add(p); seen.add(p); p = PARENTS[p]?.[0]; }
}

function show(code, { scrollTop = true } = {}){
  if (!(code in CODE_INDEX)) return;
  if (code !== cur) { STICKY.clear(); coldOpen = false; }
  cur = code;
  prefs.lastCode = code;
  computeStats(); computeVisibility();
  if (!SUB[code]) { prefs.filter = 'all'; }   // off-filter jump (search, link)
  reveal(code);
  savePrefs();
  renderAll({ scrollTree: true });
  if (scrollTop) window.scrollTo(0, 0);
}
function go(code){
  if (location.hash.slice(1) === code) show(code);
  else location.hash = code;                  // → hashchange → show()
}
window.addEventListener('hashchange', () => show(decodeURIComponent(location.hash.slice(1))));

// ── Tree clicks ─────────────────────────────────────────────────────────────
$('#tree').addEventListener('click', e => {
  const row = e.target.closest('.tn'); if (!row) return;
  const code = row.dataset.code;
  if (e.target.closest('[data-act="toggle"]') && CHILDREN[code].length) {
    EXP.has(code) ? EXP.delete(code) : EXP.add(code);
    savePrefs(); renderTree();
    return;
  }
  if (CHILDREN[code].length && !EXP.has(code)) EXP.add(code);   // drill in
  go(code);
});
$('#collapseAll').onclick = () => {
  EXP.clear(); if (cur) reveal(cur);
  savePrefs(); renderTree(true);
};
$('#expandMatches').onclick = () => {
  for (const t of DATA) if (MATCH[t.code]) reveal(t.code);
  savePrefs(); renderTree(true);
};

// ── Filter & view options ───────────────────────────────────────────────────
$('#filter').innerHTML = FILTERS.map(f => `<option value="${f[0]}">${esc(f[1])}</option>`).join('');
$('#filter').onchange = e => { prefs.filter = e.target.value; savePrefs(); renderAll(); };
$('#hideReviewed').checked = prefs.hideReviewed;
$('#hideRejected').checked = prefs.hideRejected;
$('#hideReviewed').onchange = e => { prefs.hideReviewed = e.target.checked; savePrefs(); renderMain(); };
$('#hideRejected').onchange = e => { prefs.hideRejected = e.target.checked; savePrefs(); renderMain(); };

// ── Voting ──────────────────────────────────────────────────────────────────
function candOf(cardEl){
  const t = DATA[CODE_INDEX[cur]];
  const c = t.candidates.find(x => x.elsst_id === cardEl.dataset.eid);
  const rid = me();
  const mine = rid ? humanVotes(t.code, c.elsst_id).find(v => v.rid === rid) : null;
  return { t, c, pk: cardEl.dataset.pk, rid, mine };
}

function submitVote(cardEl){
  const { t, c, pk, rid, mine } = candOf(cardEl);
  if (!rid) { openWho(); return; }
  const ta = cardEl.querySelector('.vform textarea');
  const type = DRAFTS[pk]?.t ?? mine?.t;
  if (!type) { toast('Pick a match type first.'); return; }
  const note = (ta ? ta.value : '').trim().slice(0, NOTE_MAX);
  delete DRAFTS[pk];
  STICKY.add(pk);
  STORE.setVote(t.code, c.elsst_id, rid, type, note, !mine);
  renderAll();
}

$('#wrap').addEventListener('click', e => {
  const pl = e.target.closest('.plink');
  if (pl) { go(pl.dataset.code); return; }
  const btn = e.target.closest('[data-act]'); if (!btn) return;
  const act = btn.dataset.act;
  if (act === 'signin') { openWho(); return; }
  const cardEl = btn.closest('.cand'); if (!cardEl) return;
  const { t, c, pk, rid, mine } = candOf(cardEl);

  if (act === 'pick') {
    const ta = cardEl.querySelector('.vform textarea');
    DRAFTS[pk] = { ...(DRAFTS[pk] || { editing: !!mine }), t: btn.dataset.v, n: ta ? ta.value : '' };
    cardEl.querySelectorAll('.decide button').forEach(b => b.classList.toggle('sel', b === btn));
    cardEl.querySelector('[data-act="submit"]').disabled = false;
  } else if (act === 'submit') {
    submitVote(cardEl);
  } else if (act === 'cancel') {
    delete DRAFTS[pk]; renderMain();
  } else if (act === 'edit' && mine) {
    DRAFTS[pk] = { t: mine.t, n: mine.n, editing: true };
    renderMain();
    const ta = $('#wrap').querySelector(`.cand[data-pk="${CSS.escape(pk)}"] .vform textarea`);
    if (ta) { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); }
  } else if (act === 'delete' && mine) {
    if (btn.dataset.armed) {
      delete DRAFTS[pk];
      STORE.deleteVote(t.code, c.elsst_id, rid);
      renderAll();
    } else {                                  // two-step confirm, no browser dialog
      btn.dataset.armed = '1'; btn.textContent = 'confirm delete?';
      setTimeout(() => { if (btn.isConnected) { delete btn.dataset.armed; btn.textContent = 'delete'; } }, 4000);
    }
  }
});
$('#wrap').addEventListener('input', e => {
  if (!e.target.matches('.vform textarea')) return;
  const cardEl = e.target.closest('.cand');
  const { pk, mine } = candOf(cardEl);
  DRAFTS[pk] = { ...(DRAFTS[pk] || { editing: !!mine, t: mine?.t ?? null }), n: e.target.value };
});
$('#wrap').addEventListener('keydown', e => {
  if (e.key === 'Enter' && (e.ctrlKey || e.metaKey) && e.target.matches('.vform textarea')) {
    e.preventDefault();
    submitVote(e.target.closest('.cand'));
  }
});

// ── Reviewer profile dialog ─────────────────────────────────────────────────
const sortedReviewers = () => Object.entries(REVIEWERS)
  .sort((a, b) => (a[1].name || '').localeCompare(b[1].name || '', undefined, { sensitivity: 'base' }));
function fillWhoSelect(){
  const list = sortedReviewers();
  const sel = $('#whoSel'), keep = sel.value || prefs.reviewerId || '';
  sel.innerHTML = `<option value="">— select your profile —</option>` + list.map(([id, r]) =>
    `<option value="${esc(id)}">${esc(r.name)}${r.affiliation ? ' — ' + esc(r.affiliation) : ''}</option>`).join('');
  sel.value = REVIEWERS[keep] ? keep : '';
  $('#whoExisting').hidden = !list.length && reviewersLoaded;
  $('#whoUse').disabled = !sel.value;
}
function openWho(){
  fillWhoSelect();
  $('#whoWarn').hidden = true;
  $('#whoOut').hidden = !me();
  if (!$('#whoDlg').open) $('#whoDlg').showModal();
}
function useReviewer(id){
  prefs.reviewerId = id; savePrefs();
  $('#whoDlg').close();
  for (const k in DRAFTS) delete DRAFTS[k];
  renderAll();
}
$('#whoBtn').onclick = openWho;
$('#whoSel').onchange = () => { $('#whoUse').disabled = !$('#whoSel').value; };
$('#whoUse').onclick = () => { const v = $('#whoSel').value; if (v) useReviewer(v); };
$('#whoLater').onclick = () => $('#whoDlg').close();
$('#whoOut').onclick = () => { prefs.reviewerId = null; savePrefs(); $('#whoDlg').close(); renderAll(); };
$('#whoCreate').onclick = () => {
  const name = $('#whoName').value.trim().replace(/\s+/g, ' ');
  const affiliation = $('#whoAff').value.trim().replace(/\s+/g, ' ');
  const warn = msg => { $('#whoWarn').textContent = msg; $('#whoWarn').hidden = false; };
  if (!name || !affiliation) return warn('Please enter both your name and your institutional affiliation.');
  const norm = s => s.toLowerCase();
  const dup = sortedReviewers().find(([, r]) => norm(r.name || '') === norm(name) && norm(r.affiliation || '') === norm(affiliation));
  if (dup) {
    $('#whoSel').value = dup[0]; $('#whoUse').disabled = false;
    return warn('A profile with this name and affiliation already exists — it is selected above; click “Continue as this reviewer”.');
  }
  const id = STORE.addReviewer({ name, affiliation });
  REVIEWERS[id] = REVIEWERS[id] || { name, affiliation, created: Date.now() };
  $('#whoName').value = ''; $('#whoAff').value = '';
  useReviewer(id);
  toast(`Welcome, ${name}!`);
};
$('#whoDlg').addEventListener('keydown', e => {
  if (e.key === 'Enter' && (e.target === $('#whoName') || e.target === $('#whoAff'))) {
    e.preventDefault(); $('#whoCreate').click();
  }
});

// ── Search ──────────────────────────────────────────────────────────────────
// Across OntoPop labels/codes/glosses, definedInContext, and ELSST candidate
// labels. Lower-cased fields are stored once so input events stay cheap.
let INDEX = [], selResult = -1;
function buildIndex(){
  INDEX = DATA.map((t, i) => ({
    i,
    label_lc:   t.label.toLowerCase(),
    code_lc:    t.code.toLowerCase(),
    gloss_lc:   (t.gloss || '').toLowerCase(),
    context_lc: (t.context || '').toLowerCase(),
    cands:      t.candidates.map(c => ({ lc: (c.elsst_label || '').toLowerCase(), label: c.elsst_label })),
  }));
}
function runSearch(q){
  q = q.trim().toLowerCase();
  if (!q) return [];
  // A digit-leading query like "113" or "113-1" is a code search.
  const codeOnly = /^\d+(-\w*)?$/.test(q);
  const out = [];
  for (const e of INDEX) {
    let score = 0, hint = '';
    if (codeOnly) {
      if (e.code_lc === q)            { score = 100; hint = 'exact code match'; }
      else if (e.code_lc.includes(q)) { score =  90; hint = 'in code'; }
    } else if (e.label_lc === q)      { score = 100; hint = 'exact label match'; }
    else if (e.label_lc.includes(q))  { score =  80; hint = 'in label'; }
    else if (e.code_lc.includes(q))   { score =  70; hint = 'in code'; }
    else {
      const cm = e.cands.find(c => c.lc.includes(q));
      if (cm)                           { score = 60; hint = 'candidate: ' + cm.label; }
      else if (e.gloss_lc.includes(q))  { score = 40; hint = 'in term gloss'; }
      else if (e.context_lc.includes(q)){ score = 20; hint = 'in definedInContext'; }
    }
    if (score) out.push({ i: e.i, score, hint });
  }
  out.sort((a, b) => b.score - a.score || a.i - b.i);
  return out.slice(0, 30);
}
function hl(s, q){
  if (!q) return esc(s);
  const i = s.toLowerCase().indexOf(q.toLowerCase());
  if (i < 0) return esc(s);
  return esc(s.slice(0, i)) + '<mark>' + esc(s.slice(i, i + q.length)) + '</mark>' + esc(s.slice(i + q.length));
}
function renderResults(items, q){
  const box = $('#results');
  q = q.trim();
  if (!items.length) { box.hidden = true; box.innerHTML = ''; selResult = -1; return; }
  selResult = 0;
  box.innerHTML = items.map((r, k) => {
    const t = DATA[r.i];
    return `<div class="result${k === 0 ? ' sel' : ''}" data-i="${r.i}">
      <div><b>${hl(t.label, q)}</b> <span class="hint">${esc(t.code)}</span></div>
      <div class="hint">${r.hint.startsWith('candidate: ') ? 'candidate: ' + hl(r.hint.slice(11), q) : esc(r.hint)}</div></div>`;
  }).join('');
  box.hidden = false;
  box.querySelectorAll('.result').forEach((el, k) => {
    el.onclick = () => { const i = +el.dataset.i; closeResults(); go(DATA[i].code); };
    el.onmouseenter = () => {
      box.querySelectorAll('.result').forEach(x => x.classList.remove('sel'));
      el.classList.add('sel'); selResult = k;
    };
  });
}
function closeResults(){
  const box = $('#results');
  box.hidden = true; box.innerHTML = '';
  $('#search').value = ''; selResult = -1;
}
const searchEl = $('#search');
searchEl.addEventListener('input', e => renderResults(runSearch(e.target.value), e.target.value));
searchEl.addEventListener('keydown', e => {
  const box = $('#results');
  if (e.key === 'Escape') { closeResults(); searchEl.blur(); return; }
  if (box.hidden) return;
  const items = [...box.children];
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    selResult = e.key === 'ArrowDown' ? Math.min(selResult + 1, items.length - 1) : Math.max(selResult - 1, 0);
    items.forEach((x, k) => x.classList.toggle('sel', k === selResult));
    items[selResult].scrollIntoView({ block: 'nearest' });
  } else if (e.key === 'Enter' && selResult >= 0) {
    e.preventDefault();
    const i = +items[selResult].dataset.i;
    closeResults(); go(DATA[i].code);
  }
});
document.addEventListener('click', e => { if (!e.target.closest('.search')) $('#results').hidden = true; });
document.addEventListener('keydown', e => {
  if (e.target.closest('input, textarea, select, dialog')) return;
  if (e.key === '/') { e.preventDefault(); searchEl.focus(); }
});

// Keep the sticky sidebar flush under the header, which can wrap.
function setHeadOffset(){
  document.documentElement.style.setProperty('--head', $('header').offsetHeight + 'px');
}
new ResizeObserver(setHeadOffset).observe($('header'));

// ════════════════════════════════════════════════════════════════════════════
// Boot
// ════════════════════════════════════════════════════════════════════════════
function buildHierarchy(){
  DATA.forEach((t, i) => { CODE_INDEX[t.code] = i; CHILDREN[t.code] = []; PARENTS[t.code] = []; });
  for (const t of DATA) {
    const kids = [...new Set((t.chl || []).map(p => p.code)
      .filter(c => c != null && c in CODE_INDEX && c !== t.code))];
    kids.sort((a, b) => CODE_INDEX[a] - CODE_INDEX[b]);
    CHILDREN[t.code] = kids;
    for (const k of kids) PARENTS[k].push(t.code);
  }
  for (const code in PARENTS) PARENTS[code].sort((a, b) => CODE_INDEX[a] - CODE_INDEX[b]);
  ROOTS = DATA.map(t => t.code).filter(c => !PARENTS[c].length);
}

async function boot(){
  setHeadOffset();
  const params = new URLSearchParams(location.search);
  const [cfg, data] = await Promise.all([
    fetch('config.json', { cache: 'no-cache' }).then(r => r.ok ? r.json() : {}).catch(() => ({})),
    fetch('review.json').then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); }),
  ]);
  META = data.meta || {}; DATA = data.terms; CTX = data.elsst_ctx || {}; XREF = data.xref || {};
  $('#rulesBody').innerHTML = data.rules_html || '';
  buildHierarchy();
  buildIndex();

  const fb = Object.fromEntries(Object.entries(cfg.firebase || {}).filter(([, v]) => v));
  const useFirebase = fb.apiKey && fb.projectId && !params.has('local');
  try {
    STORE = useFirebase ? await makeFirebaseStore(fb, onStoreChange) : makeLocalStore(onStoreChange);
  } catch (err) {
    console.error(err);
    STORE = makeLocalStore(onStoreChange);
    toast('Could not reach the shared database — running in local demo mode.', true);
  }

  const start = decodeURIComponent(location.hash.slice(1));
  show(start in CODE_INDEX ? start : (prefs.lastCode in CODE_INDEX ? prefs.lastCode : ROOTS[0]),
       { scrollTop: false });
  setHeadOffset();
}

boot().catch(err => {
  console.error(err);
  $('#wrap').innerHTML = `<div class="term err">Could not load the review data (${esc(err.message)}).
    If you opened index.html directly from disk, serve the folder over HTTP instead — see REVIEW_SITE.md.</div>`;
});
