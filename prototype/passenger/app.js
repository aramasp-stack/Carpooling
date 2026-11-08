/* TransportApp — интерактивный прототип на Яндекс Картах.
   Маршрут = начальная и конечная точки, без промежуточных остановок.
   Поиск: при открытии карта пустая; после «откуда» появляются маршруты рядом;
   после «куда» остаётся один маршрут и список водителей на нём.
   В машине — схема салона: у каждого места своя цена. Пассажир видит одну итоговую цену.
   Оплата демонстрационная, сервера нет: брони хранятся в браузере. */

const state = {
  tab: "search",
  from: null,      // { name, coords:[lat, lon] }
  to: null,
  routeId: null,   // маршрут, выбранный из списка, когда указано только «откуда»
  day: 0,
  pick: null,      // "from" | "to" — ждём нажатия на карту
  sim: null
};
/* ---------- поиск ---------- */
function matchRoutes() {
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
    res.push({ route, g, pick, drop, score: pick.d + (drop ? drop.d : 0) });
  });
  return res.sort((a, b) => a.score - b.score);
}
// Когда указаны «откуда» и «куда» — остаётся один, самый подходящий маршрут
function activeMatch(matches) {
  if (state.to) return matches[0] || null;
  if (state.routeId) return matches.find(m => m.route.id === state.routeId) || null;
  return null;
}
function driversFor(m) {
  const now = Date.now();
  return tripsFor(m.route, state.day)
    .map(trip => ({ trip, at: timeAt(trip, m.pick.along) }))
    .filter(x => x.at.getTime() > now + 5 * 60000);
}

/* ---------- карта ---------- */
let map = null;
const layers = { routes: {}, shown: new Set(), ends: null, endsShown: false, segment: null, from: null, to: null, pickup: null };

const isDesktop = () => window.matchMedia("(min-width: 768px)").matches;
const margins = () => isDesktop() ? [40, 70, 40, 450] : [80, 30, Math.round(window.innerHeight * 0.64) + 10, 30];
function fit(coords) {
  if (!map || !coords || !coords.length) return;
  if (coords.length === 1) { map.setCenter(coords[0], 14, { duration: 300 }); return; }
  map.setBounds(ymaps.util.bounds.fromPoints(coords), { checkZoomRange: true, zoomMargin: margins(), duration: 400 });
}
function showLines(ids) {
  if (!map) return;
  const want = new Set(ids);
  Object.entries(layers.routes).forEach(([id, line]) => {
    if (want.has(id) && !layers.shown.has(id)) { map.geoObjects.add(line); layers.shown.add(id); }
    if (!want.has(id) && layers.shown.has(id)) { map.geoObjects.remove(line); layers.shown.delete(id); }
    line.options.set("strokeOpacity", 0.9);
  });
}
function showEnds(on) {
  if (!map || !layers.ends || layers.endsShown === on) return;
  if (on) map.geoObjects.add(layers.ends); else map.geoObjects.remove(layers.ends);
  layers.endsShown = on;
}
function setSegment(coords, color) {
  if (!map) return;
  if (layers.segment) { map.geoObjects.remove(layers.segment); layers.segment = null; }
  if (!coords) return;
  layers.segment = new ymaps.Polyline(coords, {}, { strokeColor: color || "#0f172a", strokeWidth: 9, strokeOpacity: 0.5 });
  map.geoObjects.add(layers.segment);
}
function setPointMarker(which) {
  if (!map) return;
  if (layers[which]) { map.geoObjects.remove(layers[which]); layers[which] = null; }
  const p = state[which];
  if (!p) return;
  layers[which] = new ymaps.Placemark(p.coords, { hintContent: p.name }, {
    preset: which === "from" ? "islands#greenCircleDotIcon" : "islands#redCircleDotIcon"
  });
  map.geoObjects.add(layers[which]);
}
function setPickup(coords) {
  if (!map) return;
  if (layers.pickup) { map.geoObjects.remove(layers.pickup); layers.pickup = null; }
  if (!coords) return;
  layers.pickup = new ymaps.Placemark(coords, { hintContent: "Здесь водитель может вас подобрать" }, { preset: "islands#blueCircleDotIcon" });
  map.geoObjects.add(layers.pickup);
}
function clearMap() {
  showLines([]);
  showEnds(false);
  setSegment(null);
  setPickup(null);
}

