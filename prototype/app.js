/* TransportApp — интерактивный прототип на Яндекс Картах.
   Маршрут = начальная и конечная точки, без промежуточных остановок.
   Поиск: только «откуда» (все маршруты из этого места) или «откуда — куда».
   Оплата демонстрационная, сервера нет: брони хранятся в браузере. */

const CFG = window.CONFIG || {};
const D = window.DEMO;
const HAS_KEY = Boolean(CFG.yandexApiKey);
const YEREVAN = { center: [40.1830, 44.5100], bounds: [[40.05, 44.35], [40.27, 44.66]] };

const $ = (sel, root = document) => root.querySelector(sel);
const esc = s => String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const amd = n => Math.round(n).toLocaleString("ru-RU") + " ֏";
const hhmm = d => d.toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" });
const meters = m => m < 1000 ? `${Math.round(m / 10) * 10} м` : `${(m / 1000).toFixed(1)} км`;
const minutes = s => `${Math.max(1, Math.round(s / 60))} мин`;
const sleep = ms => new Promise(r => setTimeout(r, ms));

const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* приватный режим */ } }
};

const state = {
  tab: "search",
  from: null,   // { name, coords:[lat, lon] }
  to: null,
  day: 0,
  pick: null,   // "from" | "to" — ждём нажатия на карту
  bookings: store.get("ta2-bookings", []),
  sim: null
};
const saveBookings = () => store.set("ta2-bookings", state.bookings);

/* ---------- геометрия (координаты [широта, долгота]) ---------- */
const rad = x => x * Math.PI / 180;
function dist(a, b) {
  const dLat = rad(b[0] - a[0]), dLon = rad(b[1] - a[1]);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a[0])) * Math.cos(rad(b[0])) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(h));
}
function buildGeom(coords, durSec, trafficSec, source) {
  const cum = [0];
  for (let i = 1; i < coords.length; i++) cum.push(cum[i - 1] + dist(coords[i - 1], coords[i]));
  return { coords, cum, total: cum[cum.length - 1] || 1, durSec, trafficSec, source };
}
function pointAt(g, d) {
  if (d <= 0) return g.coords[0];
  if (d >= g.total) return g.coords[g.coords.length - 1];
  let i = 0;
  while (i < g.cum.length - 2 && g.cum[i + 1] < d) i++;
  const t = (d - g.cum[i]) / ((g.cum[i + 1] - g.cum[i]) || 1);
  const a = g.coords[i], b = g.coords[i + 1];
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
}
function subLine(g, d1, d2) {
  const out = [pointAt(g, d1)];
  g.cum.forEach((c, i) => { if (c > d1 && c < d2) out.push(g.coords[i]); });
  out.push(pointAt(g, d2));
  return out;
}
// Ближайшая к точке p позиция на линии маршрута: расстояние и пройденный путь от начала
function nearest(g, p) {
  const kx = 111320 * Math.cos(rad(p[0])), ky = 110540;
  let best = { d: Infinity, along: 0 };
  for (let i = 0; i < g.coords.length - 1; i++) {
    const a = g.coords[i], b = g.coords[i + 1];
    const ax = (a[1] - p[1]) * kx, ay = (a[0] - p[0]) * ky;
    const bx = (b[1] - p[1]) * kx, by = (b[0] - p[0]) * ky;
    const dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
    const t = l2 ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / l2)) : 0;
    const d = Math.hypot(ax + t * dx, ay + t * dy);
    if (d < best.d) best = { d, along: g.cum[i] + t * (g.cum[i + 1] - g.cum[i]) };
  }
  return best;
}

/* ---------- маршруты: Яндекс (с ключом) или OSRM (без ключа) ---------- */
const geoms = {};

function yandexRoute(route) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout")), 12000);
    const model = new ymaps.multiRouter.MultiRouteModel([route.from.coords, route.to.coords], { routingMode: "auto" });
    model.events.add("requestfail", () => { clearTimeout(timer); reject(new Error("requestfail")); });
    model.events.add("requestsuccess", () => {
      clearTimeout(timer);
      try {
        const r = model.getRoutes()[0];
        const coords = [];
        const push = list => list.forEach(c => {
          const last = coords[coords.length - 1];
          if (!last || last[0] !== c[0] || last[1] !== c[1]) coords.push(c);
        });
        r.getPaths().forEach(p => p.getSegments().forEach(s => {
          const geo = s.geometry;
          push(geo.getCoordinates ? geo.getCoordinates() : geo.coordinates);
        }));
        const dur = r.properties.get("duration");
        const traffic = r.properties.get("durationInTraffic") || dur;
        if (coords.length < 2) throw new Error("empty");
        resolve(buildGeom(coords, dur.value, traffic.value, "yandex"));
      } catch (e) { reject(e); }
    });
  });
}

