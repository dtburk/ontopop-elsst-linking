// OntoPop browser — read-only view of the OntoPop class hierarchy, every OWL
// property of each class, and the ELSST concepts gpt-4o matched to it, each
// linked to the CESSDA Data Catalogue. Data: browse.json (+ browse_ctx/<lang>.json
// for non-English context text), built by scripts/09_build_browse.R.

const PREFS_KEY = 'ontopop_browse_prefs_v1';
const TYPES = ['exactMatch', 'closeMatch', 'broadMatch', 'narrowMatch', 'relatedMatch'];
const LANG_NAMES = { ar:'Arabic', cs:'Czech', de:'German', en:'English', es:'Spanish', fr:'French',
  id:'Indonesian', it:'Italian', ja:'Japanese', ko:'Korean', ms:'Malay', ne:'Nepali', pl:'Polish',
  pt:'Portuguese', ru:'Russian', th:'Thai', vi:'Vietnamese', zh:'Chinese' };
const SRC_NAMES = { phase1:'exact string match', fuzzy:'fuzzy string match', semantic:'embedding similarity' };

const $ = s => document.querySelector(s);
const esc = s => (s == null ? '' : String(s)).replace(/[&<>"']/g,
  c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
const ONTO_NS = 'http://www.semanticweb.org/altergc/ontologies/2025/5/ontoPop#';
const elsstUrl  = u => 'https://elsst.cessda.eu/id/6/' + u;
// Same link ELSST shows under "Keyword search" for each concept.
const cessdaUrl = label => 'https://datacatalogue.cessda.eu/?keywords%5B0%5D=' +
  encodeURIComponent(label) + '&sortBy=cmmstudy_en';

let D = null;                 // browse.json
const CTX = {};               // lang -> {key -> text}
const XREF = {};              // elsst uuid -> [{code, t}]
const SEC_SIZE = {};          // section -> number of classes
let SEARCH = [];              // [{code, text, lang}]
let cur = null;

const prefs = (() => {
  const d = { lang:'en', open:[], off:[] };
  try { return Object.assign(d, JSON.parse(localStorage.getItem(PREFS_KEY)) || {}); } catch { return d; }
})();
const OPEN = new Set(prefs.open);     // expanded tree paths ("101-8/102-10/...")
const OFF  = new Set(prefs.off);      // match types hidden in the detail view
function savePrefs() {
  prefs.open = [...OPEN]; prefs.off = [...OFF];
  try { localStorage.setItem(PREFS_KEY, JSON.stringify(prefs)); } catch {}
}

// ── Load ─────────────────────────────────────────────────────────────────────
fetch('browse.json').then(r => {
  if (!r.ok) throw new Error(r.status + ' ' + r.statusText);
  return r.json();
}).then(init).catch(e => {
  $('#detail').innerHTML = `<p class="empty">Could not load browse.json (${esc(e.message)}).<br>
    Serve the docs/ folder over HTTP (e.g. <code>python -m http.server</code> inside docs/)
    rather than opening the file directly.</p>`;
});

function init(data) {
  D = data;
  CTX.en = D.ctx_en;
  for (const [code, c] of Object.entries(D.classes)) {
    const sec = code.split('-')[0];
    SEC_SIZE[sec] = (SEC_SIZE[sec] || 0) + 1;
    for (const m of c.matches) (XREF[m.u] ||= []).push({ code, t: m.t });
    SEARCH.push({ code, text: c.label, lang: '' });
    for (const [lg, vals] of Object.entries(c.pref || {}))
      for (const v of vals) if (v !== c.label) SEARCH.push({ code, text: v, lang: lg, kind: 'label' });
    for (const [lg, vals] of Object.entries(c.alt || {}))
      for (const v of vals) SEARCH.push({ code, text: v, lang: lg, kind: 'alt label' });
  }
  for (const s of SEARCH) s.norm = norm(s.text);
  if (!D.meta.langs.includes(prefs.lang)) prefs.lang = 'en';

  const m = D.meta;
  $('#hdr-sub').textContent = `${m.n_classes.toLocaleString()} classes · ` +
    `${m.n_matches.toLocaleString()} gpt-4o matches to ELSST`;
  renderTree();
  wireSearch();
  $('#collapse').onclick = () => { OPEN.clear(); savePrefs(); renderTree(); };
  $('#reveal').onclick = () => cur && reveal(cur);
  window.addEventListener('hashchange', fromHash);
  fromHash();
}

function fromHash() {
  const code = decodeURIComponent(location.hash.slice(1));
  if (code && D.classes[code]) { show(code); reveal(code, false); }
  else if (!cur) show(D.roots[0]);
}
const go = code => { if (location.hash.slice(1) !== code) location.hash = code; else show(code); };

// ── Tree (DAG: a class with several parents appears under each) ─────────────
const label = code => D.classes[code]?.label ?? code;
const sortCodes = arr => [...arr].sort((a, b) => {
  const [a1, a2] = a.split('-').map(Number), [b1, b2] = b.split('-').map(Number);
  return a1 - b1 || a2 - b2;
});
function bestType(c) {
  let best = 99;
  for (const m of c.matches) best = Math.min(best, TYPES.indexOf(m.t));
  return TYPES[best];
}

function renderTree() {
  const ul = document.createElement('ul');
  for (const r of sortCodes(D.roots)) ul.appendChild(nodeEl(r, r, new Set()));
  const tree = $('#tree');
  tree.replaceChildren(ul);
  markCurrent();
}

function nodeEl(code, path, seen) {
  const c = D.classes[code];
  const li = document.createElement('li');
  li.dataset.path = path;
  const kids = (c.children || []).filter(k => D.classes[k] && !seen.has(k));
  const row = document.createElement('div');
  row.className = 'node' + (c.deprecated ? ' dep' : '');
  row.dataset.code = code;
  const open = OPEN.has(path);
  const n = c.matches.length;
  const bt = n ? bestType(c) : null;
  row.innerHTML =
    `<button class="caret${kids.length ? '' : ' leaf'}" aria-label="${open ? 'Collapse' : 'Expand'}"` +
      ` aria-expanded="${open}">${open ? '▼' : '▶'}</button>` +
    `<span class="nlabel" title="${esc(c.label)} (${code})">${esc(c.label)}<span class="ncode">${code}</span></span>` +
    (n ? `<span class="nbadge t-${bt}" title="${n} gpt-4o match${n > 1 ? 'es' : ''}; strongest: ${bt}">${n}</span>` : '');
  li.appendChild(row);
  row.querySelector('.nlabel').onclick = () => go(code);
  if (kids.length) {
    row.querySelector('.caret').onclick = () => toggle(li, code, path, seen);
    if (open) li.appendChild(childList(code, path, seen));
  }
  return li;
}
function childList(code, path, seen) {
  const ul = document.createElement('ul');
  const s2 = new Set(seen).add(code);
  for (const k of sortCodes(D.classes[code].children.filter(k => D.classes[k] && !s2.has(k))))
    ul.appendChild(nodeEl(k, path + '/' + k, s2));
  return ul;
}
function toggle(li, code, path, seen) {
  const caret = li.querySelector(':scope > .node > .caret');
  if (OPEN.has(path)) {
    OPEN.delete(path);
    li.querySelector(':scope > ul')?.remove();
  } else {
    OPEN.add(path);
    li.appendChild(childList(code, path, seen));
    markCurrent();
  }
  const open = OPEN.has(path);
  caret.textContent = open ? '▼' : '▶';
  caret.setAttribute('aria-expanded', open);
  caret.setAttribute('aria-label', open ? 'Collapse' : 'Expand');
  savePrefs();
}
function markCurrent() {
  document.querySelectorAll('.node.cur').forEach(n => n.classList.remove('cur'));
  if (cur) document.querySelectorAll(`.node[data-code="${cur}"]`).forEach(n => n.classList.add('cur'));
}
// Path from a root down to `code`, following each class's first parent.
function firstPath(code) {
  const chain = [code]; const seen = new Set([code]);
  let c = code;
  while (D.classes[c]?.parents?.length) {
    const p = D.classes[c].parents.find(p => D.classes[p] && !seen.has(p));
    if (!p) break;
    chain.unshift(p); seen.add(p); c = p;
  }
  return chain;
}
function reveal(code, scroll = true) {
  const chain = firstPath(code);
  for (let i = 1; i < chain.length; i++) OPEN.add(chain.slice(0, i).join('/'));
  savePrefs(); renderTree();
  const el = document.querySelector(`#tree li[data-path="${CSS.escape(chain.join('/'))}"] > .node`);
  if (el) el.scrollIntoView({ block: scroll ? 'center' : 'nearest' });
}

// ── Search ───────────────────────────────────────────────────────────────────
function norm(s) { return String(s).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, ''); }
function wireSearch() {
  const q = $('#q'), box = $('#results');
  let hits = [], sel = 0;
  const close = () => { box.hidden = true; };
  const pick = i => { if (hits[i]) { go(hits[i].code); reveal(hits[i].code); q.value = ''; close(); q.blur(); } };
  q.addEventListener('input', () => {
    const t = norm(q.value.trim());
    if (!t) return close();
    const seen = new Set(); hits = [];
    const exactCode = D.classes[q.value.trim()] ? q.value.trim() : null;
    if (exactCode) { hits.push({ code: exactCode }); seen.add(exactCode); }
    // prefix matches first, then substring matches
    for (const pass of [s => s.norm.startsWith(t), s => s.norm.includes(t)])
      for (const s of SEARCH) {
        if (hits.length >= 60) break;
        if (!seen.has(s.code) && pass(s)) { seen.add(s.code); hits.push(s); }
      }
    sel = 0;
    box.innerHTML = hits.length ? hits.map((h, i) => {
      const c = D.classes[h.code];
      const via = h.lang ? `<div class="hit">${esc(h.kind)} (${esc(h.lang)}): ${esc(h.text)}</div>` : '';
      return `<div class="result${i === sel ? ' sel' : ''}" data-i="${i}">${esc(c.label)}
        <span class="ncode">${h.code}</span>${c.deprecated ? ' <span class="badge dep-badge">deprecated</span>' : ''}${via}</div>`;
    }).join('') : '<div class="result muted">No matching classes</div>';
    box.hidden = false;
  });
  q.addEventListener('keydown', e => {
    if (box.hidden) return;
    const items = box.querySelectorAll('.result[data-i]');
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      sel = Math.max(0, Math.min(items.length - 1, sel + (e.key === 'ArrowDown' ? 1 : -1)));
      items.forEach((el, i) => el.classList.toggle('sel', i === sel));
      items[sel]?.scrollIntoView({ block: 'nearest' });
    } else if (e.key === 'Enter') { e.preventDefault(); pick(sel); }
    else if (e.key === 'Escape') close();
  });
  box.addEventListener('mousedown', e => {
    const r = e.target.closest('.result[data-i]');
    if (r) { e.preventDefault(); pick(+r.dataset.i); }
  });
  q.addEventListener('blur', () => setTimeout(close, 100));
}

