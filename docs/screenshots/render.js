// Renders the design mockups in this folder from the Claude Design system in
// docs/design ("Cycling Companion"): the chosen options 9a, 10a, 11a/11b, 12a/12b,
// 13b, 14a, 15b, 2a and the Watch pages from 7a/16a, drawn with the same
// tokens, type and layout the SwiftUI code uses. They are HTML/CSS renders,
// not device captures. Maps are synthetic ink maps (no tiles, no network).
//
// Usage: npm i playwright && npx playwright install chromium && node render.js
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const OUT = __dirname;
const FONTS = path.join(__dirname, '..', '..', 'ios', 'RoadsAndRunes', 'Resources', 'Fonts');

const C = {
  cream: '#f5ead8', surface: '#ebddc5', track: '#dcd3c4', line: '#c0b6a5', hatch: '#a19786',
  ink: '#201e1d', inkSoft: '#474238', muted: '#645c50', mutedLight: '#82796a',
  terracotta: '#c67139', terracottaDeep: '#8c491a', terracottaLight: '#f6a06b', terracottaTint: '#ffe1d0', terracottaText: '#643312',
  sage: '#7a8a5e', sageDeep: '#56633f', sageLight: '#aebf92', sageTint: '#e1eecc', sageText: '#3d472b', compactGravel: '#728157',
  wizard: '#6b5f8f', scribe: '#4f6b7a', heart: '#ff8f8f',
};

function fontFace(family, file, weight) {
  const data = fs.readFileSync(path.join(FONTS, file)).toString('base64');
  return `@font-face{font-family:'${family}';font-weight:${weight};src:url(data:font/ttf;base64,${data}) format('truetype')}`;
}

const fonts = [
  fontFace('Caprasimo', 'Caprasimo-Regular.ttf', 400),
  fontFace('Figtree', 'Figtree-Regular.ttf', 400),
  fontFace('Figtree', 'Figtree-SemiBold.ttf', 600),
  fontFace('Figtree', 'Figtree-Bold.ttf', 700),
].join('\n');

// ---- Icons -----------------------------------------------------------------
const P = {
  star: 'M12 2l3 7 7 3-7 3-3 7-3-7-7-3 7-3z',
  shield: 'M12 2l8 3v7c0 5-3.5 8.5-8 10-4.5-1.5-8-5-8-10V5z',
  drop: 'M12 2c4 5 6 9 6 13a6 6 0 0 1-12 0c0-4 2-8 6-13z',
  book: 'M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H20v20H6.5a2.5 2.5 0 0 1 0-5H20',
  chevronRight: 'm9 18 6-6-6-6',
  chevronLeft: 'm15 18-6-6 6-6',
  check: 'M5 12l5 5L20 7',
  turnLeft: 'M9 14 4 9l5-5M4 9h11a5 5 0 0 1 5 5v6',
  arrowUp: 'M12 19V5M5 12l7-7 7 7',
  pause: 'M8 5h3v14H8zM13 5h3v14h-3z',
  play: 'M7 4l13 8-13 8z',
  bike: 'M5 17a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19 17a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM5 14l3-7h4l3 7M12 7h3l4 7',
  plus: 'M12 5v14M5 12h14',
  map: 'M3 6l6-3 6 3 6-3v15l-6 3-6-3-6 3zM9 3v15M15 6v15',
};

function icon(d, { size = 18, color = 'currentColor', fill = false, stroke = 2.75 } = {}) {
  const f = fill ? `fill="${color}"` : `fill="none" stroke="${color}" stroke-width="${stroke}" stroke-linecap="round" stroke-linejoin="round"`;
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" ${f}><path d="${d}"/></svg>`;
}

function globe(size = 18) {
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M2 12h20"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>`;
}

