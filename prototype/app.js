/* TransportApp — интерактивный прототип (этап 1 ТЗ).
   Карта Еревана, готовые маршруты, поиск «откуда — куда», бронь с демо-оплатой,
   симуляция движения машины. Настоящей оплаты и сервера нет: брони хранятся в браузере. */

const D = window.DEMO;
const $ = (sel, root = document) => root.querySelector(sel);
const esc = s => String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const amd = n => Math.round(n).toLocaleString("ru-RU") + " ֏";
const hhmm = d => d.toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" });

/* ---------- хранилище ---------- */
const store = {
  get(key, def) { try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : def; } catch { return def; } },
  set(key, val) { try { localStorage.setItem(key, JSON.stringify(val)); } catch { /* приватный режим */ } }
};

const state = {
  tab: "search",
  from: null,
  to: null,
  day: 0,
  bookings: store.get("ta-bookings", []),
  sim: null
};
const saveBookings = () => store.set("ta-bookings", state.bookings);

/* ---------- геометрия ---------- */
const R = 6371000;
const rad = x => x * Math.PI / 180;
function dist(a, b) {
  const dLat = rad(b[1] - a[1]), dLon = rad(b[0] - a[0]);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a[1])) * Math.cos(rad(b[1])) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}
function bearing(a, b) {
  const y = Math.sin(rad(b[0] - a[0])) * Math.cos(rad(b[1]));
  const x = Math.cos(rad(a[1])) * Math.sin(rad(b[1])) - Math.sin(rad(a[1])) * Math.cos(rad(b[1])) * Math.cos(rad(b[0] - a[0]));
  return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360;
}

const geoms = {}; // routeId -> { coords, cum, total, stopDist, straight }

function buildGeom(route, coords, straight) {
  const cum = [0];
  for (let i = 1; i < coords.length; i++) cum.push(cum[i - 1] + dist(coords[i - 1], coords[i]));
  const stopDist = [];
  let from = 0;
  route.stops.forEach((s, si) => {
    let best = from, bestD = Infinity;
    const last = si === route.stops.length - 1 ? coords.length - 1 : coords.length - 1;
    for (let i = from; i <= last; i++) {
      const d = dist([s.lon, s.lat], coords[i]);
      if (d < bestD) { bestD = d; best = i; }
    }
    stopDist.push(cum[best]);
    from = best;
  });
  return { coords, cum, total: cum[cum.length - 1], stopDist, straight };
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

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function loadGeometry(route) {
  const key = "ta-geom-v1-" + route.id + "-" + route.stops.map(s => s.lat + "," + s.lon).join(";");
  const cached = store.get(key, null);
  if (cached) return buildGeom(route, cached, false);
  try {
    const url = "https://router.project-osrm.org/route/v1/driving/" +
      route.stops.map(s => s.lon + "," + s.lat).join(";") + "?overview=full&geometries=geojson";
    const res = await fetch(url);
    if (!res.ok) throw new Error(res.status);
    const json = await res.json();
    const coords = json.routes[0].geometry.coordinates;
    store.set(key, coords);
    return buildGeom(route, coords, false);
  } catch (e) {
    // Нет связи с сервисом построения маршрутов — рисуем прямыми отрезками
    return buildGeom(route, route.stops.map(s => [s.lon, s.lat]), true);
  }
}

/* ---------- расписание (демо) ---------- */
function hash(str) { let h = 5381; for (const c of str) h = ((h << 5) + h + c.charCodeAt(0)) >>> 0; return h; }
function dayStart(offset) { const d = new Date(); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() + offset); return d; }
function dayLabel(offset) {
  if (offset === 0) return "Сегодня";
  if (offset === 1) return "Завтра";
  return dayStart(offset).toLocaleDateString("ru-RU", { weekday: "short", day: "numeric", month: "short" });
}

function stopMinutes(route, idx) {
  const g = geoms[route.id];
  const share = g ? g.stopDist[idx] / (g.total || 1) : idx / (route.stops.length - 1);
  return route.minutes * share;
}