// ── Detail view ──────────────────────────────────────────────────────────────
const classLink = code => D.classes[code]
  ? `<a href="#${code}">${esc(label(code))}</a> <span class="ncode">${code}</span>`
  : `<span class="mono">${esc(code)}</span>`;
const fmtSim = x => x == null ? '—' : Number(x).toFixed(2);

function show(code) {
  cur = code;
  markCurrent();
  const c = D.classes[code];
  document.title = `${c.label} (${code}) · OntoPop Browser`;
  const sec = code.split('-')[0];
  const chain = firstPath(code).slice(0, -1);

  let h = `<div class="crumbs">${chain.length ? chain.map(p => `<a href="#${p}">${esc(label(p))}</a>`).join(' › ') + ' ›' : 'Root class'}</div>
    <div class="title"><h2>${esc(c.label)}</h2><span class="chip mono">${code}</span>
      ${c.deprecated ? '<span class="badge dep-badge">owl:deprecated</span>' : ''}</div>
    <div class="iri mono">${esc(ONTO_NS + code)}</div>`;

  // Overview
  h += `<section class="card"><h3>Overview</h3><dl class="kv">`;
  if (c.gloss_llm) h += `<dt>Gloss (LLM)</dt><dd>${esc(c.gloss_llm)} <span class="muted small">— generated by the pipeline for matching</span></dd>`;
  if (c.gloss_en)  h += `<dt>Gloss (extracted)</dt><dd class="ctx gl">${fmtCtx(c.gloss_en, code)} <span class="muted small">— note for ${code} in the English context text</span></dd>`;
  h += `<dt>Parents <span class="small">(rdfs:subClassOf)</span></dt><dd class="links">${c.parents.length ? c.parents.map(classLink).join(' ') : '<span class="muted">none (root)</span>'}</dd>`;
  h += `<dt>Children</dt><dd class="links">${c.children.length ? sortCodes(c.children).map(classLink).join(' ') : '<span class="muted">none</span>'}</dd>`;
  if (c.restr.length) h += `<dt>Restrictions</dt><dd>${c.restr.map(r =>
      `<div><span class="mono">${esc(r.p)}</span> <em>${r.k}</em> ${classLink(r.t)}</div>`).join('')}</dd>`;
  h += `<dt>Section</dt><dd>${sec} <span class="muted">(${SEC_SIZE[sec]} classes)</span></dd>`;
  h += `</dl></section>`;

  h += matchesHtml(c);
  h += labelsHtml(c);
  h += `<section class="card" id="ctx-card"></section>`;

  if (c.other?.length) h += `<section class="card"><h3>Other properties</h3><dl class="kv">${c.other.map(o =>
      `<dt class="mono">${esc(o.p)}${o.l ? ` @${esc(o.l)}` : ''}</dt><dd>${esc(o.v)}</dd>`).join('')}</dl></section>`;

  const m = D.meta;
  h += `<footer>Source: <span class="mono">${esc(m.source)}</span> · ontology <span class="mono">${esc(m.version || m.ontology)}</span>.
    Matches: Phase 4 gpt-4o adjudication (candidates rejected as “none” are not shown).
    CESSDA dataset counts: exact keyword filter on the English catalogue, snapshot of ${esc(m.cessda_fetched)};
    follow a link for the live figure. Built ${esc(m.built)}.</footer>`;

  const det = $('#detail');
  det.innerHTML = h;
  det.scrollTop = 0;
  wireMatchFilters(c);
  renderCtx(c);
}

