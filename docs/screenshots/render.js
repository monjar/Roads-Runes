// Renders the design mockups in this folder. Usage: npm i playwright && npx playwright install chromium && node render.js
// These are HTML/CSS renders of the screens as designed (spec §4, §33, §40–47), not device captures.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const OUT = __dirname;
fs.mkdirSync(OUT, { recursive: true });

const C = { parchment: '#F7F0E0', deep: '#EBDEC7', moss: '#3D7049', rune: '#CC8C30', river: '#38789E', ember: '#C24A33', ink: '#1C1A17', sub: '#6B655C' };

const base = `
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { width: 393px; height: 852px; overflow: hidden; background: ${C.parchment}; color: ${C.ink}; font-family: -apple-system, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif; position: relative; }
  .serif { font-family: "New York", Georgia, "Times New Roman", serif; }
  .status { height: 54px; display: flex; justify-content: space-between; align-items: flex-end; padding: 0 28px 8px; font-size: 15px; font-weight: 600; }
  .home { position: absolute; bottom: 8px; left: 50%; transform: translateX(-50%); width: 134px; height: 5px; border-radius: 3px; background: ${C.ink}; opacity: .8; }
  .tabbar { position: absolute; bottom: 0; left: 0; right: 0; height: 84px; background: rgba(247,240,224,.96); border-top: 1px solid rgba(0,0,0,.08); display: flex; justify-content: space-around; padding-top: 10px; }
  .tab { display: flex; flex-direction: column; align-items: center; gap: 3px; font-size: 10px; color: ${C.sub}; width: 70px; }
  .tab.active { color: ${C.moss}; font-weight: 600; }
  .tab .ico { width: 26px; height: 26px; border-radius: 7px; background: currentColor; opacity: .85; }
  .content { padding: 0 16px; }
  h1 { font-size: 30px; font-weight: 700; margin: 8px 0 2px; }
  h2 { font-size: 20px; font-weight: 600; margin: 18px 0 8px; }
  .muted { color: ${C.sub}; font-size: 13px; }
  .card { background: #fff; border-radius: 16px; padding: 14px; margin-bottom: 10px; box-shadow: 0 1px 2px rgba(0,0,0,.05); }
  .row { display: flex; align-items: center; justify-content: space-between; }
  .chip { font-size: 11px; font-weight: 700; padding: 4px 9px; border-radius: 999px; }
  .chip.EASY { background: rgba(61,112,73,.18); color: ${C.moss}; }
  .chip.MODERATE { background: rgba(56,120,158,.18); color: ${C.river}; }
  .chip.HARD { background: rgba(204,140,48,.2); color: ${C.rune}; }
  .stats { display: flex; gap: 14px; margin-top: 10px; font-size: 12px; color: ${C.sub}; }
  .stats b { color: ${C.ink}; font-weight: 600; }
  .btn { display: block; text-align: center; background: ${C.moss}; color: #fff; font-weight: 600; font-size: 17px; padding: 14px; border-radius: 14px; }
  .btn.secondary { background: ${C.deep}; color: ${C.ink}; }
  .xpbar { height: 10px; border-radius: 6px; background: ${C.deep}; overflow: hidden; margin-top: 6px; }
  .xpbar i { display: block; height: 100%; background: linear-gradient(90deg, ${C.rune}, ${C.ember}); }
  .metric { display: flex; flex-direction: column; }
  .metric .l { font-size: 10px; font-weight: 700; letter-spacing: .06em; color: ${C.sub}; }
  .metric .v { font-size: 18px; font-weight: 600; font-variant-numeric: tabular-nums; }
  .surface { display: flex; height: 6px; border-radius: 3px; overflow: hidden; margin-top: 8px; }
  .obj { display: flex; align-items: center; gap: 10px; padding: 9px 0; border-bottom: 1px solid rgba(0,0,0,.06); font-size: 15px; }
  .obj .dot { width: 22px; height: 22px; border-radius: 50%; border: 2px solid ${C.sub}; flex: none; }
  .obj .dot.done { background: ${C.moss}; border-color: ${C.moss}; position: relative; }
  .obj .dot.done::after { content: ""; position: absolute; left: 6px; top: 2px; width: 6px; height: 11px; border: solid #fff; border-width: 0 2.5px 2.5px 0; transform: rotate(45deg); }
  .obj .dot.optional { border-style: dashed; }
</style>`;