function ring(size = 14, color = C.cream) {
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="${color}" stroke-width="2.5"><circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="2.5" fill="${color}"/><path d="M12 4v4M12 16v4M4 12h4M16 12h4"/></svg>`;
}

const CLASS = {
  explorer: { color: C.sage, text: C.sageDeep, light: C.sageLight, glyph: (s, c) => icon(P.star, { size: s, color: c, fill: true }) },
  wizard: { color: C.wizard, text: C.wizard, light: '#b9afd9', glyph: (s, c) => ring(s, c) },
  warrior: { color: C.terracotta, text: C.terracottaDeep, light: C.terracottaLight, glyph: (s, c) => icon(P.shield, { size: s, color: c, fill: true }) },
  scribe: { color: C.scribe, text: C.scribe, light: '#a3bcc9', glyph: (s, c) => icon(P.drop, { size: s, color: c, fill: true }) },
};

function emblem(cls, size = 32, inverted = false) {
  const k = CLASS[cls];
  const bg = inverted ? C.cream : k.color;
  const fg = inverted ? k.color : C.cream;
  return `<span style="width:${size}px;height:${size}px;border-radius:50%;background:${bg};display:inline-flex;align-items:center;justify-content:center;flex:none">${k.glyph(Math.round(size * 0.44), fg)}</span>`;
}

function diamond(color, label = '', size = 22, dashed = false, done = false) {
  if (dashed) return `<span style="width:${size}px;height:${size}px;display:inline-flex;align-items:center;justify-content:center;flex:none"><span style="width:${size * 0.8}px;height:${size * 0.8}px;transform:rotate(45deg);border-radius:${size * 0.22}px;border:2px dashed ${C.mutedLight}"></span></span>`;
  const inner = done ? icon(P.check, { size: size * 0.55, color: '#fff', stroke: 3.5 }) : `<b style="color:#fff;font-size:${size * 0.5}px">${label}</b>`;
  return `<span style="width:${size}px;height:${size}px;display:inline-flex;align-items:center;justify-content:center;flex:none;position:relative"><span style="position:absolute;width:${size * 0.8}px;height:${size * 0.8}px;transform:rotate(45deg);border-radius:${size * 0.22}px;background:${color}"></span><span style="position:relative;display:flex">${inner}</span></span>`;
}

// ---- Synthetic ink map --------------------------------------------------------
function seeded(seed) {
  let s = seed >>> 0;
  return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
}

function roads(w, h, seed) {
  const rnd = seeded(seed);
  let out = '';
  const wave = (x0, y0, x1, y1) => {
    const mx = (x0 + x1) / 2 + (rnd() - 0.5) * 60;
    const my = (y0 + y1) / 2 + (rnd() - 0.5) * 60;
    return `M${x0},${y0} Q${mx},${my} ${x1},${y1}`;
  };
  for (let y = -20; y < h + 40; y += 34 + rnd() * 30) {
    const major = rnd() > 0.7;
    out += `<path d="${wave(-20, y, w + 20, y + (rnd() - 0.5) * 90)}" stroke="${C.inkSoft}" stroke-width="${major ? 2.2 : 1}" fill="none" opacity="${major ? 0.9 : 0.7}"/>`;
  }
  for (let x = -20; x < w + 40; x += 30 + rnd() * 34) {
    const major = rnd() > 0.75;
    out += `<path d="${wave(x, -20, x + (rnd() - 0.5) * 90, h + 20)}" stroke="${C.inkSoft}" stroke-width="${major ? 2 : 1}" fill="none" opacity="${major ? 0.9 : 0.7}"/>`;
  }
  // a river
  out += `<path d="M-10,${h * 0.62} C${w * 0.2},${h * 0.5} ${w * 0.4},${h * 0.72} ${w * 0.6},${h * 0.6} S${w * 0.9},${h * 0.5} ${w + 10},${h * 0.56}" stroke="${C.scribe}" stroke-width="7" fill="none" opacity=".35"/>`;
  return out;
}

/**
 * Ink map: roads everywhere at 15% under cream fog with a hatch; full contrast
 * inside the explored region, whose edge is a dashed ink line with a soft glow.
 */
function inkMap(w, h, { seed = 7, region, overlays = '', labels = true, id = 'm' } = {}) {
  const reg = region || `M${w * 0.15},${h * 0.24} C${w * 0.23},${h * 0.17} ${w * 0.45},${h * 0.15} ${w * 0.63},${h * 0.17} C${w * 0.8},${h * 0.2} ${w * 0.88},${h * 0.27} ${w * 0.83},${h * 0.35} C${w * 0.79},${h * 0.4} ${w * 0.85},${h * 0.46} ${w * 0.75},${h * 0.5} C${w * 0.63},${h * 0.54} ${w * 0.48},${h * 0.5} ${w * 0.38},${h * 0.55} C${w * 0.28},${h * 0.6} ${w * 0.13},${h * 0.57} ${w * 0.1},${h * 0.51} C${w * 0.08},${h * 0.44} ${w * 0.18},${h * 0.4} ${w * 0.14},${h * 0.35} C${w * 0.11},${h * 0.3} ${w * 0.1},${h * 0.28} ${w * 0.15},${h * 0.24} Z`;
  const outside = `M0,0H${w}V${h}H0Z ${reg}`;
  return `<svg width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" style="display:block;background:${C.cream}">
  <defs>
    <pattern id="hatch${id}" width="7" height="7" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="7" stroke="${C.hatch}" stroke-width="1"/></pattern>
    <filter id="glow${id}" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="8"/></filter>
    <clipPath id="clip${id}"><path d="${outside}" clip-rule="evenodd"/></clipPath>
  </defs>
  <g>${roads(w, h, seed)}</g>
  <g clip-path="url(#clip${id})">
    <path d="${outside}" fill="${C.cream}" fill-opacity=".93" fill-rule="evenodd"/>
    <path d="${outside}" fill="url(#hatch${id})" opacity=".28" fill-rule="evenodd"/>
    <path d="${reg}" fill="none" stroke="${C.terracottaDeep}" stroke-width="22" opacity=".22" filter="url(#glow${id})"/>
  </g>
  <path d="${reg}" fill="none" stroke="${C.muted}" stroke-width="1.5" stroke-dasharray="5 4"/>
  ${labels ? `<text x="${w * 0.75}" y="${h * 0.64}" font-family="Caprasimo" font-size="13" fill="${C.mutedLight}" opacity=".8" text-anchor="middle" font-style="italic">unexplored</text><text x="${w * 0.22}" y="${h * 0.74}" font-family="Caprasimo" font-size="13" fill="${C.mutedLight}" opacity=".8" text-anchor="middle" font-style="italic">unexplored</text>` : ''}
  ${overlays}
</svg>`;
}

const svgDiamond = (x, y, color, label, size = 26) => `<g transform="translate(${x},${y})"><rect x="${-size / 2}" y="${-size / 2}" width="${size}" height="${size}" rx="6" fill="${color}" stroke="#fff" stroke-width="3" transform="rotate(45)"/><text x="0" y="4.5" font-family="Figtree" font-weight="700" font-size="12" fill="#fff" text-anchor="middle">${label}</text></g>`;
const svgMystery = (x, y) => `<g transform="translate(${x},${y})"><circle r="13" fill="${C.cream}" fill-opacity=".9" stroke="${C.mutedLight}" stroke-width="2" stroke-dasharray="3 2"/><text y="5" font-family="Figtree" font-weight="700" font-size="14" fill="${C.muted}" text-anchor="middle">?</text></g>`;
const svgFriend = (x, y, letter, color) => `<g transform="translate(${x},${y})"><circle r="12" fill="${color}" stroke="#fff" stroke-width="2.5"/><text y="4.5" font-family="Caprasimo" font-size="12" fill="${C.cream}" text-anchor="middle">${letter}</text></g>`;
const svgRider = (x, y, deg = 0, size = 22) => `<g transform="translate(${x},${y})"><circle r="${size}" fill="${C.sage}" fill-opacity=".25"/><circle r="${size / 2}" fill="${C.sage}" stroke="#fff" stroke-width="4"/><path transform="rotate(${deg}) scale(${size / 22})" d="M0 -6l4 10-4-2.3-4 2.3z" fill="#fff"/></g>`;
const svgRoute = (d, color = C.terracotta, w = 5, dash = '') => `<path d="${d}" fill="none" stroke="${color}" stroke-width="${w + 14}" stroke-opacity=".16" stroke-linecap="round"/><path d="${d}" fill="none" stroke="#fff" stroke-width="${w + 4}" stroke-opacity=".95" stroke-linecap="round" stroke-linejoin="round"/><path d="${d}" fill="none" stroke="${color}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round" ${dash ? `stroke-dasharray="${dash}"` : ''}/>`;

// ---- Chrome ------------------------------------------------------------------
const base = `<meta charset="utf-8"><style>
${fonts}
*{box-sizing:border-box;margin:0;padding:0}
body{width:402px;height:874px;overflow:hidden;background:${C.cream};color:${C.ink};font-family:Figtree,system-ui,sans-serif;position:relative;-webkit-font-smoothing:antialiased}
.voice{font-family:Caprasimo,serif;font-weight:400}
.island{position:absolute;top:11px;left:50%;transform:translateX(-50%);width:126px;height:37px;border-radius:24px;background:#000;z-index:50}
.status{position:absolute;top:0;left:0;right:0;display:flex;justify-content:space-between;padding:21px 34px 0;font-size:17px;font-weight:600;z-index:40}
.status svg{vertical-align:middle}
.home{position:absolute;bottom:8px;left:50%;transform:translateX(-50%);width:139px;height:5px;border-radius:100px;background:rgba(0,0,0,.25);z-index:60}
.home.light{background:rgba(255,255,255,.7)}
.tabbar{position:absolute;left:20px;right:20px;bottom:30px;height:62px;border-radius:999px;background:${C.ink};display:flex;align-items:center;justify-content:space-around;padding:0 10px;color:${C.line};font-size:11px;font-weight:600;z-index:600;box-shadow:0 12px 32px rgba(46,43,37,.25)}
.tab{display:flex;flex-direction:column;align-items:center;gap:3px;padding:8px 12px;border-radius:999px}
.tab.on{color:${C.cream};background:${C.terracotta};padding:8px 18px}
.eyebrow{font-size:11px;font-weight:700;letter-spacing:.06em;text-transform:uppercase}
.card{background:${C.surface};border-radius:24px;padding:14px 16px}
.row{display:flex;gap:12px;align-items:center;padding:12px 14px;border-radius:22px;background:${C.surface}}
.tile{flex:1;background:${C.surface};border-radius:20px;padding:12px 14px}
.tile b{display:block;font-size:22px;font-weight:700;line-height:1}
.tile span{display:block;font-size:11px;color:${C.muted};margin-top:5px}
.primary{height:60px;border-radius:999px;background:${C.terracotta};color:${C.cream};display:flex;align-items:center;justify-content:center;font-family:Caprasimo,serif;font-size:19px;box-shadow:0 12px 32px rgba(46,43,37,.22);flex:1}
.secondary{padding:0 18px;height:60px;border-radius:999px;background:${C.surface};display:flex;align-items:center;font-size:14px;font-weight:600}
.chip{padding:5px 10px;border-radius:999px;font-size:12px;font-weight:600}
.sheet{background:${C.cream};border-radius:32px 32px 0 0;box-shadow:0 -8px 24px rgba(46,43,37,.12)}
.handle{width:40px;height:5px;border-radius:3px;background:${C.line};margin:0 auto}
.muted{color:${C.muted}}
</style>`;

function status(dark) {
  const c = dark ? '#fff' : '#000';
  return `<div class="island"></div><div class="status" style="color:${c}"><span>9:41</span><span style="display:flex;gap:7px;align-items:center">
  <svg width="19" height="12" viewBox="0 0 19 12"><rect x="0" y="7.5" width="3.2" height="4.5" rx=".7" fill="${c}"/><rect x="4.8" y="5" width="3.2" height="7" rx=".7" fill="${c}"/><rect x="9.6" y="2.5" width="3.2" height="9.5" rx=".7" fill="${c}"/><rect x="14.4" y="0" width="3.2" height="12" rx=".7" fill="${c}"/></svg>
  <svg width="17" height="12" viewBox="0 0 17 12"><path d="M8.5 3.2C10.8 3.2 12.9 4.1 14.4 5.6L15.5 4.5C13.7 2.7 11.2 1.5 8.5 1.5C5.8 1.5 3.3 2.7 1.5 4.5L2.6 5.6C4.1 4.1 6.2 3.2 8.5 3.2Z" fill="${c}"/><path d="M8.5 6.8C9.9 6.8 11.1 7.3 12 8.2L13.1 7.1C11.8 5.9 10.2 5.1 8.5 5.1C6.8 5.1 5.2 5.9 3.9 7.1L5 8.2C5.9 7.3 7.1 6.8 8.5 6.8Z" fill="${c}"/><circle cx="8.5" cy="10.5" r="1.5" fill="${c}"/></svg>
  <svg width="27" height="13" viewBox="0 0 27 13"><rect x=".5" y=".5" width="23" height="12" rx="3.5" stroke="${c}" stroke-opacity=".35" fill="none"/><rect x="2" y="2" width="20" height="9" rx="2" fill="${c}"/><path d="M25 4.5V8.5C25.8 8.2 26.5 7.2 26.5 6.5C26.5 5.8 25.8 4.8 25 4.5Z" fill="${c}" fill-opacity=".4"/></svg></span></div>`;
}

function tabbar(active) {
  const tabs = [['World', globe()], ['Quests', icon(P.star)], ['Journal', icon(P.book)], ['Character', icon(P.shield)]];
  return `<div class="tabbar">${tabs.map(([t, i]) => `<div class="tab ${t === active ? 'on' : ''}">${i}${t}</div>`).join('')}</div>`;
}

function questRow(cls, eyebrow, title, meta) {
  const k = CLASS[cls];
  return `<div class="row"><div style="width:64px;height:64px;border-radius:18px;background:${k.color};display:flex;align-items:center;justify-content:center;flex:none">${k.glyph(26, C.cream)}</div><div style="flex:1"><div class="eyebrow" style="color:${k.text}">${eyebrow}</div><div class="voice" style="font-size:18px;margin-top:2px">${title}</div><div style="font-size:12.5px;color:${C.muted}">${meta}</div></div>${icon(P.chevronRight, { color: C.muted })}</div>`;
}

// ---- iPhone screens ------------------------------------------------------------
const screens = {};

// 11a — Choose your class
screens['01-onboarding-class'] = () => {
  const card = (cls, name, tagline, desc, chosen) => `<div style="display:flex;gap:14px;align-items:center;padding:14px 16px;border-radius:26px;background:${C.surface};${chosen ? `border:2px solid ${CLASS[cls].color}` : ''}">${emblem(cls, 56)}<div style="flex:1"><div style="display:flex;justify-content:space-between;align-items:baseline"><span class="voice" style="font-size:20px">${name}</span>${chosen ? `<span class="eyebrow" style="color:${C.sageDeep}">Chosen</span>` : ''}</div><div style="font-size:13px;color:${C.inkSoft};line-height:1.4">${tagline}</div><div style="font-size:11.5px;color:${C.muted};margin-top:4px">${desc}</div></div></div>`;
  return `${status(false)}
  <div style="padding:74px 22px 0;display:flex;flex-direction:column;gap:12px">
    <div class="voice" style="font-size:32px;line-height:1.05">How do you<br>like to explore?</div>
    <div style="font-size:13.5px;color:${C.muted};line-height:1.45">Your class shapes your quests and bonuses. It never locks you out of anything.</div>
    <div style="padding:14px 18px;border-radius:999px;background:${C.surface};font-size:16px">Amirali</div>
    ${card('explorer', 'Explorer', 'Chart unknown territory. New roads and unvisited areas earn the most.', 'Cartographer · Trail Sense · Pathfinder · Long Road', true)}
    ${card('wizard', 'Wizard', 'Seek strange places and hidden knowledge. Riddles, ruins, ley lines.', 'Wayfinder · Arcane Sight · Foresight', false)}
    ${card('warrior', 'Warrior', 'Take on hills, distance and rough ground. Speed never counts.', 'Endurance · Second Wind · Mountainborn', false)}
    ${card('scribe', 'Scribe', 'Record places and stories for others. Photos, notes, routes.', 'Archivist · Rumour · Chronicler', false)}
  </div>
  <div style="position:absolute;left:20px;right:20px;bottom:30px;display:flex"><div class="primary">Ride as an Explorer</div></div>
  <div class="home"></div>`;
};

// 9a — World, the new home
screens['02-world'] = () => {
  const overlays = svgMystery(300, 340) + svgMystery(120, 620) + svgMystery(330, 470) + svgMystery(70, 560) + svgMystery(250, 700)
    + svgDiamond(230, 250, C.sage, 'Q') + svgDiamond(150, 380, C.wizard, 'Q') + svgDiamond(330, 250, C.terracotta, 'Q')
    + svgFriend(120, 300, 'M', C.wizard) + svgRider(201, 330, 0, 22);
  return `<div style="position:absolute;inset:0">${inkMap(402, 874, { seed: 11, overlays, id: 'w' })}</div>
  ${status(false)}
  <div style="position:absolute;top:60px;left:16px;right:16px;display:flex;justify-content:space-between;align-items:flex-start;z-index:500">
    <div style="display:flex;align-items:center;gap:10px;padding:6px 14px 6px 6px;border-radius:999px;background:${C.ink};color:${C.cream};box-shadow:0 3px 10px rgba(46,43,37,.2)">${emblem('explorer', 32)}<div><div style="font-size:13px;font-weight:700;line-height:1.1">Amirali · Explorer 8</div><div style="height:4px;border-radius:2px;background:${C.inkSoft};margin-top:4px;width:110px"><div style="width:83%;height:100%;border-radius:2px;background:${C.sageLight}"></div></div></div></div>
    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:8px"><div style="padding:9px 14px;border-radius:999px;background:rgba(245,234,216,.94);font-size:12px;font-weight:600;box-shadow:0 1px 2px rgba(46,43,37,.14)">31% of Southwark explored</div><div style="width:40px;height:40px;border-radius:50%;background:rgba(245,234,216,.94);display:flex;align-items:center;justify-content:center;box-shadow:0 1px 2px rgba(46,43,37,.14)">${icon(P.map, { size: 16 })}</div></div>
  </div>
  <div style="position:absolute;top:400px;right:120px;z-index:500;padding:6px 10px;border-radius:999px;background:${C.ink};color:${C.cream};font-size:11px;font-weight:600;white-space:nowrap">Unexplored woodland · 11 km east</div>
  <div class="sheet" style="position:absolute;left:0;right:0;bottom:0;z-index:500;padding:12px 20px 110px;display:flex;flex-direction:column;gap:12px;box-shadow:0 -8px 24px rgba(46,43,37,.16)">
    <div class="handle"></div>
    <div style="display:flex;justify-content:space-between;align-items:baseline"><span class="voice" style="font-size:22px">Nearby</span><span style="font-size:13px;color:${C.muted}">3 quests · 5 mysteries</span></div>
    ${questRow('explorer', 'Explorer quest · 3.2 km away', 'The Lost Dockyards', '18 km · easy · 2 objectives · 280 XP')}
    ${questRow('wizard', 'Wizard quest · any class', 'Ley Lines', '22 km · three markers · 350 XP · Rune Fragment')}
  </div>
  ${tabbar('World')}
  <div class="home"></div>`;
};

// Quests tab: the current quest as the big card, nearby as rows
screens['03-quests'] = () => `${status(false)}
  <div style="padding:66px 22px 0;display:flex;flex-direction:column;gap:14px">
    <div class="voice" style="font-size:32px">Quests</div>
    <div style="border-radius:28px;background:${C.ink};color:${C.cream};padding:18px 20px;display:flex;flex-direction:column;gap:10px;position:relative;overflow:hidden"><div style="position:absolute;right:-40px;top:-40px;width:200px;height:200px;border-radius:50%;background:repeating-radial-gradient(circle,transparent 0 9px,rgba(245,234,216,.08) 9px 10px)"></div><div class="eyebrow" style="color:${C.sageLight}">Current quest · 2 objectives left</div><div class="voice" style="font-size:26px;line-height:1.05">The Forgotten Railway</div><div style="font-size:13.5px;color:${C.line};line-height:1.45">Explore the abandoned railway trail east of the river.</div><div style="display:flex;gap:14px;font-size:14px;font-weight:600"><span>18 km</span><span>Moderate</span><span style="color:${C.sageLight}">+300 XP</span></div><div style="display:flex;gap:8px;margin-top:2px"><div style="flex:1;height:48px;border-radius:999px;background:${C.terracotta};display:flex;align-items:center;justify-content:center;font-family:Caprasimo,serif;font-size:16px">Continue</div><div style="padding:0 18px;height:48px;border-radius:999px;border:1px solid rgba(245,234,216,.2);display:flex;align-items:center;font-size:13px;font-weight:600">Details</div></div></div>
    <div style="display:flex;justify-content:space-between;align-items:baseline"><span class="voice" style="font-size:20px">Nearby adventures</span><span style="font-size:13px;color:${C.muted}">3</span></div>
    ${questRow('explorer', 'Explorer quest · 3.2 km away', 'The Green Beyond', '27 km · moderate · 3 objectives · 420 XP')}
    ${questRow('wizard', 'Wizard quest · 4.1 km away', 'Ley Lines', '22 km · easy · 3 objectives · 350 XP')}
    ${questRow('warrior', 'Warrior quest · 6.8 km away', 'Trial of the Hill', '34 km · hard · 2 objectives · 450 XP')}
  </div>
  ${tabbar('Quests')}
  <div class="home"></div>`;

// 10a — Quest detail, map-led
screens['04-quest-detail'] = () => {
  const route = 'M200,300 C150,260 120,220 110,160 C105,130 130,90 170,80';
  const overlays = svgRoute('M200,300 C150,260 120,220 110,160', C.sage, 4) + svgRoute('M110,160 C105,130 130,90 170,80', C.terracotta, 5, '1 9') + svgRoute('M170,80 C230,60 300,110 290,200 C280,250 240,280 200,300', C.sage, 4, '10 8')
    + svgDiamond(110, 160, C.sage, '1') + svgDiamond(150, 96, C.terracotta, '2') + svgDiamond(170, 80, C.sage, '3') + svgRider(200, 300, 200, 20);
  return `<div style="position:absolute;top:0;left:0">${inkMap(402, 360, { seed: 3, labels: false, id: 'q', overlays, region: 'M60,120 C110,60 260,50 330,90 C380,120 370,220 330,280 C290,340 120,340 70,290 C30,250 30,170 60,120 Z' })}</div>
  ${status(false)}
  <div style="position:absolute;top:60px;left:16px;right:16px;display:flex;justify-content:space-between;z-index:500"><div style="width:40px;height:40px;border-radius:50%;background:rgba(245,234,216,.92);display:flex;align-items:center;justify-content:center;box-shadow:0 1px 2px rgba(46,43,37,.14)">${icon(P.chevronLeft)}</div><div style="padding:0 14px;height:40px;border-radius:999px;background:${C.sage};color:${C.cream};display:flex;align-items:center;gap:8px" class="eyebrow">${icon(P.star, { size: 14, color: C.cream, fill: true })}Explorer quest</div></div>
  <div class="sheet" style="position:absolute;left:0;right:0;top:332px;bottom:0;padding:14px 22px 0;display:flex;flex-direction:column;gap:12px;z-index:500">
    <div class="voice" style="font-size:30px;line-height:1.05">The Green Beyond</div>
    <p style="font-size:14px;line-height:1.5;color:${C.inkSoft}">Rumours speak of an old trail hidden beyond the eastern woods.</p>
    <div style="display:flex;flex-direction:column;gap:8px;font-size:14px">
      <div style="display:flex;gap:12px;align-items:center">${diamond(C.sage, '1')}Reach Sydenham Woods<span style="margin-left:auto;color:${C.muted};font-size:12px">12 km</span></div>
      <div style="display:flex;gap:12px;align-items:center">${diamond(C.terracotta, '2')}Explore 3 km of unseen trails<span style="margin-left:auto;color:${C.muted};font-size:12px">gravel</span></div>
      <div style="display:flex;gap:12px;align-items:center">${diamond(C.sage, '3')}Find the viewpoint<span style="margin-left:auto;color:${C.muted};font-size:12px">hidden</span></div>
      <div style="display:flex;gap:12px;align-items:center">${diamond(C.sage, '', 22, true)}Return by a different route<span style="margin-left:auto;color:${C.muted};font-size:12px">optional</span></div>
    </div>
    <div style="display:flex;gap:8px"><div class="tile"><b>27 km</b><span>Journey</span></div><div class="tile"><b>2h 10m</b><span>At your pace</span></div><div class="tile"><b style="color:${C.sageDeep}">420</b><span>XP + Map Fragment</span></div></div>
    <div style="display:flex;gap:8px;align-items:center;font-size:12.5px;color:${C.muted}"><span class="chip" style="background:${C.terracottaTint};color:${C.terracottaText}">Moderate for you</span>38% gravel, fine on the Boardman · back before sunset</div>
  </div>
  <div style="position:absolute;left:20px;right:20px;bottom:30px;z-index:600;display:flex;gap:10px"><div class="secondary">Accept</div><div class="primary">Begin quest</div></div>
  <div class="home"></div>`;
};

// 2a — Three ways to ride it
screens['05-routes'] = () => {
  const surface = (paved, compact, loose) => `<div style="display:flex;height:7px;border-radius:4px;overflow:hidden"><span style="width:${paved}%;background:${C.inkSoft}"></span><span style="width:${compact}%;background:${C.compactGravel}"></span><span style="width:${loose}%;background:repeating-linear-gradient(90deg,${C.terracotta} 0 3px,${C.cream} 3px 5px)"></span><span style="flex:1;background:${C.line}"></span></div>`;
  const card = (bar, title, badge, nums, strip, why, selected) => `<div class="card" style="display:flex;gap:14px;align-items:center;${selected ? `border:2px solid ${C.terracotta}` : ''}"><div style="width:6px;align-self:stretch;border-radius:3px;background:${bar}"></div><div style="flex:1;display:flex;flex-direction:column;gap:6px"><div style="display:flex;justify-content:space-between;align-items:baseline"><span class="voice" style="font-size:20px">${title}</span>${badge}</div><div style="display:flex;gap:14px;font-size:14px;font-weight:600">${nums}</div>${strip}<div style="font-size:12.5px;color:${C.muted};line-height:1.45">${why}</div></div></div>`;
  const overlays = svgRoute('M200,150 C120,120 60,180 90,240 C120,290 200,270 260,240 C320,210 330,140 280,110', C.mutedLight, 4, '6 8') + svgRoute('M200,150 C260,110 340,140 320,200 C300,250 240,280 190,260', C.sage, 4) + svgRoute('M200,150 C140,100 80,120 70,190 C60,250 130,300 210,290 C300,280 340,220 300,170', C.terracotta, 5)
    + `<circle cx="300" cy="170" r="6" fill="${C.terracotta}" stroke="#fff" stroke-width="3"/>` + svgRider(200, 150, 0, 16);
  return `<div style="position:absolute;top:0;left:0">${inkMap(402, 320, { seed: 5, labels: false, id: 'r', overlays, region: 'M-10,-10H412V330H-10Z' })}</div>
  ${status(false)}
  <div style="position:absolute;top:60px;left:16px;right:16px;display:flex;gap:8px;align-items:center;z-index:500"><div style="width:40px;height:40px;border-radius:50%;background:rgba(245,234,216,.92);display:flex;align-items:center;justify-content:center">${icon(P.chevronLeft)}</div><div style="flex:1;padding:10px 14px;border-radius:999px;background:rgba(245,234,216,.92);font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">“30–40 km, mostly quiet, some gravel, pub toward the end”</div></div>
  <div class="sheet" style="position:absolute;left:0;right:0;top:292px;bottom:0;padding:14px 18px 0;display:flex;flex-direction:column;gap:10px;z-index:500">
    <div style="display:flex;justify-content:space-between;align-items:baseline;padding:0 4px"><span class="voice" style="font-size:22px">Three ways to ride it</span><span style="font-size:13px;color:${C.terracottaDeep}">Adjust</span></div>
    ${card(C.terracotta, 'Adventure', `<span class="eyebrow" style="background:${C.terracotta};color:${C.cream};padding:3px 9px;border-radius:999px">Best match</span>`, '<span>35.4 km</span><span>2h 10m</span><span>↑ 310 m</span>', surface(52, 30, 8), `38% gravel · 3 climbs · 64% cycleways and quiet roads · <b style="color:${C.ink}">The Crown at 26 km</b>`, true)}
    ${card(C.sage, 'Relaxed', '', '<span>31.8 km</span><span>1h 50m</span><span>↑ 180 m</span>', surface(88, 8, 0), 'Quietest · 76% cycleways and quiet roads · gentle · no pub on route', false)}
    ${card(`repeating-linear-gradient(${C.mutedLight} 0 5px,transparent 5px 8px)`, 'Fast', '', '<span>28.2 km</span><span>1h 31m</span><span>↑ 150 m</span>', surface(97, 0, 0), '19 min quicker · more main-road riding · almost entirely paved', false)}
  </div>
  <div style="position:absolute;left:20px;right:20px;bottom:30px;z-index:600;display:flex;flex-direction:column;gap:8px"><div style="display:flex;justify-content:center;gap:6px;font-size:12px;color:${C.sageDeep};font-weight:600">Map, directions, elevation and stops download when you start</div><div class="primary">${icon(P.play, { size: 16, color: C.cream, fill: true })}&nbsp;&nbsp;Start ride</div></div>
  <div class="home"></div>`;
};

function navMap(seed, id) {
  const overlays = svgRoute('M120,760 C160,700 190,640 200,560 C210,480 230,430 260,380 C290,330 330,300 360,280', C.terracotta, 7) + `<circle cx="260" cy="380" r="7" fill="${C.terracotta}" stroke="#fff" stroke-width="3"/>` + svgDiamond(330, 300, C.sage, 'Q', 28) + svgRider(200, 560, 35, 28);
  return inkMap(402, 874, { seed, labels: false, id, overlays, region: 'M-10,-10H412V884H-10Z' });
}

function statsPill(a, b, c, bLabel = 'km new territory', cLabel = 'ride time') {
  return `<div style="position:absolute;left:14px;right:14px;bottom:30px;z-index:500;background:${C.ink};border-radius:32px;padding:16px 22px;display:flex;align-items:center;color:${C.cream};box-shadow:0 12px 32px rgba(46,43,37,.25)">
    <div style="flex:1"><div style="font-size:30px;font-weight:700;line-height:1">${a}</div><div style="font-size:11px;color:${C.line};margin-top:4px">km ridden</div></div>
    <div style="flex:1;text-align:center;border-left:1px solid rgba(245,234,216,.15);border-right:1px solid rgba(245,234,216,.15)"><div style="font-size:30px;font-weight:700;line-height:1;color:${C.sageLight}">${b}</div><div style="font-size:11px;color:${C.line};margin-top:4px">${bLabel}</div></div>
    <div style="flex:1;text-align:right"><div style="font-size:30px;font-weight:700;line-height:1">${c}</div><div style="font-size:11px;color:${C.line};margin-top:4px">${cLabel}</div></div>
    <div style="margin-left:18px;width:48px;height:48px;border-radius:50%;background:${C.inkSoft};display:flex;align-items:center;justify-content:center">${icon(P.pause, { size: 18, color: C.cream, fill: true })}</div>
  </div>`;
}

// 12a — Navigation with quest objective
screens['06-navigation'] = () => `<div style="position:absolute;inset:0">${navMap(21, 'n')}</div>
  ${status(false)}
  <div style="position:absolute;top:56px;left:14px;right:14px;z-index:500;display:flex;flex-direction:column;gap:8px">
    <div style="background:${C.cream};border-radius:30px;padding:18px 20px;display:flex;gap:18px;align-items:center;box-shadow:0 6px 18px rgba(46,43,37,.18)">${icon(P.turnLeft, { size: 56, stroke: 3 })}<div style="flex:1"><div style="font-size:56px;font-weight:700;line-height:.95;letter-spacing:-.02em">180<span style="font-size:24px;font-weight:600;margin-left:4px">m</span></div><div style="font-size:18px;font-weight:600;margin-top:6px">Turn left</div><div style="font-size:15px;color:${C.muted}">Rotherhithe Street</div></div><div style="align-self:flex-start;display:flex;flex-direction:column;align-items:center;gap:2px;color:${C.muted}">${icon(P.arrowUp, { size: 18, color: C.muted })}<span style="font-size:10px">then 0.6 km</span></div></div>
    <div style="display:flex;align-items:center;gap:12px;padding:10px 16px;border-radius:999px;background:${C.ink};color:${C.cream};box-shadow:0 4px 12px rgba(46,43,37,.2)"><span style="width:18px;height:18px;display:inline-flex;align-items:center;justify-content:center"><span style="width:14px;height:14px;transform:rotate(45deg);border-radius:4px;background:${C.sage}"></span></span><div style="flex:1;font-size:14px"><span class="eyebrow" style="color:${C.sageLight}">Quest · </span><b>Find the Old Pump House</b></div><b style="font-size:16px">1.2 km</b></div>
    <div style="display:flex;justify-content:space-between;padding:0 2px"><span style="padding:9px 14px;border-radius:999px;background:${C.ink};color:${C.cream};font-size:12px;font-weight:600;display:flex;gap:8px;align-items:center"><span style="width:9px;height:9px;border-radius:50%;background:${C.sageLight}"></span>Watch · navigating</span></div>
  </div>
  ${statsPill('14.3', '2.6', '1:02')}
  <div class="home"></div>`;

// 12b — Objective complete
screens['10-objective-complete'] = () => `<div style="position:absolute;inset:0">${navMap(21, 'o')}</div>
  ${status(false)}
  <div style="position:absolute;top:56px;left:14px;right:14px;z-index:500;display:flex;flex-direction:column;gap:8px;align-items:center">
    <div style="width:100%;background:${C.sage};color:${C.cream};border-radius:30px;padding:20px 22px;display:flex;gap:18px;align-items:center;box-shadow:0 6px 18px rgba(46,43,37,.18)"><div style="width:64px;height:64px;border-radius:50%;background:${C.cream};display:flex;align-items:center;justify-content:center;flex:none">${icon(P.star, { size: 28, color: C.sage, fill: true })}</div><div style="flex:1"><div class="eyebrow">Objective complete</div><div class="voice" style="font-size:24px;line-height:1.1;margin-top:4px">Old Pump House discovered</div><div style="font-size:15px;margin-top:6px;font-weight:600">1 objective left</div></div></div>
    <div style="padding:8px 14px;border-radius:999px;background:rgba(245,234,216,.94);font-size:12.5px;color:${C.muted};font-weight:600">Continue straight · 600 m</div>
  </div>
  ${statsPill('15.5', '3.1', '1:02')}
  <div class="home"></div>`;

// 13b — Adventure complete, map reveal first
screens['07-adventure-complete'] = () => {
  const overlays = svgRoute('M200,120 C150,150 110,200 100,260 C95,300 130,330 170,320 C210,310 230,270 260,250 C300,230 330,180 300,140 C270,110 230,100 200,120', C.sage, 4)
    + `<circle cx="100" cy="260" r="7" fill="${C.terracotta}" stroke="#fff" stroke-width="3"/><circle cx="170" cy="320" r="7" fill="${C.terracotta}" stroke="#fff" stroke-width="3"/><circle cx="300" cy="140" r="7" fill="${C.terracotta}" stroke="#fff" stroke-width="3"/>`;
  return `<div style="position:absolute;top:0;left:0">${inkMap(402, 470, { seed: 9, labels: false, id: 'a', overlays, region: 'M70,100 C120,60 260,50 320,110 C360,150 350,260 320,320 C280,380 140,380 90,330 C40,280 30,150 70,100 Z' })}</div>
  ${status(false)}
  <div style="position:absolute;top:60px;left:16px;right:16px;z-index:500;display:flex;justify-content:center"><div style="padding:8px 16px;border-radius:999px;background:${C.ink};color:${C.cream};font-size:12.5px;font-weight:600;display:flex;gap:8px;align-items:center"><span style="width:10px;height:10px;border-radius:50%;background:${C.sageLight}"></span>12.6 km² revealed · Southwark 31% → 36%</div></div>
  <div class="sheet" style="position:absolute;left:0;right:0;bottom:0;z-index:500;padding:14px 22px 104px;display:flex;flex-direction:column;gap:12px">
    <div class="handle"></div>
    <div style="display:flex;justify-content:space-between;align-items:flex-end"><div><div class="eyebrow" style="color:${C.sageDeep}">Adventure complete</div><div class="voice" style="font-size:28px;line-height:1.05;margin-top:4px">The Forgotten Railway</div></div><div style="font-size:40px;font-weight:700;line-height:1;letter-spacing:-.03em;color:${C.sageDeep}">+420<span style="font-size:14px;font-weight:600;margin-left:3px">XP</span></div></div>
    <div style="display:flex;gap:8px"><div class="tile"><b>3</b><span>New places</span></div><div class="tile"><b>12.6 km</b><span>New territory</span></div><div class="tile"><b>4.2 km</b><span>New roads</span></div></div>
    <div style="display:flex;justify-content:space-between;font-size:13px;color:${C.muted}"><span>32.4 km · 2h 08m · 340 m climbed</span><span>Explorer +300 · General +120</span></div>
    <div style="display:flex;gap:6px;flex-wrap:wrap"><span class="chip" style="background:${C.sageTint};color:${C.sageText}">Class level 8 → 9</span><span class="chip" style="background:${C.sageTint};color:${C.sageText}">Pathfinder available</span></div>
    <div style="display:flex;gap:6px;flex-wrap:wrap"><span class="chip" style="background:${C.surface};font-weight:400">Old Pump House</span><span class="chip" style="background:${C.surface};font-weight:400">Railway viaduct</span><span class="chip" style="background:${C.surface};font-weight:400">Hidden garden</span></div>
  </div>
  <div style="position:absolute;left:20px;right:20px;bottom:30px;z-index:600;display:flex"><div class="primary">Collect rewards</div></div>
  <div class="home"></div>`;
};

// 14a — Journal, adventures
screens['08-journal'] = () => {
  const entry = (cls, title, xp, meta) => `<div class="row"><div style="width:64px;height:64px;border-radius:18px;background:${cls ? CLASS[cls].color : C.track};display:flex;align-items:center;justify-content:center;flex:none">${cls ? CLASS[cls].glyph(24, C.cream) : icon(P.bike, { size: 24, color: C.muted })}</div><div style="flex:1"><div style="display:flex;justify-content:space-between"><span class="voice" style="font-size:17px">${title}</span><span style="font-size:12px;color:${cls ? CLASS[cls].text : C.sageDeep};font-weight:600">${xp}</span></div><div style="font-size:12.5px;color:${C.muted}">${meta}</div></div></div>`;
  return `${status(false)}
  <div style="padding:66px 22px 0;display:flex;flex-direction:column;gap:14px">
    <div style="display:flex;justify-content:space-between;align-items:baseline"><span class="voice" style="font-size:32px">Journal</span><span style="font-size:13px;color:${C.muted}">142 km² · 41 discoveries</span></div>
    <div style="display:flex;gap:6px;padding:5px;border-radius:999px;background:${C.surface}"><span style="flex:1;text-align:center;padding:8px 0;border-radius:999px;background:${C.ink};color:${C.cream};font-size:13px;font-weight:600">Adventures</span><span style="flex:1;text-align:center;padding:8px 0;font-size:13px;font-weight:600;color:${C.muted}">Discoveries</span><span style="flex:1;text-align:center;padding:8px 0;font-size:13px;font-weight:600;color:${C.muted}">Map</span><span style="flex:1;text-align:center;padding:8px 0;font-size:13px;font-weight:600;color:${C.muted}">Stats</span></div>
    <div class="card"><div style="display:flex;justify-content:space-between;align-items:baseline"><span class="voice" style="font-size:20px">September</span><span style="font-size:12px;color:${C.muted}">5 adventures</span></div><div style="display:flex;gap:16px;margin-top:8px;font-size:14px"><span><b>38 km</b> new roads</span><span><b>11</b> discoveries</span><span><b>4</b> quests</span><span><b>1,430 m</b></span></div></div>
    ${entry('explorer', 'The Forgotten Railway', '+420 XP', 'Sat 6 Sep · 32.4 km · 3 discoveries · 12.6 km new')}
    ${entry('wizard', 'Ley Lines', '+350 XP', 'Sun 31 Aug · 22.1 km · Rune Fragment · with Maya')}
    ${entry(null, 'Free ride · Thames east', '+90 XP', 'Wed 27 Aug · 18.0 km · 4.2 km new')}
    ${entry('explorer', 'The Lost Dockyards', '+280 XP', 'Sat 23 Aug · 17.6 km · 2 discoveries')}
  </div>
  ${tabbar('Journal')}
  <div class="home"></div>`;
};

// 11b — Character sheet
screens['09-character'] = () => `${status(true)}
  <div style="height:250px;background:${C.sage};color:${C.cream};padding:66px 22px 0;position:relative;overflow:hidden"><div style="position:absolute;inset:-60px -40px auto auto;width:320px;height:320px;border-radius:50%;background:repeating-radial-gradient(circle,transparent 0 11px,rgba(245,234,216,.12) 11px 12px)"></div><div style="position:relative;display:flex;gap:16px;align-items:center">${emblem('explorer', 84, true)}<div><div class="voice" style="font-size:30px;line-height:1">Amirali</div><div style="font-size:14px;font-weight:600;margin-top:4px">Explorer — Level 8</div><div style="font-size:12px;opacity:.85">“Wanderer” · Keeper of the South</div></div></div><div style="position:relative;margin-top:20px"><div style="display:flex;justify-content:space-between;font-size:12px;font-weight:600"><span>Explorer 8</span><span>1,820 / 2,200 XP</span></div><div style="height:8px;border-radius:4px;background:rgba(32,30,29,.25);margin-top:6px"><div style="width:83%;height:100%;border-radius:4px;background:${C.cream}"></div></div></div></div>
  <div class="sheet" style="margin-top:-26px;padding:18px 22px 0;display:flex;flex-direction:column;gap:14px;position:relative;box-shadow:none">
    <div style="display:flex;gap:8px"><div class="tile"><b>142 km²</b><span>Explored</span></div><div class="tile"><b>41</b><span>Discoveries</span></div><div class="tile"><b>19</b><span>Quests</span></div></div>
    <div style="display:flex;justify-content:space-between;align-items:baseline"><span class="voice" style="font-size:20px">Abilities</span><span style="font-size:12px;color:${C.muted}">2 of 4 unlocked</span></div>
    <div style="display:flex;gap:8px;flex-wrap:wrap"><span class="chip" style="padding:8px 12px;background:${C.sage};color:${C.cream};font-size:12.5px">Cartographer</span><span class="chip" style="padding:8px 12px;background:${C.sage};color:${C.cream};font-size:12.5px">Trail Sense</span><span class="chip" style="padding:8px 12px;border:1.5px dashed ${C.hatch};color:${C.muted};font-size:12.5px">Pathfinder · Lv 10</span><span class="chip" style="padding:8px 12px;border:1.5px dashed ${C.hatch};color:${C.muted};font-size:12.5px">Long Road · Lv 14</span></div>
    <div class="card" style="display:flex;flex-direction:column;gap:8px"><div style="display:flex;justify-content:space-between;align-items:baseline"><span style="font-weight:700;font-size:14px">Cycling profile</span><span style="font-size:11.5px;color:${C.muted}">Keeps quests suitable · separate from your level</span></div><div style="display:grid;grid-template-columns:1fr 1fr;gap:6px 14px;font-size:12.5px;color:${C.inkSoft}"><span>Typical ride <b>20–40 km</b></span><span>Climbing <b>Moderate</b></span><span>Gravel <b>Medium</b></span><span>Traffic <b>Low</b></span><span>Bike <b>Boardman ADV 8.8</b></span><span style="color:${C.terracottaDeep};font-weight:600">Adjust ›</span></div></div>
    <div style="display:flex;justify-content:space-between;align-items:baseline"><span class="voice" style="font-size:20px">Bikes</span></div>
    <div class="row" style="padding:10px 14px"><span style="width:36px;height:36px;border-radius:50%;background:${C.cream};display:inline-flex;align-items:center;justify-content:center">${icon(P.bike, { size: 16 })}</span><div style="flex:1"><div class="voice" style="font-size:17px">Boardman ADV 8.8</div><div style="font-size:12.5px;color:${C.muted}">Gravel · default · gravel ok</div></div>${icon(P.chevronRight, { color: C.muted, size: 14 })}</div>
  </div>
  ${tabbar('Character')}
  <div class="home"></div>`;

// 15b — Friends, the light feed
screens['11-friends'] = () => {
  const avatar = (letter, name, color) => `<div style="display:flex;flex-direction:column;align-items:center;gap:6px;font-size:12px"><span style="width:52px;height:52px;border-radius:50%;background:${color};display:flex;align-items:center;justify-content:center;color:${C.cream};font-family:Caprasimo,serif;font-size:20px">${letter}</span>${name}</div>`;
  const feed = (letter, color, html, meta, bg = C.surface, metaColor = C.muted) => `<div class="row" style="align-items:flex-start;background:${bg}"><span style="width:36px;height:36px;border-radius:50%;background:${color};display:flex;align-items:center;justify-content:center;color:${C.cream};font-family:Caprasimo,serif;flex:none">${letter}</span><div style="flex:1"><div style="font-size:13.5px">${html}</div><div style="font-size:12px;color:${metaColor}">${meta}</div></div></div>`;
  return `${status(false)}
  <div style="padding:66px 22px 0;display:flex;flex-direction:column;gap:14px">
    <div style="display:flex;justify-content:space-between;align-items:baseline"><span class="voice" style="font-size:32px">Friends</span><span style="font-size:13px;color:${C.terracottaDeep};font-weight:600">Add</span></div>
    <div class="row" style="justify-content:space-between;padding:12px 16px"><div><div style="font-weight:700;font-size:14px">Exact locations are never shared</div><div style="font-size:12px;color:${C.muted}">Friends see finished adventures, never where you are.</div></div><div style="display:flex;flex-direction:column;align-items:center;gap:4px;font-size:11px;font-weight:600;color:${C.muted}"><span style="width:40px;height:24px;border-radius:12px;background:${C.sage};position:relative"><span style="position:absolute;right:3px;top:3px;width:18px;height:18px;border-radius:50%;background:${C.cream}"></span></span>Visible</div></div>
    <div style="display:flex;gap:12px">${avatar('M', 'Maya', C.wizard)}${avatar('P', 'Parastoo', C.scribe)}${avatar('J', 'Jonah', C.terracotta)}${avatar('L', 'Lena', C.sage)}<div style="display:flex;flex-direction:column;align-items:center;gap:6px;font-size:12px;color:${C.muted}"><span style="width:52px;height:52px;border-radius:50%;border:1.5px dashed ${C.hatch};display:flex;align-items:center;justify-content:center">${icon(P.plus, { size: 20, color: C.muted })}</span>Invite</div></div>
    <div class="voice" style="font-size:20px;margin-top:4px">Look where people went</div>
    ${feed('M', C.wizard, '<b>Maya</b> completed <b>The Seven Bridges</b>', 'Yesterday · 41 km · 7 discoveries')}
    ${feed('A', C.sage, '<b>You</b> discovered <b>Greenwich Foot Tunnel</b>', 'Sat · Historical')}
    ${feed('P', C.scribe, '<b>Parastoo</b> explored <b>8.4 km of new territory</b>', 'Fri · Lewisham')}
    ${feed('✦', C.sage, '<b>Traveller encounter</b> · you crossed paths with Maya', 'Sat 14:02 · +10 XP each', C.sageTint, C.sageText)}
  </div>
  ${tabbar('Character')}
  <div class="home"></div>`;
};

// ---- Watch screens (7a / 16a) ------------------------------------------------------
const watchBase = `<meta charset="utf-8"><style>${fonts}
*{box-sizing:border-box;margin:0;padding:0}
body{width:198px;height:242px;overflow:hidden;background:transparent;font-family:-apple-system,"SF Pro",system-ui,sans-serif;color:#fff;-webkit-font-smoothing:antialiased}
.face{width:198px;height:242px;border-radius:48px;background:#000;padding:22px 18px 16px;display:flex;flex-direction:column;overflow:hidden;position:relative}
.time{position:absolute;top:10px;right:22px;font-size:12px;font-weight:600;color:${C.terracottaLight}}
</style>`;

const watch = {};

watch['w1-watch-navigation'] = () => `<div class="face" style="align-items:center;padding-top:20px"><span class="time">9:41</span>
  ${icon(P.turnLeft, { size: 44, color: C.terracottaLight, stroke: 3 })}
  <div style="font-size:46px;font-weight:700;line-height:1;letter-spacing:-.02em;margin-top:2px">180<span style="font-size:20px;font-weight:600">m</span></div>
  <div style="font-size:15px;font-weight:700;letter-spacing:.1em;margin-top:4px">LEFT</div>
  <div style="font-size:13px;color:${C.line};margin-top:2px;text-align:center">Rotherhithe St</div>
  <div style="margin-top:auto;font-size:14px;color:${C.line}"><b style="color:#fff">21.4</b> km/h</div>
</div>`;

watch['w2-watch-quest'] = () => `<div class="face"><span class="time">9:41</span>
  <div style="display:flex;align-items:center;gap:6px;font-size:11px;font-weight:700;letter-spacing:.08em;color:${C.sageLight}"><span style="width:10px;height:10px;transform:rotate(45deg);border-radius:2px;background:${C.sageLight}"></span>QUEST</div>
  <div style="font-size:15px;font-weight:600;margin-top:4px;color:${C.line};line-height:1.15">The Forgotten Railway</div>
  <div style="font-size:11px;color:${C.mutedLight};margin-top:12px">OBJECTIVE</div>
  <div style="font-size:19px;font-weight:600;line-height:1.15;margin-top:2px">Reach the old station</div>
  <div style="font-size:40px;font-weight:700;letter-spacing:-.02em;margin-top:auto;line-height:1">1.4<span style="font-size:18px;font-weight:600;color:${C.line}"> km</span></div>
  <div style="font-size:12px;color:${C.mutedLight}">2 of 3 objectives</div>
</div>`;

watch['w3-watch-stats'] = () => `<div class="face" style="padding:24px 20px 18px"><span class="time">9:41</span>
  <div style="font-size:11px;color:${C.mutedLight};font-weight:600;letter-spacing:.06em">RIDE</div>
  <div style="font-size:40px;font-weight:700;line-height:1;letter-spacing:-.02em;margin-top:4px">15.5<span style="font-size:16px;font-weight:600;color:${C.line}"> km</span></div>
  <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px 8px;margin-top:16px;font-size:18px;font-weight:600">
    <div>1:02:14<div style="font-size:10px;color:${C.mutedLight};font-weight:500">TIME</div></div>
    <div>↑ 186<div style="font-size:10px;color:${C.mutedLight};font-weight:500">CLIMBED</div></div>
    <div style="color:${C.heart}">146<div style="font-size:10px;color:${C.mutedLight};font-weight:500">BPM</div></div>
    <div style="color:${C.mutedLight}">19.2<div style="font-size:10px;color:${C.mutedLight};font-weight:500">KM/H</div></div>
  </div>
</div>`;

watch['w4-watch-objective-complete'] = () => `<div class="face" style="background:${C.sage};align-items:center;text-align:center;padding:24px 16px 16px">
  <div style="width:56px;height:56px;border-radius:50%;background:${C.cream};display:flex;align-items:center;justify-content:center">${icon(P.star, { size: 24, color: C.sage, fill: true })}</div>
  <div style="font-size:11px;font-weight:700;letter-spacing:.1em;margin-top:12px">OBJECTIVE COMPLETE</div>
  <div style="font-size:17px;font-weight:600;line-height:1.15;margin-top:4px">Old Pump House discovered</div>
  <div style="font-size:30px;font-weight:700;margin-top:auto;letter-spacing:-.02em">+50 XP</div>
</div>`;

watch['w5-watch-always-on'] = () => `<div class="face" style="align-items:center;padding-top:20px;color:rgba(255,255,255,.7)">
  ${icon(P.turnLeft, { size: 36, color: 'rgba(255,255,255,.7)', stroke: 2.5 })}
  <div style="font-size:42px;font-weight:500;line-height:1;letter-spacing:-.02em;margin-top:2px">180<span style="font-size:20px">m</span></div>
  <div style="font-size:14px;font-weight:600;letter-spacing:.1em;margin-top:4px">LEFT</div>
  <div style="margin-top:auto;font-size:14px;color:rgba(255,255,255,.5)">21 km/h</div>
</div>`;

// ---- Render --------------------------------------------------------------------
(async () => {
  const browser = await chromium.launch(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {});
  const shoot = async (name, html, isWatch) => {
    const page = await browser.newPage({ viewport: isWatch ? { width: 198, height: 242 } : { width: 402, height: 874 }, deviceScaleFactor: 2 });
    await page.setContent((isWatch ? watchBase : base) + html);
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: path.join(OUT, `${name}.png`), omitBackground: isWatch });
    await page.close();
    console.log('rendered', name);
  };
  for (const [name, fn] of Object.entries(screens)) await shoot(name, fn(), false);
  for (const [name, fn] of Object.entries(watch)) await shoot(name, fn(), true);
  await browser.close();
})();