function matchesHtml(c) {
  const by = {}; for (const m of c.matches) (by[m.t] ||= []).push(m);
  const n = c.matches.length;
  let h = `<section class="card" id="matches"><h3>ELSST matches by gpt-4o
    <span class="count">${n ? `${n} concept${n > 1 ? 's' : ''}` : ''}</span>
    ${n ? `<span class="filters">${TYPES.filter(t => by[t]).map(t =>
      `<button class="badge t-${t}${OFF.has(t) ? ' off' : ''}" data-t="${t}" title="Show/hide ${t}">${t} ${by[t].length}</button>`).join('')}</span>` : ''}
    </h3>`;
  if (!n) return h + `<p class="muted">gpt-4o did not match any ELSST candidate to this class.</p></section>`;
  for (const t of TYPES) {
    if (!by[t]) continue;
    h += `<div class="typegroup" data-t="${t}"${OFF.has(t) ? ' hidden' : ''}>`;
    for (const m of by[t]) h += matchHtml(m);
    h += `</div>`;
  }
  return h + `</section>`;
}

function matchHtml(m) {
  const e = D.elsst[m.u] || { label: m.u };
  const cnt = e.n == null ? 'Search' :
    `<span class="n">${e.n.toLocaleString()}</span> dataset${e.n === 1 ? '' : 's'}`;
  const asc = (e.asc || []).slice().reverse();
  const others = (XREF[m.u] || []).filter(x => x.code !== cur);
  const src = (m.src || '').split('+').map(s => SRC_NAMES[s] || s).join(', ');
  return `<div class="match">
    <div class="mt"><span class="badge t-${m.t}">${m.t}</span></div>
    <div>
      <div class="head">
        <a class="elabel" href="${elsstUrl(m.u)}" target="_blank" rel="noopener" title="Open in ELSST">${esc(e.label)}</a>
        <a class="cessda" href="${cessdaUrl(e.label)}" target="_blank" rel="noopener"
           title="Search for '${esc(e.label)}' in CESSDA Data Catalogue">${cnt} in CESSDA Data Catalogue ↗</a>
      </div>
      ${e.def ? `<p class="def">${esc(e.def)}</p>` : ''}
      ${asc.length ? `<div class="meta">Broader: ${asc.map(esc).join(' › ')}</div>` : ''}
      ${e.alt?.length ? `<div class="meta">Alt labels: ${e.alt.map(esc).join('; ')}</div>` : ''}
      ${e.narr?.length ? `<div class="meta">Narrower: ${e.narr.map(esc).join('; ')}</div>` : ''}
      ${m.why ? `<p class="why">gpt-4o: ${esc(m.why)}</p>` : ''}
      <div class="meta">Candidate from ${esc(src)} · string sim ${fmtSim(m.jw)} · cosine ${fmtSim(m.cos)}</div>
      ${others.length ? `<details><summary>Also matched to ${others.length} other OntoPop class${others.length > 1 ? 'es' : ''}</summary>
        ${others.map(x => `<div><span class="badge t-${x.t}">${x.t}</span> ${classLink(x.code)}</div>`).join('')}</details>` : ''}
    </div></div>`;
}