function status(dark) {
  return `<div class="status" style="${dark ? 'color:#fff' : ''}"><span>9:41</span><span>●●●● ▲ ▮</span></div>`;
}
function tabbar(active) {
  const tabs = ['World', 'Quests', 'Journal', 'Character'];
  return `<div class="tabbar">${tabs.map(t => `<div class="tab ${t === active ? 'active' : ''}"><div class="ico"></div>${t}</div>`).join('')}</div>`;
}

// ---- Map SVG with fog of war ---------------------------------------------
function hexPath(cx, cy, r) {
  const pts = [];
  for (let i = 0; i < 6; i++) { const a = Math.PI / 180 * (60 * i + 30); pts.push(`${(cx + r * Math.cos(a)).toFixed(1)},${(cy + r * Math.sin(a)).toFixed(1)}`); }
  return `M${pts.join('L')}Z`;
}
function mapSVG(w, h, opts = {}) {
  const r = 22, dx = r * Math.sqrt(3), dy = r * 1.5;
  const px = opts.player || [190, 470];
  let hexes = '';
  for (let row = -1; row * dy < h + r; row++) {
    for (let col = -1; col * dx < w + dx; col++) {
      const cx = col * dx + (row % 2 ? dx / 2 : 0), cy = row * dy;
      const d = Math.hypot(cx - px[0], cy - px[1]);
      const seed = Math.abs(Math.sin(cx * 12.9898 + cy * 78.233)) ;
      let fill = 'rgba(20,16,12,.58)';
      if (d < 120) fill = 'none';
      else if (d < 190 && seed > 0.35) fill = 'none';
      else if (d < 260 && seed > 0.7) fill = 'rgba(20,16,12,.28)';
      // quest-revealed cells
      for (const q of opts.quests || []) { if (Math.hypot(cx - q[0], cy - q[1]) < 30) fill = 'rgba(20,16,12,.25)'; }
      if (opts.explored && d < 90) hexes += `<path d="${hexPath(cx, cy, r)}" fill="none" stroke="rgba(61,112,73,.45)" stroke-width="1"/>`;
      if (fill !== 'none') hexes += `<path d="${hexPath(cx, cy, r)}" fill="${fill}" stroke="rgba(247,240,224,.15)" stroke-width="1"/>`;
    }
  }
  const streets = [];
  for (let i = 0; i < 12; i++) streets.push(`<line x1="0" y1="${i * 78 + 20}" x2="${w}" y2="${i * 78 + 60}" />`);
  for (let i = 0; i < 8; i++) streets.push(`<line x1="${i * 62 + 10}" y1="0" x2="${i * 62 - 30}" y2="${h}" />`);
  const route = opts.route ? `<path d="${opts.route}" fill="none" stroke="${C.rune}" stroke-width="6" stroke-linecap="round" stroke-linejoin="round" opacity=".95"/>` : '';
  const markers = (opts.quests || []).map(q => `<g transform="translate(${q[0]},${q[1]})"><path d="M0,-26 C-12,-26 -14,-12 -14,-10 C-14,0 0,14 0,14 C0,14 14,0 14,-10 C14,-12 12,-26 0,-26Z" fill="${q[2] || C.rune}" stroke="#fff" stroke-width="2"/><circle r="4" cy="-11" fill="#fff"/></g>`).join('');
  const pois = (opts.pois || []).map(p => `<circle cx="${p[0]}" cy="${p[1]}" r="6" fill="${C.river}" stroke="#fff" stroke-width="2"/>`).join('');
  return `<svg width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" style="display:block">
    <rect width="${w}" height="${h}" fill="#EFE7D6"/>
    <path d="M-20,${h * .62} C120,${h * .5} 200,${h * .74} ${w + 20},${h * .58} L${w + 20},${h * .66} C200,${h * .82} 120,${h * .58} -20,${h * .70}Z" fill="#B7D2DE"/>
    <ellipse cx="${w * .78}" cy="${h * .28}" rx="70" ry="48" fill="#CFE0B8"/>
    <g stroke="#fff" stroke-width="3">${streets.join('')}</g>
    <g stroke="#E3D9C4" stroke-width="1">${streets.join('')}</g>
    ${route}${pois}
    ${hexes}
    ${markers}
    <g transform="translate(${px[0]},${px[1]})"><circle r="16" fill="rgba(56,120,158,.25)"/><circle r="8" fill="${C.river}" stroke="#fff" stroke-width="3"/></g>
  </svg>`;
}