const ready = (async () => {
  await loadYmaps();
  map = new ymaps.Map("map", { center: YEREVAN.center, zoom: 12, controls: [] }, { suppressMapOpenBlock: false });
  const traffic = new ymaps.control.TrafficControl({ state: { providerKey: "traffic#actual", trafficShown: true } });
  map.controls.add(traffic, { float: "none", position: { top: CTRL_TOP, right: 16 } });
  map.controls.add("zoomControl", { size: "small", float: "none", position: { top: CTRL_TOP + 54, right: 16 } });

  map.events.add("click", e => {
    if (!state.pick) return;
    const which = state.pick;
    state.pick = null;
    const coords = e.get("coords");
    setPlace(which, { name: "Точка на карте", coords });
    reverseName(coords).then(name => {
      if (name && state[which] && state[which].coords === coords) { state[which].name = name; if (state.tab === "search") renderSearch(); }
    });
  });

  const loaded = await Promise.all(D.routes.map((r, i) => sleep(i * 120).then(() => loadRoute(r))));
  D.routes.forEach((route, i) => {
    geoms[route.id] = loaded[i];
    layers.routes[route.id] = new ymaps.Polyline(loaded[i].coords, { hintContent: `${route.from.name} → ${route.to.name}` }, {
      strokeColor: route.color, strokeWidth: 6, strokeOpacity: 0.9
    });
  });
  const ends = new ymaps.GeoObjectCollection();
  const seen = new Set();
  D.routes.forEach(r => [r.from, r.to].forEach(p => {
    const k = p.coords.join(",");
    if (seen.has(k)) return;
    seen.add(k);
    ends.add(new ymaps.Placemark(p.coords, { hintContent: p.name }, { preset: "islands#darkBlueCircleDotIcon" }));
  }));
  layers.ends = ends;
  refreshMapForTab();
})();
ready.catch(e => {
  $("#map").innerHTML = `<div class="empty" style="padding-top:80px">Не удалось загрузить Яндекс Карты. Проверьте интернет и обновите страницу.</div>`;
  console.error(e);
});

function refreshMapForTab() {
  if (!map) return;
  if (state.tab === "search") updateSearchMap();
  if (state.tab === "routes") { clearMap(); showLines(D.routes.map(r => r.id)); showEnds(true); fit(Object.values(geoms).flatMap(g => g.coords)); }
}

// Карта на вкладке «Поиск»: пустая → маршруты рядом с «откуда» → один маршрут
function updateSearchMap() {
  if (!map) return;
  setSegment(null);
  setPickup(null);
  showEnds(false);
  setPointMarker("from");
  setPointMarker("to");
  const matches = matchRoutes();
  const active = activeMatch(matches);
  if (!state.from) { showLines([]); map.setCenter(YEREVAN.center, 12, { duration: 300 }); return; }
  if (active) {
    showLines([active.route.id]);
    const end = active.drop ? active.drop.along : active.g.total;
    setSegment(subLine(active.g, active.pick.along, end), active.route.color);
    setPickup(pointAt(active.g, active.pick.along));
    fit([...active.g.coords, state.from.coords, ...(state.to ? [state.to.coords] : [])]);
    return;
  }
  showLines(matches.map(m => m.route.id));
  fit([state.from.coords, ...(state.to ? [state.to.coords] : []), ...matches.flatMap(m => m.g.coords)]);
}