function tripsFor(route, dayOffset) {
  return D.departures.map(t => {
    const [h, m] = t.split(":").map(Number);
    const dep = dayStart(dayOffset);
    dep.setHours(h, m, 0, 0);
    const id = `${route.id}-${dep.toISOString().slice(0, 10)}-${t}`;
    const seed = hash(id);
    const driver = D.drivers[seed % D.drivers.length];
    const total = 3 + (seed >>> 4) % 2;
    const takenDemo = (seed >>> 7) % total;
    const mine = state.bookings.filter(b => b.tripId === id && b.status === "paid").reduce((s, b) => s + b.seats, 0);
    return { id, route, dep, driver, total, taken: Math.min(total, takenDemo + mine) };
  });
}
const tripById = id => {
  for (const r of D.routes) for (let d = -14; d < 3; d++) {
    const t = tripsFor(r, d).find(x => x.id === id);
    if (t) return t;
  }
  return null;
};
const atStop = (trip, idx) => new Date(trip.dep.getTime() + stopMinutes(trip.route, idx) * 60000);

function search() {
  const res = [];
  const now = Date.now();
  D.routes.forEach(route => {
    const fi = route.stops.findIndex(s => s.name === state.from);
    const ti = route.stops.findIndex(s => s.name === state.to);
    if (fi < 0 || ti < 0 || fi >= ti) return;
    tripsFor(route, state.day).forEach(trip => {
      const leave = atStop(trip, fi);
      if (leave.getTime() < now + 5 * 60000) return;
      res.push({ trip, fi, ti, leave, arrive: atStop(trip, ti) });
    });
  });
  return res.sort((a, b) => a.leave - b.leave);
}

/* ---------- карта ---------- */
const map = new maplibregl.Map({
  container: "map",
  style: {
    version: 8,
    sources: {
      osm: {
        type: "raster",
        tiles: ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
        tileSize: 256,
        maxzoom: 19,
        attribution: "© OpenStreetMap contributors"
      }
    },
    layers: [{ id: "osm", type: "raster", source: "osm" }]
  },
  center: [44.505, 40.183],
  zoom: 12
});
map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "top-right");

const isDesktop = () => window.matchMedia("(min-width: 768px)").matches;
function padding() {
  return isDesktop()
    ? { top: 50, bottom: 50, left: 430, right: 60 }
    : { top: 60, left: 30, right: 30, bottom: Math.round(window.innerHeight * 0.6) };
}
function fit(coords) {
  if (!coords.length) return;
  const b = new maplibregl.LngLatBounds(coords[0], coords[0]);
  coords.forEach(c => b.extend(c));
  map.fitBounds(b, { padding: padding(), maxZoom: 15, duration: 600 });
}
function fitAll() { fit(Object.values(geoms).flatMap(g => g.coords)); }

function setRouteFocus(routeId) {
  D.routes.forEach(r => {
    if (!map.getLayer("route-" + r.id)) return;
    map.setPaintProperty("route-" + r.id, "line-opacity", !routeId || routeId === r.id ? 0.9 : 0.2);
  });
}
function setSegment(coords) {
  map.getSource("segment").setData({
    type: "FeatureCollection",
    features: coords ? [{ type: "Feature", geometry: { type: "LineString", coordinates: coords } }] : []
  });
}