const screens = {};

screens['01-onboarding-class'] = `
${status()}
<div class="content">
  <p class="muted" style="margin-top:8px">STEP 2 OF 3</p>
  <h1 class="serif">Choose your class</h1>
  <p class="muted" style="margin-bottom:16px">Your class shapes the quests the world offers you. You can change it later.</p>
  <div class="card" style="border:2px solid ${C.moss}">
    <div class="row"><b style="font-size:18px">Explorer</b><span class="chip EASY">SELECTED</span></div>
    <p class="muted" style="margin-top:6px">Rewards discovering new territory: new roads, neighbourhoods, trails, parks and viewpoints.</p>
    <div class="stats"><span>Trail Sense</span><span>Cartographer</span><span>Pathfinder</span></div>
  </div>
  ${[['Wizard', 'Hidden knowledge, puzzles and unusual locations.'], ['Warrior', 'Climbs, distance and demanding terrain. Never speed.'], ['Scribe', 'Document the world: photos, notes, community knowledge.']].map(([n, d]) => `
  <div class="card" style="opacity:.55"><div class="row"><b style="font-size:18px">${n}</b><span class="muted">🔒 Coming soon</span></div><p class="muted" style="margin-top:6px">${d}</p></div>`).join('')}
  <div style="position:absolute;left:16px;right:16px;bottom:44px"><a class="btn">Continue as Explorer</a></div>
</div>
<div class="home"></div>`;

const worldRoute = 'M190,470 C240,430 300,420 320,360 C340,300 300,250 250,240';
screens['02-world'] = `
<div style="position:absolute;inset:0">${mapSVG(393, 852, { quests: [[250, 240, C.rune], [90, 300, C.river], [320, 560, C.moss]], pois: [[140, 400], [300, 470]], explored: true })}</div>
<div style="position:absolute;top:0;left:0;right:0">${status()}</div>
<div style="position:absolute;top:60px;left:16px;right:16px;display:flex;gap:8px">
  <div class="card" style="margin:0;padding:8px 12px;flex:1;display:flex;justify-content:space-between;align-items:center"><span class="muted" style="font-size:12px">Rotherhithe</span><b style="color:${C.moss};font-size:13px">96 km new · 412 areas</b></div>
  <div class="card" style="margin:0;padding:8px 12px;font-weight:600">Adventure ▾</div>
</div>
<div style="position:absolute;left:0;right:0;bottom:84px;background:${C.parchment};border-radius:20px 20px 0 0;padding:10px 16px 8px;box-shadow:0 -4px 20px rgba(0,0,0,.15)">
  <div style="width:36px;height:5px;border-radius:3px;background:rgba(0,0,0,.2);margin:0 auto 10px"></div>
  <div class="row"><h2 style="margin:0">Nearby adventures</h2><span class="muted">3 quests</span></div>
  <div class="card" style="margin-top:10px;margin-bottom:8px">
    <div class="row"><b>Beyond the River</b><span class="chip MODERATE">MODERATE</span></div>
    <p class="muted" style="margin-top:4px">Cross to Deptford Creek and see what the far bank holds.</p>
    <div class="stats"><span><b>28 km</b></span><span><b>2 h</b></span><span><b>350 XP</b></span><span>62% new territory</span></div>
  </div>
  <div class="card" style="margin-bottom:0">
    <div class="row"><b>Three Shadows on the Map</b><span class="chip EASY">EASY</span></div>
    <div class="stats"><span><b>18 km</b></span><span><b>1 h 15</b></span><span><b>150 XP</b></span></div>
  </div>
</div>
${tabbar('World')}
<div class="home"></div>`;

