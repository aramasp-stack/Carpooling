/* TransportApp — общий код прототипа для приложений пассажира и водителя:
   данные, расписание рейсов, места в салоне, брони, геометрия маршрутов, загрузка Яндекс Карт.
   Оба приложения открываются с одного адреса и видят одни и те же брони (они хранятся в браузере). */

const CFG = window.CONFIG || {};
const D = window.DEMO;
const HAS_KEY = Boolean(CFG.yandexApiKey);
const YEREVAN = { center: [40.1830, 44.5100], bounds: [[40.05, 44.35], [40.27, 44.66]] };
// На телефоне кнопки карты ниже, чтобы не попадать под вырез экрана
const CTRL_TOP = window.innerWidth < 500 ? 52 : 16;

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

/* ---------- расписание и места (демо) ---------- */
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

// Места в салоне. Цены мест задаёт водитель; в демо — от базовой цены маршрута.
function seatsFor(route, total, id) {
  const base = route.price;
  const seats = [
    { id: "front", label: "Переднее", price: base + D.seatPrice.front },
    { id: "rl", label: "Сзади слева", price: base + D.seatPrice.window },
    { id: "rm", label: "Сзади посередине", price: base + D.seatPrice.middle },
    { id: "rr", label: "Сзади справа", price: base + D.seatPrice.window }
  ];
  return total === 3 ? seats.filter(s => s.id !== "rm") : seats;
}

/* ---------- общие данные обоих приложений (в браузере) ---------- */
const KEYS = {
  bookings: "ta3-bookings",       // брони пассажира
  custom: "ta3-custom-trips",     // рейсы, созданные в приложении водителя
  boarding: "ta3-boarding",       // отметки водителя «сел / не пришёл»
  tripState: "ta3-trip-state"     // начат / завершён рейс
};
const Bookings = {
  all: () => store.get(KEYS.bookings, []),
  save: list => store.set(KEYS.bookings, list),
  add(b) { const list = Bookings.all(); list.unshift(b); Bookings.save(list); },
  update(b) { const list = Bookings.all(); const i = list.findIndex(x => x.id === b.id); if (i >= 0) { list[i] = b; Bookings.save(list); } }
};
const customTrips = () => store.get(KEYS.custom, []);

// Демо-пассажиры, которые уже заняли места до вас
const DEMO_PASSENGERS = ["Ани", "Сурен", "Мари", "Карен", "Лилит", "Артур", "Нарине", "Гор"];

function finishTrip(id, route, dep, driver, seats, demoTaken) {
  const bookings = Bookings.all().filter(b => b.tripId === id && b.status !== "cancelled");
  seats.forEach(s => {
    const b = bookings.find(x => x.seatIds.includes(s.id));
    s.taken = Boolean(b) || demoTaken.has(s.id);
    s.bookingId = b ? b.id : null;
    s.passenger = b ? "Пассажир из приложения" : (s.taken ? DEMO_PASSENGERS[hash(id + s.id) % DEMO_PASSENGERS.length] : null);
  });
  const free = seats.filter(s => !s.taken);
  return { id, route, dep, driver, seats, free: free.length, minPrice: free.length ? Math.min(...free.map(s => s.price)) : null };
}

function tripsFor(route, dayOffset) {
  const day = dayStart(dayOffset);
  const base = D.departures.map(t => {
    const [h, m] = t.split(":").map(Number);
    const dep = new Date(day);
    dep.setHours(h, m, 0, 0);
    const id = `${route.id}-${ymd(dep)}-${t}`;
    const seed = hash(id);
    const driver = D.drivers[seed % D.drivers.length];
    const total = 3 + (seed >>> 4) % 2;
    const seats = seatsFor(route, total, id);
    const takenDemo = (seed >>> 7) % total;
    const order = seats.map(s => s.id).sort((a, b) => hash(id + a) - hash(id + b));
    return finishTrip(id, route, dep, driver, seats, new Set(order.slice(0, takenDemo)));
  });
  const extra = customTrips().filter(c => c.routeId === route.id && c.date === ymd(day)).map(c => {
    const [h, m] = c.time.split(":").map(Number);
    const dep = new Date(day);
    dep.setHours(h, m, 0, 0);
    return { ...finishTrip(c.id, route, dep, D.drivers[c.driver || 0], c.seats.map(s => ({ ...s })), new Set()), custom: true };
  });
  return [...base, ...extra].sort((a, b) => a.dep - b.dep);
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


function loadYmaps() {
  return new Promise((resolve, reject) => {
    const s = document.createElement("script");
    s.src = "https://api-maps.yandex.ru/2.1/?lang=ru_RU" + (HAS_KEY ? "&apikey=" + encodeURIComponent(CFG.yandexApiKey) : "");
    s.onload = () => ymaps.ready(resolve);
    s.onerror = () => reject(new Error("Яндекс Карты не загрузились"));
    document.head.appendChild(s);
  });
}

function plural(n, one, few, many) {
  const n10 = n % 10, n100 = n % 100;
  if (n10 === 1 && n100 !== 11) return one;
  if (n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14)) return few;
  return many;
}