let popup = null;
const ready = new Promise(resolve => {
  map.on("load", async () => {
    for (const route of D.routes) {
      geoms[route.id] = await loadGeometry(route);
      await sleep(150);
    }
    D.routes.forEach(route => {
      map.addSource("route-" + route.id, {
        type: "geojson",
        data: { type: "Feature", geometry: { type: "LineString", coordinates: geoms[route.id].coords } }
      });
      map.addLayer({
        id: "route-" + route.id, type: "line", source: "route-" + route.id,
        layout: { "line-cap": "round", "line-join": "round" },
        paint: { "line-color": route.color, "line-width": 5, "line-opacity": 0.9 }
      });
    });
    map.addSource("segment", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
    map.addLayer({
      id: "segment", type: "line", source: "segment",
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": "#111827", "line-width": 8, "line-opacity": 0.55 }
    });

    const stops = {};
    D.routes.forEach(r => r.stops.forEach(s => { stops[s.name] = s; }));
    map.addSource("stops", {
      type: "geojson",
      data: {
        type: "FeatureCollection",
        features: Object.values(stops).map(s => ({
          type: "Feature", properties: { name: s.name }, geometry: { type: "Point", coordinates: [s.lon, s.lat] }
        }))
      }
    });
    map.addLayer({
      id: "stops", type: "circle", source: "stops",
      paint: { "circle-radius": 7, "circle-color": "#ffffff", "circle-stroke-color": "#111827", "circle-stroke-width": 2.5 }
    });
    map.on("mouseenter", "stops", () => { map.getCanvas().style.cursor = "pointer"; });
    map.on("mouseleave", "stops", () => { map.getCanvas().style.cursor = ""; });
    map.on("click", "stops", e => {
      const name = e.features[0].properties.name;
      const el = document.createElement("div");
      el.innerHTML = `<strong>${esc(name)}</strong><div class="popup-btns"><button data-set="from">Отсюда</button><button data-set="to">Сюда</button></div>`;
      el.addEventListener("click", ev => {
        const which = ev.target.dataset.set;
        if (!which) return;
        state[which] = name;
        popup.remove();
        switchTab("search");
      });
      if (popup) popup.remove();
      popup = new maplibregl.Popup({ offset: 10 }).setLngLat(e.lngLat).setDOMContent(el).addTo(map);
    });

    fitAll();
    resolve();
    if (Object.values(geoms).some(g => g.straight)) toast("Сервис построения маршрутов недоступен — линии показаны напрямую между остановками.");
  });
});

/* ---------- интерфейс ---------- */
const view = $("#view");
function toast(text) {
  const t = $("#toast");
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { t.hidden = true; }, 3500);
}
function modal(html) {
  $("#modal-card").innerHTML = html;
  $("#modal").hidden = false;
}
const closeModal = () => { $("#modal").hidden = true; };
$("#modal").addEventListener("click", e => { if (e.target.id === "modal") closeModal(); });

function switchTab(tab) {
  stopSim();
  state.tab = tab;
  document.querySelectorAll(".tabs button").forEach(b => b.classList.toggle("active", b.dataset.tab === tab));
  setSegment(null);
  setRouteFocus(null);
  if (tab === "search") renderSearch();
  if (tab === "routes") renderRoutes();
  if (tab === "mine") renderMine();
}
document.querySelectorAll(".tabs button").forEach(b => b.addEventListener("click", () => switchTab(b.dataset.tab)));

const allStops = () => [...new Set(D.routes.flatMap(r => r.stops.map(s => s.name)))].sort((a, b) => a.localeCompare(b, "ru"));

function renderSearch() {
  const opts = sel => `<option value="">— выберите остановку —</option>` +
    allStops().map(n => `<option ${n === sel ? "selected" : ""}>${esc(n)}</option>`).join("");
  view.innerHTML = `
    <h2>Куда едем?</h2>
    <div class="where">
      <label class="field"><span>Откуда</span><select id="from">${opts(state.from)}</select></label>
      <label class="field"><span>Куда</span><select id="to">${opts(state.to)}</select></label>
      <button class="swap" id="swap" title="Поменять местами" aria-label="Поменять местами">⇅</button>
    </div>
    <div class="chips">${[0, 1, 2].map(d => `<button class="chip ${d === state.day ? "active" : ""}" data-day="${d}">${dayLabel(d)}</button>`).join("")}</div>
    <button class="btn" id="go" ${state.from && state.to ? "" : "disabled"}>Найти поездки</button>
    <p class="muted small">Остановку можно выбрать и на карте: нажмите на белый кружок.</p>`;
  $("#from").onchange = e => { state.from = e.target.value || null; renderSearch(); };
  $("#to").onchange = e => { state.to = e.target.value || null; renderSearch(); };
  $("#swap").onclick = () => { [state.from, state.to] = [state.to, state.from]; renderSearch(); };
  view.querySelectorAll("[data-day]").forEach(b => b.onclick = () => { state.day = +b.dataset.day; renderSearch(); });
  $("#go").onclick = async () => { await ready; renderResults(); };
}