screens['03-quests'] = `
${status()}
<div class="content">
  <h1 class="serif">Quests</h1>
  <h2>Active</h2>
  <div class="card" style="border-left:4px solid ${C.rune}">
    <div class="row"><b>The Forgotten Railway</b><span class="chip HARD">HARD</span></div>
    <p class="muted" style="margin-top:4px">2 of 3 objectives · next: Reach Old Station · 4.2 km</p>
    <div class="xpbar"><i style="width:66%"></i></div>
  </div>
  <h2>Nearby</h2>
  ${[['Beyond the River', 'MODERATE', '28 km', '2 h', '350 XP'], ['Three Shadows on the Map', 'EASY', '18 km', '1 h 15', '150 XP'], ['Coffee at the Frontier', 'EASY', '14 km', '1 h', '150 XP']].map(q => `
  <div class="card"><div class="row"><b>${q[0]}</b><span class="chip ${q[1]}">${q[1]}</span></div><div class="stats"><span><b>${q[2]}</b></span><span><b>${q[3]}</b></span><span><b>${q[4]}</b></span></div></div>`).join('')}
  <h2>Recommended for Explorers</h2>
  <div class="card"><div class="row"><b>Walking the Edge</b><span class="chip MODERATE">MODERATE</span></div><p class="muted" style="margin-top:4px">Push the frontier of your map in four places.</p></div>
</div>
${tabbar('Quests')}
<div class="home"></div>`;

screens['04-quest-detail'] = `
${status()}
<div class="content">
  <p class="muted" style="margin-top:6px">← Quests</p>
  <span class="chip MODERATE" style="display:inline-block;margin-top:10px">MODERATE · EXPLORER</span>
  <h1 class="serif">Beyond the River</h1>
  <p style="font-size:15px;line-height:1.4;margin:6px 0 10px">Water marks the edge of your map. Deptford Creek is on the other side. Cross to it and see what the far bank holds.</p>
  <div class="stats" style="margin-bottom:14px"><span><b>28 km</b> recommended</span><span><b>2 h</b></span><span><b>350 XP</b></span></div>
  <div class="card">
    <b>Objectives</b>
    <div class="obj"><div class="dot"></div><div>Reach Deptford Creek<div class="muted">within 100 m · 6.8 km away</div></div></div>
    <div class="obj"><div class="dot optional"></div><div>Ride 3 km of new roads on the way<div class="muted">optional · +25 XP</div></div></div>
    <div class="obj" style="border:0"><div class="dot"></div><div>Return home<div class="muted">within 300 m of your start</div></div></div>
  </div>
  <div class="card"><b>Rewards</b><div class="stats"><span><b>+350 XP</b> base</span><span>+ exploration</span><span>+ discoveries</span></div></div>
  <div style="height:120px">${mapSVG(361, 120, { player: [60, 90], quests: [[290, 40]] })}</div>
  <div style="position:absolute;left:16px;right:16px;bottom:100px;display:flex;gap:10px"><a class="btn secondary" style="flex:1">Accept</a><a class="btn" style="flex:2">Plan route</a></div>
</div>
${tabbar('Quests')}
<div class="home"></div>`;