async function osrmRoute(route) {
  const key = "ta2-osrm-" + route.from.coords.join(",") + ";" + route.to.coords.join(",");
  let coords = store.get(key, null);
  if (!coords) {
    const url = "https://router.project-osrm.org/route/v1/driving/" +
      `${route.from.coords[1]},${route.from.coords[0]};${route.to.coords[1]},${route.to.coords[0]}?overview=full&geometries=geojson`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(res.status);
    const json = await res.json();
    coords = json.routes[0].geometry.coordinates.map(([lon, lat]) => [lat, lon]);
    store.set(key, coords);
  }
  return buildGeom(coords, route.minutes * 60, null, "osrm");
}

async function loadRoute(route) {
  if (HAS_KEY) {
    try { return await yandexRoute(route); } catch (e) { console.warn("Маршрут Яндекса не построен, беру запасной", route.id, e); }
  }
  try { return await osrmRoute(route); } catch (e) { /* нет связи */ }
  return buildGeom([route.from.coords, route.to.coords], route.minutes * 60, null, "line");
}

/* ---------- расписание (демо) ---------- */
function hash(str) { let h = 5381; for (const c of str) h = ((h << 5) + h + c.charCodeAt(0)) >>> 0; return h; }
function dayStart(offset) { const d = new Date(); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() + offset); return d; }
function ymd(d) { return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; }
function dayLabel(offset) {
  if (offset === 0) return "Сегодня";
  if (offset === 1) return "Завтра";
  return dayStart(offset).toLocaleDateString("ru-RU", { weekday: "short", day: "numeric", month: "short" });
}
const routeById = id => D.routes.find(r => r.id === id);
const durOf = route => geoms[route.id] ? geoms[route.id].durSec : route.minutes * 60;

function tripsFor(route, dayOffset) {
  return D.departures.map(t => {
    const [h, m] = t.split(":").map(Number);
    const dep = dayStart(dayOffset);
    dep.setHours(h, m, 0, 0);
    const id = `${route.id}-${ymd(dep)}-${t}`;
    const seed = hash(id);
    const driver = D.drivers[seed % D.drivers.length];
    const total = 3 + (seed >>> 4) % 2;
    const takenDemo = (seed >>> 7) % total;
    const mine = state.bookings.filter(b => b.tripId === id && b.status === "paid").reduce((s, b) => s + b.seats, 0);
    return { id, route, dep, driver, total, taken: Math.min(total, takenDemo + mine) };
  });
}
function tripById(id) {
  const route = routeById(id.split("-")[0]);
  if (!route) return null;
  for (let d = -14; d < 3; d++) {
    const t = tripsFor(route, d).find(x => x.id === id);
    if (t) return t;
  }
  return null;
}
const timeAt = (trip, along) => new Date(trip.dep.getTime() + durOf(trip.route) * 1000 * (along / (geoms[trip.route.id] ? geoms[trip.route.id].total : 1)));

/* ---------- поиск ---------- */
function searchRoutes() {
  if (!state.from) return [];
  const res = [];
  D.routes.forEach(route => {
    const g = geoms[route.id];
    if (!g) return;
    const pick = nearest(g, state.from.coords);
    if (pick.d > D.nearMeters || pick.along > g.total - 300) return;
    let drop = null;
    if (state.to) {
      drop = nearest(g, state.to.coords);
      if (drop.d > D.nearMeters || drop.along < pick.along + 300) return;
    }
    res.push({ route, g, pick, drop });
  });
  return res.sort((a, b) => a.pick.d - b.pick.d);
}
function departuresFor(r) {
  const now = Date.now();
  return tripsFor(r.route, state.day)
    .map(trip => ({ trip, at: timeAt(trip, r.pick.along) }))
    .filter(x => x.at.getTime() > now + 5 * 60000);
}

/* ---------- карта ---------- */
let map = null;
const layers = { routes: {}, ends: null, segment: null, from: null, to: null, pickup: null };

const isDesktop = () => window.matchMedia("(min-width: 768px)").matches;
const margins = () => isDesktop() ? [40, 70, 40, 450] : [80, 30, Math.round(window.innerHeight * 0.64) + 10, 30];
function fit(coords) {
  if (!map || !coords || coords.length < 2) return;
  map.setBounds(ymaps.util.bounds.fromPoints(coords), { checkZoomRange: true, zoomMargin: margins(), duration: 400 });
}
const fitAll = () => fit(Object.values(geoms).flatMap(g => g.coords));

function focusRoute(id) {
  Object.entries(layers.routes).forEach(([rid, line]) => {
    line.options.set("strokeOpacity", !id || id === rid ? 0.9 : 0.15);
  });
}
function setSegment(coords, color) {
  if (layers.segment) { map.geoObjects.remove(layers.segment); layers.segment = null; }
  if (!coords) return;
  layers.segment = new ymaps.Polyline(coords, {}, { strokeColor: color || "#0f172a", strokeWidth: 9, strokeOpacity: 0.55 });
  map.geoObjects.add(layers.segment);
}
function setPointMarker(which) {
  if (layers[which]) { map.geoObjects.remove(layers[which]); layers[which] = null; }
  const p = state[which];
  if (!p) return;
  layers[which] = new ymaps.Placemark(p.coords, { hintContent: p.name }, {
    preset: which === "from" ? "islands#greenCircleDotIcon" : "islands#redCircleDotIcon"
  });
  map.geoObjects.add(layers[which]);
}
function setPickup(coords) {
  if (layers.pickup) { map.geoObjects.remove(layers.pickup); layers.pickup = null; }
  if (!coords) return;
  layers.pickup = new ymaps.Placemark(coords, { hintContent: "Здесь водитель может вас подобрать" }, { preset: "islands#blueCircleDotIcon" });
  map.geoObjects.add(layers.pickup);
}