function freeText(trip) {
  const free = trip.total - trip.taken;
  return free > 0 ? `<span class="seats-free">свободно мест: ${free}</span>` : `<span class="seats-none">мест нет</span>`;
}

function renderResults() {
  const list = search();
  setSegment(null);
  setRouteFocus(null);
  view.innerHTML = `
    <button class="link back" id="back">← Изменить поиск</button>
    <h2>${esc(state.from)} → ${esc(state.to)}</h2>
    <p class="muted small">${dayLabel(state.day)} · найдено рейсов: ${list.length}</p>
    ${list.length ? "" : `<p>Нет подходящих рейсов. Эти остановки не лежат на одном маршруте в нужном направлении или рейсы на сегодня уже ушли — попробуйте другой день или откройте вкладку «Маршруты».</p>`}
    <div id="list"></div>`;
  $("#back").onclick = renderSearch;
  const box = $("#list");
  list.forEach((r, i) => {
    const t = r.trip;
    const card = document.createElement("div");
    card.className = "card";
    card.innerHTML = `
      <div class="row"><span class="time">${hhmm(r.leave)} → ${hhmm(r.arrive)}</span><span class="price">${amd(t.route.price)}</span></div>
      <div class="small" style="margin:4px 0"><span class="code" style="background:${t.route.color}">${t.route.id}</span>${esc(t.route.name)}</div>
      <div class="row small"><span>${esc(t.driver.name)} ★ ${t.driver.rating} ${t.driver.verified ? '<span class="verified">✓ документы проверены</span>' : ""}</span>${freeText(t)}</div>
      <div class="small muted">${esc(t.driver.car)}, ${esc(t.driver.color)}</div>`;
    card.onclick = () => renderTrip(r);
    box.appendChild(card);
    if (i === 0) {
      const g = geoms[t.route.id];
      fit(subLine(g, g.stopDist[r.fi], g.stopDist[r.ti]));
    }
  });
}

function money(price, seats) {
  const total = price * seats;
  const fee = total * D.commissionPercent / 100;
  const duty = total * D.statePercent / 100;
  return { total, fee, duty, driver: total - fee - duty };
}

function renderTrip(r, seats = 1) {
  const t = r.trip, g = geoms[t.route.id];
  const free = t.total - t.taken;
  seats = Math.max(1, Math.min(seats, free, 4));
  setRouteFocus(t.route.id);
  const seg = subLine(g, g.stopDist[r.fi], g.stopDist[r.ti]);
  setSegment(seg);
  fit(seg);
  const m = money(t.route.price, seats);
  view.innerHTML = `
    <button class="link back" id="back">← К списку рейсов</button>
    <h2>${hhmm(r.leave)} · ${esc(t.route.stops[r.fi].name)}</h2>
    <p class="small"><span class="code" style="background:${t.route.color}">${t.route.id}</span>${esc(t.route.name)}</p>
    <p>Выход: <strong>${esc(t.route.stops[r.ti].name)}</strong>, около ${hhmm(r.arrive)}</p>
    <div class="card" style="cursor:default">
      <div class="row"><strong>${esc(t.driver.name)}</strong><span>★ ${t.driver.rating} · ${t.driver.trips} поездок</span></div>
      <div class="small muted">${esc(t.driver.car)}, ${esc(t.driver.color)}, номер ${esc(t.driver.plate)}</div>
      ${t.driver.verified ? '<div class="verified">✓ документы проверены</div>' : '<div class="small muted">документы ещё на проверке</div>'}
    </div>
    ${free > 0 ? `
      <h3>Сколько мест?</h3>
      <div class="stepper"><button id="minus">−</button><strong>${seats}</strong><button id="plus">+</button><span class="muted small">свободно ${free}</span></div>
      <div class="breakdown">
        <div class="row"><span>${seats} × ${amd(t.route.price)}</span><strong>${amd(m.total)}</strong></div>
        <div class="row muted"><span>Водителю</span><span>${amd(m.driver)}</span></div>
        <div class="row muted"><span>Комиссия сервиса ${D.commissionPercent}%</span><span>${amd(m.fee)}</span></div>
        <div class="row muted"><span>Госпошлина ${D.statePercent}%</span><span>${amd(m.duty)}</span></div>
        <div class="muted" style="margin-top:6px">Разбивка видна только в прототипе. Комиссия 10% — пример.</div>
      </div>
      <button class="btn" id="pay">Оплатить картой ${amd(m.total)}</button>
      <p class="muted small">Бесплатная отмена — не позднее чем за 60 минут до отправления.</p>`
      : `<p class="seats-none">На этот рейс мест нет.</p>`}`;
  $("#back").onclick = renderResults;
  if (free > 0) {
    $("#minus").onclick = () => renderTrip(r, seats - 1);
    $("#plus").onclick = () => renderTrip(r, seats + 1);
    $("#pay").onclick = () => payDemo(r, seats, m.total);
  }
}