function spark(seed) {
  let d = 'M0,30'; for (let i = 1; i <= 40; i++) { const y = 30 - 22 * Math.abs(Math.sin(i / 6 + seed)) * Math.abs(Math.cos(i / 11)); d += ` L${i * 8},${y.toFixed(1)}`; } return `<svg width="320" height="34"><path d="${d}" fill="none" stroke="${C.river}" stroke-width="2"/></svg>`;
}
function routeCard(label, sel, dist, time, climb, newT, cw, traffic, s, pois, seed) {
  return `<div class="card" style="${sel ? `border:2px solid ${C.moss}` : ''}">
    <div class="row"><b style="font-size:17px">${label}</b><span style="color:${sel ? C.moss : C.sub}">${sel ? '●' : '○'}</span></div>
    ${spark(seed)}
    <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:6px;margin-top:6px">
      <div class="metric"><span class="l">DISTANCE</span><span class="v">${dist}</span></div><div class="metric"><span class="l">TIME</span><span class="v">${time}</span></div><div class="metric"><span class="l">CLIMB</span><span class="v">${climb}</span></div>
      <div class="metric"><span class="l">NEW TERRITORY</span><span class="v">${newT}</span></div><div class="metric"><span class="l">CYCLEWAYS</span><span class="v">${cw}</span></div><div class="metric"><span class="l">TRAFFIC</span><span class="v">${traffic}</span></div>
    </div>
    <div class="surface"><i style="flex:${s[0]};background:rgba(28,26,23,.6)"></i><i style="flex:${s[1]};background:${C.rune}"></i><i style="flex:${s[2]};background:${C.moss}"></i></div>
    <p class="muted" style="margin-top:8px">${pois}</p></div>`;
}
screens['05-routes'] = `
${status()}
<div class="content">
  <p class="muted" style="margin-top:6px">← Beyond the River</p>
  <h1 class="serif">Choose a route</h1>
  <p class="muted" style="margin-bottom:10px">“around 25 km, quiet roads, a pub near the end” · Gravel bike</p>
  ${routeCard('Relaxed', false, '23.1 km', '1 h 30', '120 m', '48%', '61%', 'Low', [85, 12, 3], 'Thames Path · The Crown 19.4 km in · +3 min', 1)}
  ${routeCard('Adventure', true, '27.4 km', '1 h 50', '210 m', '71%', '44%', 'Low', [55, 35, 10], 'Stave Hill · Thames Path · The Crown 22.6 km in · +2 min', 2)}
  ${routeCard('Gravel', false, '26.0 km', '1 h 45', '180 m', '64%', '30%', 'Medium', [40, 52, 8], 'Deptford Creek · The Crown 21.1 km in · +4 min', 3)}
</div>
<div style="position:absolute;left:16px;right:16px;bottom:44px"><a class="btn">Download route & start ride</a></div>
<div class="home"></div>`;

screens['06-navigation'] = `
<div style="position:absolute;inset:0;background:#000"></div>
<div style="position:absolute;top:0;left:0;right:0">${status(true)}</div>
<div style="position:absolute;top:54px;left:0;right:0;height:230px;background:#000;color:#fff;padding:10px 20px;display:flex;flex-direction:column;justify-content:center">
  <div style="display:flex;align-items:center;gap:18px">
    <svg width="96" height="96" viewBox="0 0 96 96"><path d="M30,84 L30,40 Q30,26 44,26 L60,26" fill="none" stroke="#FFC733" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/><path d="M52,10 L74,26 L52,42Z" fill="#FFC733"/></svg>
    <div><div style="font-size:72px;font-weight:800;line-height:1;font-variant-numeric:tabular-nums">180 <span style="font-size:32px;font-weight:600">m</span></div><div style="font-size:22px;font-weight:600;letter-spacing:.08em;color:#FFC733;margin-top:4px">RIGHT</div></div>
  </div>
  <div style="font-size:28px;font-weight:600;margin-top:10px">Rotherhithe Street</div>
  <div style="font-size:14px;opacity:.6;margin-top:4px">then ↰ Left onto Mill Road · 620 m</div>
</div>
<div style="position:absolute;top:284px;left:0;right:0;height:380px">${mapSVG(393, 380, { player: [196, 250], route: 'M196,250 C210,190 260,170 300,120 C320,95 330,80 340,40', pois: [[300, 120]], quests: [[340, 40, C.rune]] })}</div>
<div style="position:absolute;top:664px;left:0;right:0;bottom:0;background:#111;color:#fff;padding:12px 20px">
  <div style="display:flex;align-items:center;gap:10px;font-size:15px;padding-bottom:10px;border-bottom:1px solid rgba(255,255,255,.12)"><span style="color:#FFC733">◎</span><span style="flex:1"><b>Reach Old Station</b> <span style="opacity:.6">· The Forgotten Railway</span></span><b style="font-variant-numeric:tabular-nums">1.4 km</b></div>
  <div style="display:flex;justify-content:space-around;padding-top:12px;text-align:center">
    ${[['12.6', 'KM'], ['48:12', 'TIME'], ['23', 'KM/H'], ['140', 'M CLIMB'], ['132', 'BPM']].map(m => `<div><div style="font-size:24px;font-weight:600;font-variant-numeric:tabular-nums">${m[0]}</div><div style="font-size:10px;font-weight:700;opacity:.55;letter-spacing:.06em">${m[1]}</div></div>`).join('')}
  </div>
  <div style="display:flex;gap:10px;margin-top:14px"><a class="btn secondary" style="flex:1;background:#2a2a2a;color:#fff;padding:10px">Pause</a><a class="btn" style="flex:1;background:${C.ember};padding:10px">End ride</a></div>
</div>`;