function loadYmaps() {
  return new Promise((resolve, reject) => {
    const s = document.createElement("script");
    s.src = "https://api-maps.yandex.ru/2.1/?lang=ru_RU" + (HAS_KEY ? "&apikey=" + encodeURIComponent(CFG.yandexApiKey) : "");
    s.onload = () => ymaps.ready(resolve);
    s.onerror = () => reject(new Error("Яндекс Карты не загрузились"));
    document.head.appendChild(s);
  });
}

const ready = (async () => {
  await loadYmaps();
  map = new ymaps.Map("map", { center: YEREVAN.center, zoom: 12, controls: [] }, { suppressMapOpenBlock: false });
  const traffic = new ymaps.control.TrafficControl({ state: { providerKey: "traffic#actual", trafficShown: true } });
  map.controls.add(traffic, { float: "none", position: { top: 16, right: 16 } });
  map.controls.add("zoomControl", { size: "small", float: "none", position: { top: 70, right: 16 } });

  map.events.add("click", async e => {
    if (!state.pick) return;
    const which = state.pick;
    state.pick = null;
    const coords = e.get("coords");
    await setPlace(which, { name: "Точка на карте", coords });
    reverseName(coords).then(name => { if (name && state[which] && state[which].coords === coords) { state[which].name = name; if (state.tab === "search") renderSearch(); } });
  });

  const loaded = await Promise.all(D.routes.map((r, i) => sleep(i * 120).then(() => loadRoute(r))));
  D.routes.forEach((route, i) => {
    geoms[route.id] = loaded[i];
    const line = new ymaps.Polyline(loaded[i].coords, { hintContent: `${route.id}: ${route.from.name} → ${route.to.name}` }, {
      strokeColor: route.color, strokeWidth: 5, strokeOpacity: 0.9
    });
    line.events.add("click", () => { switchTab("routes"); showRoute(route); });
    layers.routes[route.id] = line;
    map.geoObjects.add(line);
  });
  const ends = new ymaps.GeoObjectCollection();
  const seen = new Set();
  D.routes.forEach(r => [r.from, r.to].forEach(p => {
    const k = p.coords.join(",");
    if (seen.has(k)) return;
    seen.add(k);
    const pm = new ymaps.Placemark(p.coords, { hintContent: p.name + " — нажмите, чтобы ехать отсюда" }, { preset: "islands#darkBlueCircleDotIcon" });
    pm.events.add("click", () => { setPlace("from", { name: p.name, coords: p.coords }); switchTab("search"); });
    ends.add(pm);
  }));
  layers.ends = ends;
  map.geoObjects.add(ends);
  fitAll();
})();
ready.catch(e => {
  $("#map").innerHTML = `<div class="empty" style="padding-top:80px">Не удалось загрузить Яндекс Карты. Проверьте интернет и обновите страницу.</div>`;
  console.error(e);
});

/* ---------- адреса ---------- */
async function setPlace(which, place) {
  state[which] = place;
  if (map) setPointMarker(which);
  if (state.tab === "search") renderSearch();
}
async function geocode(text) {
  if (!HAS_KEY || !window.ymaps) return [];
  try {
    const res = await ymaps.geocode(text, { boundedBy: YEREVAN.bounds, strictBounds: true, results: 5 });
    const out = [];
    res.geoObjects.each(o => out.push({ name: o.properties.get("name"), sub: o.properties.get("description"), coords: o.geometry.getCoordinates(), src: "Яндекс" }));
    return out;
  } catch { return []; }
}
async function reverseName(coords) {
  if (!HAS_KEY || !window.ymaps) return null;
  try {
    const res = await ymaps.geocode(coords, { results: 1 });
    const o = res.geoObjects.get(0);
    return o ? o.properties.get("name") : null;
  } catch { return null; }
}
function localPlaces(text) {
  const q = text.trim().toLowerCase();
  if (!q) return [];
  return D.places.filter(p => p.name.toLowerCase().includes(q)).slice(0, 5).map(p => ({ ...p, src: "место" }));
}

/* ---------- интерфейс ---------- */
const view = $("#view");
function toast(text) {
  const t = $("#toast");
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { t.hidden = true; }, 3500);
}
function modal(html) { $("#modal-card").innerHTML = html; $("#modal").hidden = false; }
const closeModal = () => { $("#modal").hidden = true; };
$("#modal").addEventListener("click", e => { if (e.target.id === "modal") closeModal(); });

function clearMapFocus() {
  if (!map) return;
  setSegment(null);
  setPickup(null);
  focusRoute(null);
}
function switchTab(tab) {
  stopSim();
  state.tab = tab;
  state.pick = null;
  document.querySelectorAll(".tabs button").forEach(b => b.classList.toggle("active", b.dataset.tab === tab));
  clearMapFocus();
  if (tab === "search") renderSearch();
  if (tab === "routes") renderRoutes();
  if (tab === "mine") renderMine();
}
document.querySelectorAll(".tabs button").forEach(b => b.addEventListener("click", () => switchTab(b.dataset.tab)));