function wireMatchFilters() {
  document.querySelectorAll('#matches .filters button').forEach(b => b.onclick = () => {
    const t = b.dataset.t;
    OFF.has(t) ? OFF.delete(t) : OFF.add(t);
    b.classList.toggle('off', OFF.has(t));
    document.querySelector(`#matches .typegroup[data-t="${t}"]`).hidden = OFF.has(t);
    savePrefs();
  });
}

function labelsHtml(c) {
  const langs = [...new Set([...Object.keys(c.pref || {}), ...Object.keys(c.alt || {})])]
    .sort((a, b) => (a === 'en' ? -1 : b === 'en' ? 1 : a.localeCompare(b)));
  let h = `<section class="card"><h3>Labels <span class="count">${langs.length} language${langs.length === 1 ? '' : 's'}</span></h3>
    <table class="labels"><thead><tr><th>Lang</th><th>skos:prefLabel</th><th>skos:altLabel</th></tr></thead><tbody>`;
  if (c.rdfs?.length) h += `<tr><td class="lg">—</td><td colspan="2">${c.rdfs.map(esc).join('; ')} <span class="muted small">rdfs:label</span></td></tr>`;
  for (const lg of langs)
    h += `<tr><td class="lg" title="${LANG_NAMES[lg] || lg}">${lg}</td>
      <td dir="auto">${(c.pref?.[lg] || []).map(esc).join('; ')}</td>
      <td class="alt" dir="auto">${(c.alt?.[lg] || []).map(esc).join('; ')}</td></tr>`;
  return h + `</tbody></table></section>`;
}