screens['07-adventure-complete'] = `
${status()}
<div class="content" style="text-align:center;padding-top:16px">
  <p style="font-size:12px;font-weight:800;letter-spacing:.25em;color:${C.rune}">ADVENTURE COMPLETE</p>
  <h1 class="serif" style="font-size:34px;margin-top:8px">The Forgotten Railway</h1>
  <p class="muted">Quest complete</p>
  <div style="font-size:64px;font-weight:800;color:${C.moss};margin:18px 0 12px">+420 XP</div>
  <div class="card" style="text-align:left">
    ${[['✦', '3 discoveries'], ['▦', '12.6 km new territory'], ['⬡', '34 new areas uncovered'], ['↑', 'Level 7 → 8', true], ['🔓', 'Cartographer available', true], ['♛', 'Title earned: Wanderer', true]].map(l => `<div style="display:flex;gap:12px;padding:6px 0;font-size:16px;${l[2] ? `color:${C.rune};font-weight:600` : ''}"><span style="width:20px;text-align:center">${l[0]}</span>${l[1]}</div>`).join('')}
  </div>
  <div class="card" style="text-align:left;font-size:13px">
    ${[['Quest completed', 385], ['Objective completed', 80], ['New area explored', 468], ['New road explored', 252], ['Discovery found', 130], ['Class bonus', 180]].map(l => `<div class="row" style="padding:3px 0"><span>${l[0]}</span><b>+${l[1]}</b></div>`).join('')}
    <div class="row" style="padding:6px 0 0;border-top:1px solid rgba(0,0,0,.08);margin-top:4px"><span class="muted">Capped per ride</span><b>+420</b></div>
  </div>
  <div style="display:flex;justify-content:space-around;margin:8px 0 16px">
    <div class="metric"><span class="l">RIDDEN</span><span class="v">32.4 km</span></div><div class="metric"><span class="l">CLIMBED</span><span class="v">340 m</span></div><div class="metric"><span class="l">TIME</span><span class="v">2 h 04</span></div>
  </div>
  <a class="btn">Back to the world</a>
</div>
<div class="home"></div>`;