const ICON_GEO = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><circle cx="12" cy="12" r="4"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/></svg>';
const ICON_PIN = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M12 21s7-6.2 7-11.5A7 7 0 0 0 5 9.5C5 14.8 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/></svg>';
const ICON_SWAP = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M7 4v16M7 4l-3 3M7 4l3 3M17 20V4M17 20l-3-3M17 20l3-3"/></svg>';

function renderSearch() {
  view.innerHTML = `
    <h2>Куда поедем?</h2>
    <div class="where">
      <div class="loc"><span class="dot from"></span><input id="in-from" autocomplete="off" placeholder="Откуда — адрес или место" value="${state.from ? esc(state.from.name) : ""}">${state.from ? '<button class="clear" data-clear="from" aria-label="Очистить">×</button>' : ""}</div>
      <div class="loc"><span class="dot to"></span><input id="in-to" autocomplete="off" placeholder="Куда — можно не указывать" value="${state.to ? esc(state.to.name) : ""}">${state.to ? '<button class="clear" data-clear="to" aria-label="Очистить">×</button>' : ""}</div>
      <button class="swap" id="swap" title="Поменять местами" aria-label="Поменять местами">${ICON_SWAP}</button>
    </div>
    <div id="sugg"></div>
    <div class="quick">
      <button class="pill" id="geo">${ICON_GEO} Я здесь</button>
      <button class="pill ${state.pick === "from" ? "on" : ""}" data-pick="from">${ICON_PIN} Откуда на карте</button>
      <button class="pill ${state.pick === "to" ? "on" : ""}" data-pick="to">${ICON_PIN} Куда на карте</button>
    </div>
    <div class="chips">${[0, 1, 2].map(d => `<button class="chip ${d === state.day ? "active" : ""}" data-day="${d}">${dayLabel(d)}</button>`).join("")}</div>
    <button class="btn" id="go" ${state.from ? "" : "disabled"}>Показать маршруты</button>
    <p class="muted small" style="margin-top:12px">Достаточно указать «откуда» — покажем все маршруты, которые начинаются или проходят рядом. Начальную точку маршрута можно выбрать и на карте.</p>
    ${HAS_KEY ? "" : '<div class="note">Ключ Яндекс Карт не задан: пробки видны, но маршруты построены упрощённо, а адреса ищутся только по списку мест. Как добавить ключ — в README.</div>'}`;

  bindInput("from");
  bindInput("to");
  view.querySelectorAll("[data-clear]").forEach(b => b.onclick = () => { const w = b.dataset.clear; state[w] = null; if (map) setPointMarker(w); renderSearch(); });
  $("#swap").onclick = () => { [state.from, state.to] = [state.to, state.from]; if (map) { setPointMarker("from"); setPointMarker("to"); } renderSearch(); };
  $("#geo").onclick = locateMe;
  view.querySelectorAll("[data-pick]").forEach(b => b.onclick = () => {
    state.pick = state.pick === b.dataset.pick ? null : b.dataset.pick;
    if (state.pick) toast(state.pick === "from" ? "Нажмите на карту, откуда поедете" : "Нажмите на карту, куда поедете");
    renderSearch();
  });
  view.querySelectorAll("[data-day]").forEach(b => b.onclick = () => { state.day = +b.dataset.day; renderSearch(); });
  $("#go").onclick = async () => { await ready; renderResults(); };
}

function bindInput(which) {
  const input = $("#in-" + which);
  let timer = 0;
  input.addEventListener("input", () => {
    clearTimeout(timer);
    timer = setTimeout(async () => {
      const text = input.value;
      const local = localPlaces(text);
      showSugg(which, local);
      if (HAS_KEY && text.trim().length > 2) {
        const remote = await geocode("Ереван, " + text);
        if (input.value === text) showSugg(which, [...local, ...remote].slice(0, 7));
      }
    }, 220);
  });
  input.addEventListener("focus", () => { if (!input.value) showSugg(which, D.places.slice(0, 5).map(p => ({ ...p, src: "место" }))); });
}
function showSugg(which, list) {
  const box = $("#sugg");
  if (!box) return;
  if (!list.length) { box.innerHTML = ""; return; }
  box.innerHTML = `<div class="sugg">${list.map((p, i) => `<button data-i="${i}">${ICON_PIN}<span>${esc(p.name)}${p.sub ? `<br><span class="tiny muted">${esc(p.sub)}</span>` : ""}</span><span class="src">${esc(p.src || "")}</span></button>`).join("")}</div>`;
  box.querySelectorAll("button").forEach(b => b.onclick = () => {
    const p = list[+b.dataset.i];
    setPlace(which, { name: p.name, coords: p.coords });
  });
}
function locateMe() {
  if (!navigator.geolocation) { toast("Браузер не умеет определять местоположение."); return; }
  toast("Определяем местоположение…");
  navigator.geolocation.getCurrentPosition(pos => {
    const coords = [pos.coords.latitude, pos.coords.longitude];
    if (dist(coords, YEREVAN.center) > 40000) toast("Вы далеко от Еревана — маршрутов рядом не будет. Выберите точку на карте.");
    setPlace("from", { name: "Моё местоположение", coords });
  }, () => toast("Не удалось определить местоположение. Выберите точку на карте."), { timeout: 8000 });
}