/* ---------- адреса ---------- */
function setPlace(which, place) {
  state[which] = place;
  state.routeId = null;
  if (state.tab === "search") { renderSearch(); updateSearchMap(); }
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

function switchTab(tab) {
  stopSim();
  state.tab = tab;
  state.pick = null;
  document.querySelectorAll(".tabs button").forEach(b => b.classList.toggle("active", b.dataset.tab === tab));
  if (map) {
    clearMap();
    if (tab !== "search") ["from", "to"].forEach(w => { if (layers[w]) { map.geoObjects.remove(layers[w]); layers[w] = null; } });
  }
  if (tab === "search") renderSearch();
  if (tab === "routes") renderRoutes();
  if (tab === "mine") renderMine();
  refreshMapForTab();
}
document.querySelectorAll(".tabs button").forEach(b => b.addEventListener("click", () => switchTab(b.dataset.tab)));

const ICON_GEO = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><circle cx="12" cy="12" r="4"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/></svg>';
const ICON_PIN = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M12 21s7-6.2 7-11.5A7 7 0 0 0 5 9.5C5 14.8 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/></svg>';
const ICON_SWAP = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M7 4v16M7 4l-3 3M7 4l3 3M17 20V4M17 20l-3-3M17 20l3-3"/></svg>';

function renderSearch() {
  view.innerHTML = `
    <div class="where">
      <div class="loc"><span class="dot from"></span><input id="in-from" autocomplete="off" placeholder="Откуда поедете?" value="${state.from ? esc(state.from.name) : ""}">${state.from ? '<button class="clear" data-clear="from" aria-label="Очистить">×</button>' : ""}</div>
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
    <div id="results"></div>
    ${HAS_KEY ? "" : '<div class="note">Ключ Яндекс Карт не задан: пробки видны, но маршруты построены упрощённо, а адреса ищутся только по списку мест.</div>'}`;

  bindInput("from");
  bindInput("to");
  view.querySelectorAll("[data-clear]").forEach(b => b.onclick = () => setPlace(b.dataset.clear, null));
  $("#swap").onclick = () => { [state.from, state.to] = [state.to, state.from]; state.routeId = null; renderSearch(); updateSearchMap(); };
  $("#geo").onclick = locateMe;
  view.querySelectorAll("[data-pick]").forEach(b => b.onclick = () => {
    state.pick = state.pick === b.dataset.pick ? null : b.dataset.pick;
    if (state.pick) toast(state.pick === "from" ? "Нажмите на карту, откуда поедете" : "Нажмите на карту, куда поедете");
    renderSearch();
  });
  view.querySelectorAll("[data-day]").forEach(b => b.onclick = () => { state.day = +b.dataset.day; renderSearch(); });
  renderResults();
}

function renderResults() {
  const box = $("#results");
  if (!box) return;
  if (!state.from) {
    box.innerHTML = `<div class="hint">${ICON_PIN}<div><strong>Откуда поедете?</strong><br><span class="small muted">Укажите адрес, точку на карте или нажмите «Я здесь» — покажем маршруты рядом. «Куда» можно добавить, чтобы остался один подходящий маршрут.</span></div></div>`;
    return;
  }
  if (!Object.keys(geoms).length) { box.innerHTML = '<div class="empty">Загружаем маршруты…</div>'; ready.then(() => { if (state.tab === "search") { renderResults(); updateSearchMap(); } }); return; }
  const matches = matchRoutes();
  const active = activeMatch(matches);
  if (active) { renderDrivers(box, active, matches.length); return; }
  if (!matches.length) {
    box.innerHTML = `<div class="empty">Рядом с этой точкой нет маршрутов${state.to ? " в нужную сторону" : ""}. Попробуйте другую точку или посмотрите вкладку «Маршруты».</div>`;
    return;
  }
  box.innerHTML = `<h3>Маршруты рядом: ${matches.length}</h3><div id="rlist"></div>`;
  const list = $("#rlist");
  matches.forEach(m => {
    const n = driversFor(m).filter(x => x.trip.free).length;
    const card = document.createElement("button");
    card.className = "route-card clickable";
    card.style.setProperty("--c", m.route.color);
    card.innerHTML = `
      <div class="route-head">
        <span class="swatch"></span>
        <div style="flex:1">
          <div class="route-title">${esc(m.route.from.name)} → ${esc(m.route.to.name)}</div>
          <div class="small muted">${m.pick.d < 120 ? "начинается рядом" : `до маршрута ${meters(m.pick.d)} пешком`} · в пути ~${minutes(m.g.durSec)}</div>
        </div>
        <span class="chev">›</span>
      </div>
      <div class="small" style="margin-top:8px">${n ? `<b>${n}</b> ${plural(n, "водитель", "водителя", "водителей")} · ${dayLabel(state.day).toLowerCase()}` : '<span class="muted">свободных мест нет</span>'}</div>`;
    card.onclick = () => { state.routeId = m.route.id; renderResults(); updateSearchMap(); };
    list.appendChild(card);
  });
}

function renderDrivers(box, m, total) {
  const drivers = driversFor(m);
  box.innerHTML = `
    ${!state.to && total > 1 ? '<button class="link back" id="allroutes">← Все маршруты рядом</button>' : ""}
    <div class="route-card" style="--c:${m.route.color}">
      <div class="route-head">
        <span class="swatch"></span>
        <div style="flex:1">
          <div class="route-title">${esc(m.route.from.name)} → ${esc(m.route.to.name)}</div>
          <div class="small muted">${m.pick.d < 120 ? "маршрут начинается рядом" : `до маршрута ${meters(m.pick.d)} пешком`}${m.drop && m.drop.d >= 120 ? ` · от маршрута до места ${meters(m.drop.d)}` : ""}</div>
        </div>
      </div>
      <div class="facts"><span>в пути <b>~${minutes(m.g.durSec)}</b></span><span>${meters(m.g.total)}</span>${m.g.trafficSec ? `<span class="traffic">сейчас с пробками ${minutes(m.g.trafficSec)}</span>` : ""}</div>
    </div>
    <h3>Водители · ${dayLabel(state.day).toLowerCase()}</h3>
    <div id="dlist">${drivers.length ? "" : '<div class="empty">На этот день рейсов больше нет. Выберите другой день.</div>'}</div>`;
  const back = $("#allroutes");
  if (back) back.onclick = () => { state.routeId = null; renderResults(); updateSearchMap(); };
  const list = $("#dlist");
  drivers.forEach(({ trip, at }) => {
    const d = trip.driver;
    const row = document.createElement("button");
    row.className = "driver-row" + (trip.free ? "" : " full");
    row.disabled = !trip.free;
    row.style.setProperty("--c", m.route.color);
    row.innerHTML = `
      <div class="avatar">${esc(d.name[0])}</div>
      <div class="info">
        <div><strong>${esc(d.name)}</strong> <span class="small">★ ${d.rating}</span>${d.verified ? ' <span class="verified">✓</span>' : ""}</div>
        <div class="small muted">${esc(d.car)}, ${esc(d.color)}</div>
        <div class="small ${trip.free ? "seats-ok" : "seats-no"}">${trip.free ? `свободно ${trip.free} ${plural(trip.free, "место", "места", "мест")}` : "мест нет"}</div>
      </div>
      <div class="when">
        <div class="tm">${hhmm(at)}</div>
        ${trip.free ? `<div class="small">от ${amd(trip.minPrice)}</div>` : ""}
      </div>`;
    row.onclick = () => renderCar(m, trip);
    list.appendChild(row);
  });
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

// Схема салона: водитель и переднее место, сзади 2 или 3 места
function seatPlan(trip, selected) {
  const s = id => trip.seats.find(x => x.id === id);
  const btn = seat => {
    if (!seat) return "";
    const on = selected.includes(seat.id);
    return `<button class="seat ${seat.taken ? "taken" : ""} ${on ? "on" : ""}" data-seat="${seat.id}" ${seat.taken ? "disabled" : ""} aria-pressed="${on}">
      <span class="seat-name">${esc(seat.label)}</span>
      <span class="seat-price">${seat.taken ? "занято" : amd(seat.price)}</span>
    </button>`;
  };
  const rear = ["rl", "rm", "rr"].map(s).filter(Boolean);
  return `<div class="car-plan">
    <div class="car-nose"></div>
    <div class="car-row">
      <div class="seat driver-seat"><span class="wheel">⎈</span><span class="seat-name">Водитель</span></div>
      ${btn(s("front"))}
    </div>
    <div class="car-row r${rear.length}">${rear.map(btn).join("")}</div>
  </div>`;
}

function renderCar(m, trip, selected = []) {
  const g = m.g;
  const dropAlong = m.drop ? m.drop.along : g.total;
  const pickAt = timeAt(trip, m.pick.along), dropAt = timeAt(trip, dropAlong);
  const total = selected.reduce((sum, id) => sum + trip.seats.find(x => x.id === id).price, 0);
  view.innerHTML = `
    <button class="link back" id="back">← К водителям</button>
    ${driverCard(trip)}
    <div class="timeline">
      <span class="dot from"></span><span>Посадка рядом с вами${m.pick.d >= 120 ? ` · ${meters(m.pick.d)} пешком` : ""}</span><span class="tm">≈ ${hhmm(pickAt)}</span>
      <span class="dot to"></span><span>${m.drop ? `Высадка рядом с «${esc(state.to.name)}»` : esc(m.route.to.name)}</span><span class="tm">≈ ${hhmm(dropAt)}</span>
    </div>
    <h3>Выберите места</h3>
    ${seatPlan(trip, selected)}
    <div class="note">Где именно вас подобрать и высадить, договоритесь с водителем: его телефон появится в брони в день поездки.</div>
    <div class="paybar">
      <div><div class="tiny muted">${selected.length ? selected.map(id => trip.seats.find(x => x.id === id).label).join(", ") : "Места не выбраны"}</div><div class="total">${amd(total)}</div></div>
      <button class="btn" id="pay" ${selected.length ? "" : "disabled"}>Оплатить картой</button>
    </div>
    <p class="muted tiny" style="text-align:center">Бесплатная отмена — не позднее чем за 60 минут до посадки</p>`;
  $("#back").onclick = () => { renderSearch(); updateSearchMap(); };
  view.querySelectorAll(".seat[data-seat]").forEach(b => b.onclick = () => {
    const id = b.dataset.seat;
    const next = selected.includes(id) ? selected.filter(x => x !== id) : [...selected, id];
    renderCar(m, trip, next);
  });
  if (selected.length) $("#pay").onclick = () => payDemo(m, trip, selected, total);
}

function payDemo(m, trip, seatIds, total) {
  modal(`
    <h2>Оплата картой</h2>
    <p>К оплате: <strong>${amd(total)}</strong></p>
    <p class="muted small">Это демо: деньги не списываются. В рабочей версии здесь откроется защищённая страница банка для карт ArCa, Visa и Mastercard.</p>
    <button class="btn" id="confirm">Подтвердить демо-оплату</button>
    <button class="btn secondary" id="cancel">Отмена</button>`);
  $("#cancel").onclick = closeModal;
  $("#confirm").onclick = () => {
    const b = {
      id: "B" + Date.now().toString(36).toUpperCase(),
      tripId: trip.id, routeId: m.route.id,
      pickAlong: m.pick.along, dropAlong: m.drop ? m.drop.along : m.g.total,
      fromName: state.from.name, toName: state.to ? state.to.name : m.route.to.name,
      seatIds, seatLabels: seatIds.map(id => trip.seats.find(x => x.id === id).label),
      amount: total, status: "paid", rating: null
    };
    Bookings.add(b);
    closeModal();
    toast("Оплата прошла (демо). Места забронированы.");
    state.tab = "mine";
    document.querySelectorAll(".tabs button").forEach(x => x.classList.toggle("active", x.dataset.tab === "mine"));
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
  clearMap();
  showLines([b.routeId]);
  setSegment(seg, trip.route.color);
  setPickup(pointAt(g, b.pickAlong));
  fit(g.coords);
  const minsLeft = (pickAt - Date.now()) / 60000;
  const dayOff = Math.round((new Date(trip.dep).setHours(0, 0, 0, 0) - dayStart(0).getTime()) / 864e5);
  view.innerHTML = `
    <button class="link back" id="back">← Мои поездки</button>
    <div class="row"><h2>Бронь ${esc(b.id)}</h2>${statusBadge(b)}</div>
    <div class="timeline">
      <span class="dot from"></span><span>${esc(b.fromName)}</span><span class="tm">≈ ${hhmm(pickAt)}</span>
      <span class="dot to"></span><span>${esc(b.toName)}</span><span class="tm">≈ ${hhmm(dropAt)}</span>
    </div>
    <p class="small muted">${dayLabel(dayOff)} · ${esc(b.seatLabels.join(", "))} · <b style="color:var(--text)">${amd(b.amount)}</b></p>
    ${driverCard(trip)}
    ${b.status === "paid" ? `
      <div class="note">Телефон водителя появится в день поездки (в прототипе не показывается).</div>
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
    <p>${free ? `Вернём ${amd(b.amount)} на карту.` : "До посадки меньше 60 минут. Деньги не вернутся."}</p>
    <button class="btn danger" id="yes">Отменить бронь</button>
    <button class="btn secondary" id="no">Не отменять</button>`);
  $("#no").onclick = closeModal;
  $("#yes").onclick = () => {
    b.status = "cancelled";
    b.refund = free ? b.amount : 0;
    Bookings.update(b);
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
    btn.onclick = () => { b.rating = +btn.dataset.n; Bookings.update(b); toast("Спасибо за оценку!"); renderTicket(b); };
  });
}

function renderRoutes() {
  view.innerHTML = `<h2>Все маршруты</h2><p class="muted small">Маршрут — это начальная и конечная точки. Где подсесть по пути, пассажир договаривается с водителем.</p><div id="list"></div>`;
  const box = $("#list");
  D.routes.forEach(route => {
    const g = geoms[route.id];
    const card = document.createElement("div");
    card.className = "route-card";
    card.style.setProperty("--c", route.color);
    card.innerHTML = `
      <div class="route-head">
        <span class="swatch"></span>
        <div class="ends"><span class="dot from"></span><span>${esc(route.from.name)}</span><span class="dot to"></span><span>${esc(route.to.name)}</span></div>
      </div>
      <div class="facts">${g ? `<span>в пути <b>~${minutes(g.durSec)}</b></span><span>${meters(g.total)}</span>${g.trafficSec ? `<span class="traffic">сейчас с пробками ${minutes(g.trafficSec)}</span>` : ""}` : "<span>загрузка…</span>"}</div>
      <div class="quick">
        <button class="pill" data-a="go">Ехать по этому маршруту</button>
        <button class="pill" data-a="sim">Показать движение машины</button>
      </div>`;
    card.addEventListener("click", e => {
      const a = e.target.closest("[data-a]");
      if (!a) { if (g) { showLines([route.id]); fit(g.coords); } return; }
      if (a.dataset.a === "go") {
        state.from = { ...route.from };
        state.to = { ...route.to };
        state.routeId = null;
        switchTab("search");
      }
      if (a.dataset.a === "sim") ready.then(() => startSim({ ...tripsFor(route, 0)[0], dep: new Date() }, null));
    });
    box.appendChild(card);
  });
}

function renderMine() {
  const list = Bookings.all();
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
      <div class="tiny muted">${esc(trip.driver.name)}, ${esc(trip.driver.car)} · ${esc(b.seatLabels.join(", "))} · ${amd(b.amount)}</div>`
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
  clearMap();
  showLines([route.id]);
  map.geoObjects.add(car);
  state.sim = { trip, booking, pos: 0, speed, factor: 10, car, last: performance.now(), raf: 0, boarded: false, g, route };
  if (booking) { setSegment(subLine(g, booking.pickAlong, booking.dropAlong), route.color); setPickup(pointAt(g, booking.pickAlong)); }
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
    Bookings.update(b);
    toast("Поездка завершена. Оцените водителя.");
    const after = $("#after");
    if (after) after.innerHTML = rateBlock();
    bindRate(b);
  }
}

/* ---------- старт ---------- */
renderSearch();