function payDemo(r, seats, total) {
  modal(`
    <h2>Оплата картой</h2>
    <p>Это демо: деньги не списываются.</p>
    <p class="muted small">В рабочей версии здесь откроется защищённая страница банка для карт ArCa, Visa и Mastercard. Приложение не хранит данные карты.</p>
    <p>К оплате: <strong>${amd(total)}</strong></p>
    <button class="btn" id="confirm">Подтвердить демо-оплату</button>
    <button class="btn secondary" id="cancel">Отмена</button>`);
  $("#cancel").onclick = closeModal;
  $("#confirm").onclick = () => {
    const t = r.trip;
    const booking = {
      id: "B" + Date.now().toString(36).toUpperCase(),
      tripId: t.id, routeId: t.route.id, fi: r.fi, ti: r.ti,
      seats, amount: total, status: "paid", createdAt: new Date().toISOString(), rating: null
    };
    state.bookings.unshift(booking);
    saveBookings();
    closeModal();
    toast("Оплата прошла (демо). Место забронировано.");
    renderTicket(booking);
  };
}

function bookingInfo(b) {
  const trip = tripById(b.tripId);
  if (!trip) return null;
  return { trip, leave: atStop(trip, b.fi), arrive: atStop(trip, b.ti) };
}

function statusBadge(b) {
  if (b.status === "paid") return '<span class="status ok">Оплачено</span>';
  if (b.status === "done") return '<span class="status done">Поездка завершена</span>';
  return `<span class="status off">${b.refund ? "Отменено, возврат " + amd(b.refund) : "Отменено без возврата"}</span>`;
}

function renderTicket(b) {
  stopSim();
  const info = bookingInfo(b);
  if (!info) { view.innerHTML = `<p>Рейс больше не в расписании.</p>`; return; }
  const { trip, leave, arrive } = info;
  const g = geoms[trip.route.id];
  if (!g) { view.innerHTML = '<p class="muted">Загрузка карты…</p>'; ready.then(() => renderTicket(b)); return; }
  const dayOff = Math.round((new Date(trip.dep).setHours(0, 0, 0, 0) - dayStart(0).getTime()) / 864e5);
  setRouteFocus(trip.route.id);
  const seg = subLine(g, g.stopDist[b.fi], g.stopDist[b.ti]);
  setSegment(seg);
  fit(seg);
  const minsLeft = (leave - Date.now()) / 60000;
  view.innerHTML = `
    <button class="link back" id="back">← Мои поездки</button>
    <div class="row"><h2>Бронь ${esc(b.id)}</h2>${statusBadge(b)}</div>
    <p><strong>${hhmm(leave)}</strong> ${esc(trip.route.stops[b.fi].name)}<br><strong>${hhmm(arrive)}</strong> ${esc(trip.route.stops[b.ti].name)}</p>
    <p class="small"><span class="code" style="background:${trip.route.color}">${trip.route.id}</span>${dayLabel(dayOff)} · мест: ${b.seats} · ${amd(b.amount)}</p>
    <div class="card" style="cursor:default">
      <div class="row"><strong>${esc(trip.driver.name)}</strong><span>★ ${trip.driver.rating}</span></div>
      <div class="small">${esc(trip.driver.car)}, ${esc(trip.driver.color)}</div>
      <div class="time">${esc(trip.driver.plate)}</div>
    </div>
    ${b.status === "paid" ? `
      <button class="btn" id="track">Следить за машиной</button>
      <button class="btn danger" id="cancelb">Отменить бронь</button>
      <p class="muted small">${minsLeft >= 60 ? "Сейчас отмена бесплатная — деньги вернутся на карту." : "До отправления меньше 60 минут — при отмене деньги не возвращаются."}</p>` : ""}
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
    <p>${free ? `Вернём ${amd(b.amount)} на карту.` : "До отправления меньше 60 минут. Деньги не вернутся — водитель получит свою долю."}</p>
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
    <p class="muted small">Водитель увидит оценку, когда тоже оценит поездку или через 14 дней.</p>`;
}
function bindRate(b) {
  const box = $("#stars");
  if (!box) return;
  box.querySelectorAll("button").forEach(btn => {
    btn.onmouseenter = () => box.querySelectorAll("button").forEach(x => x.classList.toggle("on", +x.dataset.n <= +btn.dataset.n));
    btn.onclick = () => { b.rating = +btn.dataset.n; saveBookings(); toast("Спасибо за оценку!"); renderTicket(b); };
  });
}