screens['08-journal'] = `
${status()}
<div class="content">
  <h1 class="serif">Journal</h1>
  <div style="display:flex;gap:8px;margin:8px 0 12px">${['Adventures', 'Discoveries', 'World', 'Statistics'].map((t, i) => `<span class="chip" style="background:${i === 0 ? C.moss : C.deep};color:${i === 0 ? '#fff' : C.ink};padding:7px 12px;font-size:12px">${t}</span>`).join('')}</div>
  <div class="card" style="padding:0;overflow:hidden">
    <div style="height:120px">${mapSVG(361, 120, { player: [300, 60], route: 'M40,90 C120,30 200,100 300,60', explored: true })}</div>
    <div style="padding:12px 14px"><div class="row"><b>The Forgotten Railway</b><b style="color:${C.moss}">+420 XP</b></div><p class="muted" style="margin-top:3px">Sun 1 Jun · 32.4 km · 340 m · 3 discoveries · 12.6 km new</p></div>
  </div>
  <div class="card" style="padding:0;overflow:hidden">
    <div style="height:120px">${mapSVG(361, 120, { player: [80, 70], route: 'M80,70 C160,20 260,110 320,50', explored: true })}</div>
    <div style="padding:12px 14px"><div class="row"><b>Beyond the Water</b><b style="color:${C.moss}">+265 XP</b></div><p class="muted" style="margin-top:3px">Sat 24 May · 26.1 km · 190 m · 1 discovery · 8.2 km new</p></div>
  </div>
  <h2>Exploration</h2>
  <div class="card" style="display:grid;grid-template-columns:1fr 1fr;gap:12px">
    ${[['NEW TERRITORY', '96.2 km'], ['UNIQUE ROADS', '210 km'], ['REGIONS VISITED', '7'], ['QUESTS COMPLETED', '12'], ['DISCOVERIES', '30'], ['TOTAL DISTANCE', '812 km']].map(m => `<div class="metric"><span class="l">${m[0]}</span><span class="v">${m[1]}</span></div>`).join('')}
  </div>
</div>
${tabbar('Journal')}
<div class="home"></div>`;

screens['09-character'] = `
${status()}
<div class="content">
  <h1 class="serif">Character</h1>
  <div class="card">
    <div style="display:flex;gap:14px;align-items:center"><div style="width:64px;height:64px;border-radius:50%;background:${C.deep};display:flex;align-items:center;justify-content:center;font-size:30px">🧭</div><div><div style="font-size:22px;font-weight:600" class="serif">Rowan</div><div class="muted">Wanderer · Explorer</div></div><div style="margin-left:auto" class="chip HARD">1 ability point</div></div>
    <div style="margin-top:14px" class="row"><b style="font-size:13px">Level 8</b><span class="muted">4,180 / 4,800 XP</span></div><div class="xpbar"><i style="width:35%"></i></div>
    <div style="margin-top:12px" class="row"><b style="font-size:13px">Explorer level 6</b><span class="muted">2,510 / 3,080 XP</span></div><div class="xpbar"><i style="width:60%"></i></div>
  </div>
  <h2>Abilities</h2>
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
    ${[['Trail Sense', 'Rank 2/3', 'Reveal more interesting nearby paths.', 1], ['Cartographer', 'Unlock', 'Increase information about unexplored areas.', 2], ['Pathfinder', 'Lv 8', 'Reveal unusual route alternatives.', 0], ['Far Wanderer', 'Lv 12', 'Rewards for distant discoveries.', 0]].map(a => `<div class="card" style="margin:0;opacity:${a[3] ? 1 : .55}"><b>${a[0]}</b><div style="font-size:11px;font-weight:700;color:${a[3] === 2 ? '#fff' : C.rune};${a[3] === 2 ? `background:${C.moss};display:inline-block;padding:3px 8px;border-radius:8px;margin-top:4px` : 'margin-top:4px'}">${a[1]}</div><p class="muted" style="margin-top:6px;font-size:12px">${a[2]}</p></div>`).join('')}
  </div>
  <h2>Bikes & rider profile</h2>
  <div class="card"><div class="row"><b>Boardman ADV 8.8</b><span class="muted">Gravel · default</span></div><p class="muted" style="margin-top:4px">Comfortable 30 km · 400 m climb · gravel OK</p></div>
</div>
${tabbar('Character')}
<div class="home"></div>`;