function routeFacts(r, g) {
  const parts = [`<span>в пути <b>~${minutes(g.durSec)}</b></span>`, `<span>${meters(g.total)}</span>`];
  if (g.trafficSec) parts.push(`<span class="traffic">сейчас с пробками ${minutes(g.trafficSec)}</span>`);
  return parts.join("");
}

function renderResults() {
  const list = searchRoutes();
  clearMapFocus();
  view.innerHTML = `
    <button class="link back" id="back">← Изменить поиск</button>
    <h2>${list.length ? `Маршруты рядом: ${list.length}` : "Маршрутов рядом нет"}</h2>
    <div class="timeline" style="margin-bottom:12px">
      <span class="dot from"></span><span>${esc(state.from.name)}</span><span></span>
      <span class="dot to"></span><span>${state.to ? esc(state.to.name) : '<span class="muted">любое направление</span>'}</span><span></span>
    </div>
    ${list.length ? "" : `<div class="empty">Рядом с этой точкой нет маршрутов${state.to ? " в нужную сторону" : ""}. Попробуйте точку ближе к линиям на карте или откройте «Маршруты».</div>`}
    <div id="list"></div>`;
  $("#back").onclick = renderSearch;
  const box = $("#list");
  const coordsToFit = [state.from.coords];
  if (state.to) coordsToFit.push(state.to.coords);
  list.forEach(r => {
    const deps = departuresFor(r);
    const card = document.createElement("div");
    card.className = "route-card";
    card.style.setProperty("--c", r.route.color);
    const walk = r.pick.d < 120 ? "маршрут начинается рядом" : `до маршрута ${meters(r.pick.d)} пешком`;
    card.innerHTML = `
      <div class="route-head">
        <span class="code">${r.route.id}</span>
        <div>
          <div class="route-title">${esc(r.route.from.name)} → ${esc(r.route.to.name)}</div>
          <div class="small muted">${walk}</div>
        </div>
        <span class="price">${amd(r.route.price)}</span>
      </div>
      <div class="facts">${routeFacts(r.route, r.g)}</div>
      <div class="deps">${deps.length ? deps.map((x, i) => {
        const free = x.trip.total - x.trip.taken;
        return `<button class="dep ${free ? "" : "full"}" data-i="${i}" ${free ? "" : "disabled"}><span class="t">${hhmm(x.at)}</span><span class="s">${free ? `мест: ${free}` : "мест нет"}</span></button>`;
      }).join("") : '<span class="small muted">На этот день рейсов больше нет</span>'}</div>`;
    card.querySelectorAll(".dep[data-i]").forEach(b => b.onclick = () => renderTrip(r, deps[+b.dataset.i].trip));
    card.addEventListener("mouseenter", () => focusRoute(r.route.id));
    card.addEventListener("mouseleave", () => focusRoute(null));
    box.appendChild(card);
    coordsToFit.push(...r.g.coords);
  });
  fit(coordsToFit);
}

function money(price, seats) {
  const total = price * seats;
  const fee = total * D.commissionPercent / 100;
  const duty = total * D.statePercent / 100;
  return { total, fee, duty, driver: total - fee - duty };
}
const initials = name => name.slice(0, 1).toUpperCase();

function driverCard(trip) {
  const d = trip.driver;
  return `<div class="driver" style="--c:${trip.route.color}">
    <div class="avatar">${esc(initials(d.name))}</div>
    <div style="flex:1">
      <div class="row"><strong>${esc(d.name)}</strong><span class="small">★ ${d.rating} · ${d.trips} поездок</span></div>
      <div class="small muted">${esc(d.car)}, ${esc(d.color)}</div>
      <div class="row" style="margin-top:4px"><span class="plate">${esc(d.plate)}</span>${d.verified ? '<span class="verified">✓ документы проверены</span>' : '<span class="tiny muted">документы на проверке</span>'}</div>
    </div>
  </div>`;
}