// ── Context text (ontoPop:definedInContext) ──────────────────────────────────
async function renderCtx(c) {
  const card = $('#ctx-card');
  const langs = Object.keys(c.ctx || {}).sort((a, b) => (a === 'en' ? -1 : b === 'en' ? 1 : a.localeCompare(b)));
  if (!langs.length) { card.remove(); return; }
  const lang = langs.includes(prefs.lang) ? prefs.lang : langs[0];
  const sec = c.code.split('-')[0];
  card.innerHTML = `<h3>Defined in context <span class="ctx-tools">
      <select id="ctx-lang" aria-label="Language">${langs.map(l =>
        `<option value="${l}"${l === lang ? ' selected' : ''}>${LANG_NAMES[l] || l} (${l})</option>`).join('')}</select>
      <span class="muted small">ontoPop:definedInContext — the dictionary paragraph shared by all ${SEC_SIZE[sec]} classes in section ${sec};
      notes for ${c.code} highlighted</span></span></h3><div class="ctx" id="ctx-body" dir="auto"><p class="muted">Loading…</p></div>`;
  $('#ctx-lang').onchange = e => { prefs.lang = e.target.value; savePrefs(); renderCtx(c); };
  const body = $('#ctx-body');
  try {
    if (!CTX[lang]) {
      const r = await fetch(`browse_ctx/${lang}.json`);
      if (!r.ok) throw new Error(r.status);
      CTX[lang] = await r.json();
    }
  } catch (e) { body.innerHTML = `<p class="muted">Could not load ${lang} text (${esc(e.message)}).</p>`; return; }
  if (cur !== c.code) return;           // user moved on while loading
  body.innerHTML = fmtCtx(CTX[lang][c.ctx[lang]] || '', c.code);
  if (c.idb?.[lang]) body.insertAdjacentHTML('beforeend',
    `<h4>rdfs:isDefinedBy (differs from the above)</h4>${fmtCtx(CTX[lang][c.idb[lang]] || '', c.code)}`);
}

// Render the dictionary paragraph: **bold**, *italic*, " - **101-4** …" note
// lines as a list, class codes as links. The source text carries a few
// literal HTML fragments (<br />, <sup>) and &quot; entities.
const fmtInline = text => esc(text)
  .replace(/&amp;(quot|amp|lt|gt|#39);/g, '&$1;')
  .replace(/&lt;br\s*\/?&gt;/gi, '<br>')
  .replace(/&lt;(\/?)sup&gt;/gi, '<$1sup>');
function fmtCtx(text, self) {
  let s = fmtInline(text);
  s = s.replace(/\b(\d{3})-(\d{1,2})(\*?)/g, (all, a, b, star) => {
    const code = `${a}-${b}`;
    if (!D.classes[code]) return all.replace('*', '&#42;');
    return `<a class="code${code === self ? ' self' : ''}" href="#${code}" title="${esc(label(code))}">${code}</a>${star ? '&#42;' : ''}`;
  });
  s = s.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>').replace(/\*([^*\n]+?)\*/g, '<em>$1</em>');
  const out = []; let list = [];
  const flush = () => { if (list.length) { out.push('<ul>' + list.join('') + '</ul>'); list = []; } };
  for (const line of s.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    if (/^-\s/.test(t)) {
      const isSelf = new RegExp(`^-\\s*(<strong>)?\\s*<a class="code self"`).test(t);
      list.push(`<li${isSelf ? ' class="self"' : ''}>${t.replace(/^-\s*/, '')}</li>`);
    } else { flush(); out.push(`<p>${t}</p>`); }
  }
  flush();
  return out.join('');
}