// ---- Watch -------------------------------------------------------------
const watchBase = `<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { width: 198px; height: 242px; background: #000; color: #fff; font-family: -apple-system, "SF Pro Rounded", "Helvetica Neue", Arial, sans-serif; border-radius: 44px; overflow: hidden; position: relative; }
  .time { position: absolute; top: 10px; right: 22px; font-size: 13px; font-weight: 600; color: #FFC733; }
  .center { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; }
  .big { font-size: 46px; font-weight: 800; font-variant-numeric: tabular-nums; line-height: 1; }
  .label { font-size: 11px; font-weight: 700; letter-spacing: .12em; color: #FFC733; }
  .street { font-size: 15px; font-weight: 600; margin-top: 8px; padding: 0 18px; }
  .dots { position: absolute; bottom: 12px; left: 0; right: 0; display: flex; justify-content: center; gap: 5px; }
  .dots i { width: 5px; height: 5px; border-radius: 50%; background: #444; } .dots i.on { background: #fff; }
</style>`;
const dots = n => `<div class="dots">${[0, 1, 2, 3].map(i => `<i class="${i === n ? 'on' : ''}"></i>`).join('')}</div>`;
screens['w1-watch-navigation'] = watchBase + `<div class="time">9:41</div><div class="center">
  <svg width="56" height="56" viewBox="0 0 96 96"><path d="M30,84 L30,40 Q30,26 44,26 L60,26" fill="none" stroke="#FFC733" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/><path d="M52,10 L74,26 L52,42Z" fill="#FFC733"/></svg>
  <div class="big" style="margin-top:6px">180 m</div><div class="label" style="margin-top:6px">RIGHT</div><div class="street">Rotherhithe Street</div></div>${dots(0)}`;
screens['w2-watch-quest'] = watchBase + `<div class="time">9:41</div><div class="center">
  <div class="label" style="color:#9aa">THE FORGOTTEN RAILWAY</div><div style="font-size:12px;color:#888;margin-top:14px">Objective</div><div style="font-size:19px;font-weight:700;margin-top:4px;padding:0 14px">Reach Old Station</div><div class="big" style="font-size:36px;margin-top:12px;color:#FFC733">1.4 km</div></div>${dots(1)}`;
screens['w3-watch-stats'] = watchBase + `<div class="time">9:41</div><div class="center" style="justify-content:center;gap:10px">
  ${[['12.6 km', 'DISTANCE'], ['48:12', 'DURATION'], ['140 m', 'ELEVATION'], ['132 bpm', 'HEART RATE']].map(m => `<div><div style="font-size:24px;font-weight:700;font-variant-numeric:tabular-nums">${m[0]}</div><div style="font-size:9px;font-weight:700;letter-spacing:.1em;color:#888">${m[1]}</div></div>`).join('')}</div>${dots(2)}`;
screens['w4-watch-objective-complete'] = watchBase + `<div class="center" style="background:#0f2a17">
  <div style="width:44px;height:44px;border-radius:50%;background:${C.moss};display:flex;align-items:center;justify-content:center;font-size:24px">✓</div>
  <div class="label" style="margin-top:10px;color:#9fd8ac">OBJECTIVE COMPLETE</div><div style="font-size:17px;font-weight:700;margin-top:6px">Old Station discovered</div><div class="big" style="font-size:30px;margin-top:8px;color:#FFC733">+50 XP</div></div>`;
screens['w5-watch-always-on'] = watchBase + `<div class="time" style="color:#777">9:41</div><div class="center" style="color:#bbb">
  <svg width="44" height="44" viewBox="0 0 96 96"><path d="M30,84 L30,40 Q30,26 44,26 L60,26" fill="none" stroke="#999" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/><path d="M52,10 L74,26 L52,42Z" fill="#999"/></svg>
  <div class="big" style="margin-top:8px;font-weight:600">180 m</div><div class="street" style="color:#888">Rotherhithe St</div></div>`;

(async () => {
  const browser = await chromium.launch();
  for (const [name, html] of Object.entries(screens)) {
    const watch = name.startsWith('w');
    const page = await browser.newPage({ viewport: watch ? { width: 198, height: 242 } : { width: 393, height: 852 }, deviceScaleFactor: 2 });
    await page.setContent((watch ? '' : base) + html);
    await page.screenshot({ path: path.join(OUT, `${name}.png`), omitBackground: watch });
    await page.close();
    console.log('wrote', name);
  }
  await browser.close();
})();