function renderTrip(r, trip, seats = 1) {
  const g = r.g;
  const free = trip.total - trip.taken;
  seats = Math.max(1, Math.min(seats, free, 4));
  const dropAlong = r.drop ? r.drop.along : g.total;
  const pickAt = timeAt(trip, r.pick.along), dropAt = timeAt(trip, dropAlong);
  const seg = subLine(g, r.pick.along, dropAlong);
  focusRoute(r.route.id);
  setSegment(seg, r.route.color);
  setPickup(pointAt(g, r.pick.along));
  fit([...seg, state.from.coords]);
  const m = money(r.route.price, seats);
  view.innerHTML = `
    <button class="link back" id="back">← К маршрутам</button>
    <h2>${esc(r.route.from.name)} → ${esc(r.route.to.name)}</h2>
    <div class="timeline">
      <span class="dot from"></span><span>Посадка рядом с вами${r.pick.d >= 120 ? ` · ${meters(r.pick.d)} пешком` : ""}</span><span class="tm">≈ ${hhmm(pickAt)}</span>
      <span class="dot to"></span><span>${r.drop ? `Высадка рядом с «${esc(state.to.name)}»` : esc(r.route.to.name)}</span><span class="tm">≈ ${hhmm(dropAt)}</span>
    </div>
    <p class="tiny muted">Водитель выезжает из точки «${esc(r.route.from.name)}» в ${hhmm(trip.dep)}${g.trafficSec ? ". Время посадки посчитано с учётом сегодняшних пробок" : ""}.</p>
    ${driverCard(trip)}
    <div class="note">Где именно вас подобрать и высадить, договоритесь с водителем: его телефон появится в брони в день поездки.</div>
    ${free > 0 ? `
      <h3>Сколько мест?</h3>
      <div class="stepper"><button id="minus" aria-label="Меньше">−</button><strong>${seats}</strong><button id="plus" aria-label="Больше">+</button><span class="muted small">свободно ${free}</span></div>
      <div class="breakdown">
        <div class="row"><span>${seats} × ${amd(r.route.price)}</span><strong>${amd(m.total)}</strong></div>
        <div class="row muted"><span>Водителю</span><span>${amd(m.driver)}</span></div>
        <div class="row muted"><span>Комиссия сервиса ${D.commissionPercent}%</span><span>${amd(m.fee)}</span></div>
        <div class="row muted"><span>Госпошлина ${D.statePercent}%</span><span>${amd(m.duty)}</span></div>
        <div class="tiny muted" style="margin-top:6px">Разбивка видна только в прототипе. Комиссия 10% — пример.</div>
      </div>
      <button class="btn" id="pay">Оплатить картой ${amd(m.total)}</button>
      <p class="muted tiny" style="text-align:center">Бесплатная отмена — не позднее чем за 60 минут до посадки</p>`
      : `<div class="empty">На этот рейс мест нет.</div>`}`;
  $("#back").onclick = renderResults;
  if (free > 0) {
    $("#minus").onclick = () => renderTrip(r, trip, seats - 1);
    $("#plus").onclick = () => renderTrip(r, trip, seats + 1);
    $("#pay").onclick = () => payDemo(r, trip, seats, m.total);
  }
}

function payDemo(r, trip, seats, total) {
  modal(`
    <h2>Оплата картой</h2>
    <p>Это демо: деньги не списываются.</p>
    <p class="muted small">В рабочей версии здесь откроется защищённая страница банка для карт ArCa, Visa и Mastercard. Приложение не хранит данные карты.</p>
    <p>К оплате: <strong>${amd(total)}</strong></p>
    <button class="btn" id="confirm">Подтвердить демо-оплату</button>
    <button class="btn secondary" id="cancel">Отмена</button>`);
  $("#cancel").onclick = closeModal;
  $("#confirm").onclick = () => {
    const b = {
      id: "B" + Date.now().toString(36).toUpperCase(),
      tripId: trip.id, routeId: r.route.id,
      pickAlong: r.pick.along, dropAlong: r.drop ? r.drop.along : r.g.total,
      fromName: state.from.name, toName: state.to ? state.to.name : r.route.to.name,
      seats, amount: total, status: "paid", rating: null
    };
    state.bookings.unshift(b);
    saveBookings();
    closeModal();
    toast("Оплата прошла (демо). Место забронировано.");
    renderTicket(b);
  };
}

function statusBadge(b) {
  if (b.status === "paid") return '<span class="status ok">Оплачено</span>';
  if (b.status === "done") return '<span class="status done">Завершена</span>';
  return `<span class="status off">${b.refund ? "Возврат " + amd(b.refund) : "Отменено без возврата"}</span>`;
}