function renderRoutes() {
  view.innerHTML = `<h2>Маршруты</h2><p class="muted small">Цены и остановки — демо. В рабочей версии их задаёт администратор.</p><div id="list"></div>`;
  const box = $("#list");
  D.routes.forEach(r => {
    const card = document.createElement("div");
    card.className = "card";
    card.innerHTML = `
      <div class="row"><span><span class="code" style="background:${r.color}">${r.id}</span><strong>${esc(r.name)}</strong></span></div>
      <div class="row small muted" style="margin-top:4px"><span>~${r.minutes} мин · ${(geoms[r.id] ? geoms[r.id].total / 1000 : 0).toFixed(1)} км</span><span class="price" style="color:var(--text)">${amd(r.price)}</span></div>
      <ul class="stop-list">${r.stops.map(s => `<li>${esc(s.name)}</li>`).join("")}</ul>
      <button class="btn secondary" style="margin-top:10px" data-sim="${r.id}">Показать движение машины</button>`;
    card.onclick = e => {
      if (e.target.dataset.sim) return;
      setRouteFocus(r.id);
      if (geoms[r.id]) fit(geoms[r.id].coords);
    };
    card.querySelector("[data-sim]").onclick = async () => {
      await ready;
      const trip = tripsFor(r, 0)[0];
      startSim({ ...trip, dep: new Date() }, null);
    };
    box.appendChild(card);
  });
  ready.then(() => { if (state.tab === "routes") fitAll(); });
}

function renderMine() {
  const list = state.bookings;
  view.innerHTML = `<h2>Мои поездки</h2>
    ${list.length ? "" : '<p class="muted">Пока нет броней. Найдите поездку на вкладке «Поиск».</p>'}
    <div id="list"></div>`;
  const box = $("#list");
  list.forEach(b => {
    const info = bookingInfo(b);
    const route = D.routes.find(r => r.id === b.routeId);
    const card = document.createElement("div");
    card.className = "card";
    card.innerHTML = info ? `
      <div class="row"><span class="time">${hhmm(info.leave)}</span>${statusBadge(b)}</div>
      <div class="small">${esc(route.stops[b.fi].name)} → ${esc(route.stops[b.ti].name)}</div>
      <div class="small muted">${info.leave.toLocaleDateString("ru-RU", { day: "numeric", month: "long" })} · мест: ${b.seats} · ${amd(b.amount)}</div>`
      : `<div class="small muted">Бронь ${esc(b.id)}: рейс вне расписания</div>`;
    card.onclick = () => renderTicket(b);
    box.appendChild(card);
  });
}

/* ---------- симуляция движения ---------- */
function stopSim() {
  if (!state.sim) return;
  cancelAnimationFrame(state.sim.raf);
  state.sim.marker.remove();
  state.sim = null;
}