function renderTicket(b) {
  stopSim();
  const trip = tripById(b.tripId);
  const g = geoms[b.routeId];
  if (!trip) { view.innerHTML = `<button class="link back" id="back">← Мои поездки</button><div class="empty">Рейс больше не в расписании.</div>`; $("#back").onclick = () => switchTab("mine"); return; }
  if (!g) { view.innerHTML = '<div class="empty">Загрузка карты…</div>'; ready.then(() => renderTicket(b)); return; }
  const pickAt = timeAt(trip, b.pickAlong), dropAt = timeAt(trip, b.dropAlong);
  const seg = subLine(g, b.pickAlong, b.dropAlong);
  focusRoute(b.routeId);
  setSegment(seg, trip.route.color);
  setPickup(pointAt(g, b.pickAlong));
  fit(seg);
  const minsLeft = (pickAt - Date.now()) / 60000;
  const dayOff = Math.round((new Date(trip.dep).setHours(0, 0, 0, 0) - dayStart(0).getTime()) / 864e5);
  view.innerHTML = `
    <button class="link back" id="back">← Мои поездки</button>
    <div class="row"><h2>Бронь ${esc(b.id)}</h2>${statusBadge(b)}</div>
    <div class="timeline">
      <span class="dot from"></span><span>${esc(b.fromName)}</span><span class="tm">≈ ${hhmm(pickAt)}</span>
      <span class="dot to"></span><span>${esc(b.toName)}</span><span class="tm">≈ ${hhmm(dropAt)}</span>
    </div>
    <p class="small muted">${dayLabel(dayOff)} · маршрут ${trip.route.id} · мест: ${b.seats} · ${amd(b.amount)}</p>
    ${driverCard(trip)}
    ${b.status === "paid" ? `
      <div class="note">Телефон водителя: появится в день поездки (в прототипе не показывается).</div>
      <button class="btn" id="track">Следить за машиной</button>
      <button class="btn danger" id="cancelb">Отменить бронь</button>
      <p class="muted tiny" style="text-align:center">${minsLeft >= 60 ? "Сейчас отмена бесплатная — деньги вернутся на карту." : "До посадки меньше 60 минут — при отмене деньги не возвращаются."}</p>` : ""}
    ${b.status === "done" && !b.rating ? rateBlock() : ""}
    ${b.rating ? `<p class="muted small">Ваша оценка: ${"★".repeat(b.rating)}</p>` : ""}`;
  $("#back").onclick = () => switchTab("mine");
  if (b.status === "paid") {
    $("#track").onclick = () => startSim(trip, b);
    $("#cancelb").onclick = () => cancelBooking(b, minsLeft);
  }
  bindRate(b);
}

function cancelBooking(b, minsLeft) {
  const free = minsLeft >= 60;
  modal(`
    <h2>Отменить бронь?</h2>
    <p>${free ? `Вернём ${amd(b.amount)} на карту.` : "До посадки меньше 60 минут. Деньги не вернутся — водитель получит свою долю."}</p>
    <button class="btn danger" id="yes">Отменить бронь</button>
    <button class="btn secondary" id="no">Не отменять</button>`);
  $("#no").onclick = closeModal;
  $("#yes").onclick = () => {
    b.status = "cancelled";
    b.refund = free ? b.amount : 0;
    saveBookings();
    closeModal();
    toast(free ? "Бронь отменена, деньги вернутся на карту (демо)." : "Бронь отменена без возврата.");
    renderTicket(b);
  };
}

function rateBlock() {
  return `<h3>Оцените водителя</h3>
    <div class="stars" id="stars">${[1, 2, 3, 4, 5].map(n => `<button data-n="${n}" aria-label="${n}">★</button>`).join("")}</div>
    <p class="muted tiny">Водитель увидит оценку, когда тоже оценит поездку или через 14 дней.</p>`;
}
function bindRate(b) {
  const box = $("#stars");
  if (!box) return;
  box.querySelectorAll("button").forEach(btn => {
    btn.onmouseenter = () => box.querySelectorAll("button").forEach(x => x.classList.toggle("on", +x.dataset.n <= +btn.dataset.n));
    btn.onclick = () => { b.rating = +btn.dataset.n; saveBookings(); toast("Спасибо за оценку!"); renderTicket(b); };
  });
}

function showRoute(route) {
  focusRoute(route.id);
  if (geoms[route.id]) fit(geoms[route.id].coords);
}

function renderRoutes() {
  view.innerHTML = `<h2>Маршруты</h2><p class="muted small">Маршрут — это начальная и конечная точки. Где подсесть по пути, пассажир договаривается с водителем. Цены — демо.</p><div id="list"></div>`;
  const box = $("#list");
  D.routes.forEach(route => {
    const g = geoms[route.id];
    const card = document.createElement("div");
    card.className = "route-card";
    card.style.setProperty("--c", route.color);
    card.innerHTML = `
      <div class="route-head">
        <span class="code">${route.id}</span>
        <div class="ends"><span class="dot from"></span><span>${esc(route.from.name)}</span><span class="dot to"></span><span>${esc(route.to.name)}</span></div>
        <span class="price">${amd(route.price)}</span>
      </div>
      <div class="facts">${g ? routeFacts(route, g) : '<span>загрузка…</span>'}</div>
      <div class="quick">
        <button class="pill" data-a="from">Ехать отсюда</button>
        <button class="pill" data-a="sim">Показать движение машины</button>
      </div>`;
    card.addEventListener("click", e => {
      const a = e.target.closest("[data-a]");
      if (!a) { showRoute(route); return; }
      if (a.dataset.a === "from") { setPlace("from", { ...route.from }); state.to = null; if (map) setPointMarker("to"); switchTab("search"); ready.then(renderResults); }
      if (a.dataset.a === "sim") ready.then(() => startSim({ ...tripsFor(route, 0)[0], dep: new Date() }, null));
    });
    box.appendChild(card);
  });
  ready.then(() => { if (state.tab === "routes") fitAll(); });
}