function startSim(trip, booking) {
  stopSim();
  const route = trip.route, g = geoms[route.id];
  const speed = g.total / (route.minutes * 60); // м/с по расписанию
  const el = document.createElement("div");
  el.className = "car";
  el.style.background = route.color;
  const marker = new maplibregl.Marker({ element: el, rotationAlignment: "map" }).setLngLat(g.coords[0]).addTo(map);
  state.sim = { trip, booking, pos: 0, speed, factor: 10, marker, last: performance.now(), raf: 0, boarded: false };
  setRouteFocus(route.id);
  setSegment(booking ? subLine(g, g.stopDist[booking.fi], g.stopDist[booking.ti]) : null);
  fit(g.coords);

  view.innerHTML = `
    <button class="link back" id="back">← Назад</button>
    <h2><span class="code" style="background:${route.color}">${route.id}</span>${esc(route.name)}</h2>
    <p class="muted small">Симуляция: машина едет по линии маршрута без реального GPS.</p>
    <div class="eta" id="eta">…</div>
    <div class="muted" id="eta2"></div>
    <h3>Скорость симуляции</h3>
    <div class="chips">${[1, 10, 30].map(f => `<button class="chip ${f === 10 ? "active" : ""}" data-f="${f}">×${f}</button>`).join("")}</div>
    <ul class="stop-list" id="stops">${route.stops.map(s => `<li>${esc(s.name)}</li>`).join("")}</ul>`;
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
    const p = pointAt(g, s.pos);
    const ahead = pointAt(g, Math.min(g.total, s.pos + 15));
    s.marker.setLngLat(p);
    if (dist(p, ahead) > 1) s.marker.setRotation(bearing(p, ahead));

    if (now - lastText > 200) {
      lastText = now;
      updateEta(s, g, route);
    }
    if (s.pos >= g.total) { finishSim(s); return; }
    s.raf = requestAnimationFrame(tick);
  };
  state.sim.raf = requestAnimationFrame(tick);
}

function mins(m) { const v = Math.max(0, Math.round(m)); return v < 1 ? "меньше минуты" : `${v} мин`; }

function updateEta(s, g, route) {
  const eta = $("#eta"), eta2 = $("#eta2");
  if (!eta) return;
  const toMin = d => (d - s.pos) / s.speed / 60;
  // ближайшая следующая остановка
  const next = g.stopDist.findIndex(d => d > s.pos + 5);
  document.querySelectorAll("#stops li").forEach((li, i) => { li.style.fontWeight = i === next ? "700" : ""; li.style.opacity = g.stopDist[i] < s.pos - 5 ? .45 : 1; });
  if (s.booking) {
    const b = s.booking;
    const dFrom = g.stopDist[b.fi], dTo = g.stopDist[b.ti];
    if (s.pos < dFrom - 5) {
      eta.textContent = `Машина у остановки «${route.stops[b.fi].name}» через ${mins(toMin(dFrom))}`;
      eta2.textContent = `${s.trip.driver.car}, ${s.trip.driver.color}, ${s.trip.driver.plate}`;
    } else if (s.pos < dTo - 5) {
      if (!s.boarded) { s.boarded = true; toast("Водитель отметил: вы сели (демо)."); }
      eta.textContent = `В пути: до «${route.stops[b.ti].name}» ${mins(toMin(dTo))}`;
      eta2.textContent = "";
    } else {
      eta.textContent = "Вы приехали";
      eta2.textContent = "";
    }
  } else {
    eta.textContent = next >= 0 ? `Следующая: «${route.stops[next].name}» через ${mins(toMin(g.stopDist[next]))}` : "Конечная";
    eta2.textContent = `${(s.pos / 1000).toFixed(1)} из ${(g.total / 1000).toFixed(1)} км`;
  }
}

function finishSim(s) {
  const b = s.booking;
  if (b && b.status === "paid") {
    b.status = "done";
    saveBookings();
    toast("Поездка завершена. Оцените водителя.");
    const eta = $("#eta");
    if (eta) eta.insertAdjacentHTML("afterend", rateBlock());
    bindRate(b);
  } else {
    const eta = $("#eta");
    if (eta) eta.textContent = "Машина приехала на конечную";
  }
}

/* ---------- старт ---------- */
renderSearch();