function renderMine() {
  const list = state.bookings;
  view.innerHTML = `<h2>Мои поездки</h2>
    ${list.length ? "" : '<div class="empty">Пока нет броней. Найдите поездку на вкладке «Поиск».</div>'}
    <div id="list"></div>`;
  const box = $("#list");
  list.forEach(b => {
    const trip = tripById(b.tripId);
    const card = document.createElement("div");
    card.className = "trip-card";
    const at = trip && geoms[b.routeId] ? timeAt(trip, b.pickAlong) : trip ? trip.dep : null;
    card.innerHTML = trip ? `
      <div class="row"><strong>${hhmm(at)} · ${at.toLocaleDateString("ru-RU", { day: "numeric", month: "long" })}</strong>${statusBadge(b)}</div>
      <div class="small">${esc(b.fromName)} → ${esc(b.toName)}</div>
      <div class="tiny muted">Маршрут ${b.routeId} · мест: ${b.seats} · ${amd(b.amount)}</div>`
      : `<div class="small muted">Бронь ${esc(b.id)}: рейс вне расписания</div>`;
    card.onclick = () => renderTicket(b);
    box.appendChild(card);
  });
}

/* ---------- симуляция движения ---------- */
function stopSim() {
  if (!state.sim) return;
  cancelAnimationFrame(state.sim.raf);
  map.geoObjects.remove(state.sim.car);
  state.sim = null;
}

function startSim(trip, booking) {
  stopSim();
  const route = trip.route, g = geoms[route.id];
  const speed = g.total / (g.trafficSec || g.durSec); // м/с
  const car = new ymaps.Placemark(g.coords[0], { hintContent: `${trip.driver.car}, ${trip.driver.plate}` }, { preset: "islands#autoCircleIcon", iconColor: route.color });
  map.geoObjects.add(car);
  state.sim = { trip, booking, pos: 0, speed, factor: 10, car, last: performance.now(), raf: 0, boarded: false, g, route };
  focusRoute(route.id);
  if (booking) { setSegment(subLine(g, booking.pickAlong, booking.dropAlong), route.color); setPickup(pointAt(g, booking.pickAlong)); }
  else { setSegment(null); setPickup(null); }
  fit(g.coords);

  view.innerHTML = `
    <button class="link back" id="back">← Назад</button>
    <h2>${esc(route.from.name)} → ${esc(route.to.name)}</h2>
    <p class="muted tiny">Симуляция: машина едет по линии маршрута без реального GPS.</p>
    <div class="eta" id="eta">…</div>
    <div class="muted small" id="eta2"></div>
    <div class="progress"><i id="bar"></i></div>
    <h3>Скорость симуляции</h3>
    <div class="chips">${[1, 10, 30].map(f => `<button class="chip ${f === 10 ? "active" : ""}" data-f="${f}">×${f}</button>`).join("")}</div>
    <div id="after"></div>`;
  $("#back").onclick = () => { stopSim(); booking ? renderTicket(booking) : switchTab("routes"); };
  view.querySelectorAll("[data-f]").forEach(b => b.onclick = () => {
    state.sim.factor = +b.dataset.f;
    view.querySelectorAll("[data-f]").forEach(x => x.classList.toggle("active", x === b));
  });

  let lastText = 0;
  const tick = now => {
    const s = state.sim;
    if (!s) return;
    const dt = Math.min(0.25, (now - s.last) / 1000);
    s.last = now;
    s.pos = Math.min(g.total, s.pos + s.speed * dt * s.factor);
    s.car.geometry.setCoordinates(pointAt(g, s.pos));
    if (now - lastText > 200) { lastText = now; updateEta(s); }
    if (s.pos >= g.total) { updateEta(s); finishSim(s); return; }
    s.raf = requestAnimationFrame(tick);
  };
  state.sim.raf = requestAnimationFrame(tick);
}

function updateEta(s) {
  const eta = $("#eta"), eta2 = $("#eta2"), bar = $("#bar");
  if (!eta) return;
  const left = d => (d - s.pos) / s.speed;
  if (bar) bar.style.width = (100 * s.pos / s.g.total).toFixed(1) + "%";
  const d = s.trip.driver;
  if (s.booking) {
    const b = s.booking;
    if (s.pos < b.pickAlong - 10) {
      eta.textContent = `Машина подъедет через ${minutes(left(b.pickAlong))}`;
      eta2.textContent = `${d.car}, ${d.color}, ${d.plate}`;
    } else if (s.pos < b.dropAlong - 10) {
      if (!s.boarded) { s.boarded = true; toast("Водитель отметил: вы сели (демо)."); }
      eta.textContent = `В пути: до места ${minutes(left(b.dropAlong))}`;
      eta2.textContent = b.toName;
    } else {
      eta.textContent = "Вы приехали";
      eta2.textContent = b.toName;
    }
  } else {
    eta.textContent = s.pos < s.g.total ? `До «${s.route.to.name}» ${minutes(left(s.g.total))}` : `Машина приехала: «${s.route.to.name}»`;
    eta2.textContent = `${meters(s.pos)} из ${meters(s.g.total)}`;
  }
}

function finishSim(s) {
  const b = s.booking;
  if (b && b.status === "paid") {
    b.status = "done";
    saveBookings();
    toast("Поездка завершена. Оцените водителя.");
    const after = $("#after");
    if (after) after.innerHTML = rateBlock();
    bindRate(b);
  }
}

/* ---------- старт ---------- */
renderSearch();
