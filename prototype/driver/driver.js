/* TransportApp — приложение водителя (прототип).
   Демо-водитель — Арам. Он видит свои рейсы и пассажиров, отмечает «сел / не пришёл»,
   начинает и завершает рейс, видит заработок и выплаты, создаёт новые рейсы.
   Брони из приложения пассажира (тот же браузер) появляются здесь автоматически. */

const ME = D.drivers[0];
const SHARE = 1 - (D.commissionPercent + D.statePercent) / 100; // доля водителя
const st = { tab: "trips", day: 0, sim: null };

const boarding = { get: () => store.get(KEYS.boarding, {}), set: v => store.set(KEYS.boarding, v) };
const tripState = { get: () => store.get(KEYS.tripState, {}), set: v => store.set(KEYS.tripState, v) };

/* ---------- мои рейсы ---------- */
const myTrips = dayOffset => D.routes.flatMap(r => tripsFor(r, dayOffset)).filter(t => t.driver.name === ME.name).sort((a, b) => a.dep - b.dep);
const endOf = t => new Date(t.dep.getTime() + durOf(t.route) * 1000);
function statusOf(t) {
  const s = tripState.get()[t.id];
  if (s === "finished" || (!s && endOf(t) < new Date())) return "finished";
  if (s === "started") return "started";
  return "planned";
}
const paidOf = t => t.seats.filter(s => s.taken).reduce((sum, s) => sum + s.price, 0);
const STATUS = { planned: ["Запланирован", "ok"], started: ["В пути", "ok"], finished: ["Завершён", "done"] };

/* ---------- карта ---------- */
let map = null;
const lines = {};
let shownLine = null, marks = null, car = null;
const isDesktop = () => window.matchMedia("(min-width: 768px)").matches;
const margins = () => isDesktop() ? [40, 70, 40, 450] : [80, 30, Math.round(window.innerHeight * 0.64) + 10, 30];
function fit(coords) {
  if (!map || !coords || coords.length < 2) return;
  map.setBounds(ymaps.util.bounds.fromPoints(coords), { checkZoomRange: true, zoomMargin: margins(), duration: 400 });
}
function showRoute(routeId, points) {
  if (!map) return;
  if (shownLine) { map.geoObjects.remove(shownLine); shownLine = null; }
  if (marks) { map.geoObjects.remove(marks); marks = null; }
  if (!routeId || !lines[routeId]) return;
  shownLine = lines[routeId];
  map.geoObjects.add(shownLine);
  marks = new ymaps.GeoObjectCollection();
  const r = routeById(routeId);
  marks.add(new ymaps.Placemark(r.from.coords, { hintContent: "Старт: " + r.from.name }, { preset: "islands#greenCircleDotIcon" }));
  marks.add(new ymaps.Placemark(r.to.coords, { hintContent: "Финиш: " + r.to.name }, { preset: "islands#redCircleDotIcon" }));
  (points || []).forEach(p => marks.add(new ymaps.Placemark(p.coords, { hintContent: p.hint }, { preset: "islands#blueCircleDotIcon" })));
  map.geoObjects.add(marks);
  fit(geoms[routeId].coords);
}

const ready = (async () => {
  await loadYmaps();
  map = new ymaps.Map("map", { center: YEREVAN.center, zoom: 12, controls: [] }, { suppressMapOpenBlock: false });
  map.controls.add(new ymaps.control.TrafficControl({ state: { providerKey: "traffic#actual", trafficShown: true } }), { float: "none", position: { top: CTRL_TOP, right: 16 } });
  map.controls.add("zoomControl", { size: "small", float: "none", position: { top: CTRL_TOP + 54, right: 16 } });
  const loaded = await Promise.all(D.routes.map((r, i) => sleep(i * 120).then(() => loadRoute(r))));
  D.routes.forEach((r, i) => {
    geoms[r.id] = loaded[i];
    lines[r.id] = new ymaps.Polyline(loaded[i].coords, {}, { strokeColor: r.color, strokeWidth: 6, strokeOpacity: 0.9 });
  });
})();
ready.catch(e => { $("#map").innerHTML = '<div class="empty" style="padding-top:80px">Не удалось загрузить Яндекс Карты.</div>'; console.error(e); });

/* ---------- общий интерфейс ---------- */
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
  st.tab = tab;
  document.querySelectorAll(".tabs button").forEach(b => b.classList.toggle("active", b.dataset.tab === tab));
  showRoute(null);
  if (tab === "trips") renderTrips();
  if (tab === "money") renderMoney();
  if (tab === "profile") renderProfile();
}
document.querySelectorAll(".tabs button").forEach(b => b.addEventListener("click", () => switchTab(b.dataset.tab)));

/* ---------- вкладка «Рейсы» ---------- */
function renderTrips() {
  const trips = myTrips(st.day);
  const next = myTrips(0).find(t => statusOf(t) !== "finished");
  view.innerHTML = `
    <div class="online">
      <div><div class="big">Здравствуйте, ${esc(ME.name)}!</div><div class="small muted">${next ? `Ближайший рейс в ${hhmm(next.dep)} · ${esc(next.route.from.name)} → ${esc(next.route.to.name)}` : "На сегодня рейсов больше нет"}</div></div>
    </div>
    <button class="btn" id="new">+ Новый рейс</button>
    <div class="chips" style="margin-top:14px">${[0, 1, 2].map(d => `<button class="chip ${d === st.day ? "active" : ""}" data-day="${d}">${dayLabel(d)}</button>`).join("")}</div>
    <div id="list">${trips.length ? "" : '<div class="empty">На этот день рейсов нет. Нажмите «Новый рейс».</div>'}</div>`;
  $("#new").onclick = () => ready.then(() => renderNewTrip());
  view.querySelectorAll("[data-day]").forEach(b => b.onclick = () => { st.day = +b.dataset.day; renderTrips(); });
  const box = $("#list");
  trips.forEach(t => {
    const taken = t.seats.filter(s => s.taken).length;
    const [label, cls] = STATUS[statusOf(t)];
    const el = document.createElement("button");
    el.className = "trip-item";
    el.style.setProperty("--c", t.route.color);
    el.innerHTML = `
      <div class="row"><span class="tm">${hhmm(t.dep)}</span><span class="status ${cls}">${label}</span></div>
      <div class="small" style="margin:2px 0 8px">${esc(t.route.from.name)} → ${esc(t.route.to.name)}${t.custom ? ' <span class="tiny muted">· создан вами</span>' : ""}</div>
      <div class="row small">
        <span class="row" style="gap:8px"><span class="seat-dots">${t.seats.map(s => `<i class="${s.taken ? "b" : ""}"></i>`).join("")}</span>занято ${taken} из ${t.seats.length}</span>
        <span>вам <b>${amd(paidOf(t) * SHARE)}</b></span>
      </div>`;
    el.onclick = () => ready.then(() => renderTrip(t.id));
    box.appendChild(el);
  });
}

/* ---------- новый рейс ---------- */
function renderNewTrip(routeId = D.routes[0].id, day = 1, time = "08:00", seatCfg = null) {
  const route = routeById(routeId);
  const seats = seatCfg || seatsFor(route, 4).map(s => ({ ...s, on: true }));
  showRoute(routeId);
  view.innerHTML = `
    <button class="link back" id="back">← Мои рейсы</button>
    <h2>Новый рейс</h2>
    <h3>Маршрут</h3>
    <div class="route-pick">${D.routes.map(r => `<label><input type="radio" name="route" value="${r.id}" ${r.id === routeId ? "checked" : ""}><span class="swatch" style="--c:${r.color};margin:0"></span><span>${esc(r.from.name)} → ${esc(r.to.name)}</span></label>`).join("")}</div>
    <h3>Когда</h3>
    <div class="chips" style="margin:6px 0">${[0, 1, 2].map(d => `<button class="chip ${d === day ? "active" : ""}" data-day="${d}">${dayLabel(d)}</button>`).join("")}</div>
    <div class="field-row"><span>Выезд в</span><input type="time" id="time" value="${time}"></div>
    <h3>Места и цены</h3>
    <div class="seat-edit">${seats.map((s, i) => `
      <input type="checkbox" data-on="${i}" ${s.on ? "checked" : ""} aria-label="${esc(s.label)}">
      <span>${esc(s.label)}</span>
      <span><input type="number" min="100" step="50" data-price="${i}" value="${s.price}"> ֏</span>`).join("")}</div>
    <p class="tiny muted">Снимите галочку, если место не продаёте. Пассажир видит цену каждого места.</p>
    <button class="btn" id="publish">Опубликовать рейс</button>`;
  const read = () => {
    const cfg = seats.map((s, i) => ({ ...s, on: view.querySelector(`[data-on="${i}"]`).checked, price: Math.max(100, +view.querySelector(`[data-price="${i}"]`).value || s.price) }));
    return { routeId: view.querySelector('input[name="route"]:checked').value, time: $("#time").value || "08:00", cfg };
  };
  $("#back").onclick = () => switchTab("trips");
  view.querySelectorAll('input[name="route"]').forEach(r => r.onchange = () => { const v = read(); renderNewTrip(v.routeId, day, v.time, null); });
  view.querySelectorAll("[data-day]").forEach(b => b.onclick = () => { const v = read(); renderNewTrip(v.routeId, +b.dataset.day, v.time, v.cfg); });
  $("#publish").onclick = () => {
    const v = read();
    const chosen = v.cfg.filter(s => s.on).map(({ id, label, price }) => ({ id, label, price }));
    if (!chosen.length) { toast("Отметьте хотя бы одно место."); return; }
    const date = ymd(dayStart(day));
    const id = `${v.routeId}-${date}-${v.time}-c${Date.now().toString(36)}`;
    const list = customTrips();
    list.push({ id, routeId: v.routeId, date, time: v.time, driver: 0, seats: chosen });
    store.set(KEYS.custom, list);
    toast("Рейс опубликован — пассажиры уже видят его в поиске.");
    st.day = day;
    renderTrip(id);
  };
}

/* ---------- рейс: пассажиры, старт, финиш ---------- */
function paxList(t) {
  const g = geoms[t.route.id];
  const bookings = Bookings.all();
  return t.seats.filter(s => s.taken).map(s => {
    const b = s.bookingId ? bookings.find(x => x.id === s.bookingId) : null;
    const along = b ? b.pickAlong : (hash(t.id + s.id) % 5) / 10 * g.total; // демо: где ждёт пассажир
    return { seat: s, name: s.passenger, booking: b, along, coords: pointAt(g, along), where: b ? b.fromName : (along < 50 ? `у старта «${t.route.from.name}»` : `по пути, ${meters(along)} от старта`) };
  }).sort((a, b) => a.along - b.along);
}

function renderTrip(id) {
  stopSim();
  const t = tripById(id);
  if (!t) { switchTab("trips"); return; }
  const pax = paxList(t);
  const marksB = boarding.get()[id] || {};
  const status = statusOf(t);
  const paid = paidOf(t);
  showRoute(t.route.id, pax.map(p => ({ coords: p.coords, hint: `${p.name}, ${p.seat.label}` })));
  const [label, cls] = STATUS[status];
  view.innerHTML = `
    <button class="link back" id="back">← Мои рейсы</button>
    <div class="row"><h2>${hhmm(t.dep)} · ${dayLabel(Math.round((new Date(t.dep).setHours(0, 0, 0, 0) - dayStart(0).getTime()) / 864e5))}</h2><span class="status ${cls}">${label}</span></div>
    <div class="timeline">
      <span class="dot from"></span><span>${esc(t.route.from.name)}</span><span class="tm">${hhmm(t.dep)}</span>
      <span class="dot to"></span><span>${esc(t.route.to.name)}</span><span class="tm">≈ ${hhmm(endOf(t))}</span>
    </div>
    <h3>Пассажиры · ${pax.length} из ${t.seats.length}</h3>
    ${pax.map(p => `
      <div class="pax">
        <div class="avatar">${esc(p.name[0])}</div>
        <div class="who"><strong>${esc(p.name)}</strong> <span class="tiny muted">· ${esc(p.seat.label)}</span><div class="tiny muted">ждёт: ${esc(p.where)}</div></div>
        <div class="acts">
          <button class="mini ok ${marksB[p.seat.id] === "in" ? "on" : ""}" data-in="${p.seat.id}">Сел</button>
          <button class="mini no ${marksB[p.seat.id] === "no" ? "on" : ""}" data-no="${p.seat.id}">Нет</button>
          <button class="mini" data-call="1" aria-label="Позвонить">📞</button>
        </div>
      </div>`).join("")}
    ${t.seats.filter(s => !s.taken).map(s => `<div class="pax empty-seat"><div class="who small">${esc(s.label)} — свободно · ${amd(s.price)}</div></div>`).join("")}
    <div class="breakdown">
      <div class="row"><span>Оплатили пассажиры</span><strong>${amd(paid)}</strong></div>
      <div class="row muted"><span>Комиссия сервиса ${D.commissionPercent}%</span><span>− ${amd(paid * D.commissionPercent / 100)}</span></div>
      <div class="row muted"><span>Госпошлина ${D.statePercent}%</span><span>− ${amd(paid * D.statePercent / 100)}</span></div>
      <div class="row"><span>Вам</span><strong>${amd(paid * SHARE)}</strong></div>
    </div>
    ${status === "finished" ? '<div class="note">Рейс завершён. Деньги будут в ближайшей выплате.</div>' : `
      <button class="btn" id="go">${status === "started" ? "Продолжить рейс" : "Начать рейс"}</button>
      <a class="btn secondary" target="_blank" rel="noopener" href="https://yandex.ru/maps/?rtext=${t.route.from.coords.join(",")}~${t.route.to.coords.join(",")}&rtt=auto">Открыть в Яндекс Картах</a>`}`;
  $("#back").onclick = () => switchTab("trips");
  const mark = (seat, val) => { const all = boarding.get(); all[id] = { ...(all[id] || {}), [seat]: all[id] && all[id][seat] === val ? undefined : val }; boarding.set(all); renderTrip(id); };
  view.querySelectorAll("[data-in]").forEach(b => b.onclick = () => mark(b.dataset.in, "in"));
  view.querySelectorAll("[data-no]").forEach(b => b.onclick = () => mark(b.dataset.no, "no"));
  view.querySelectorAll("[data-call]").forEach(b => b.onclick = () => toast("В рабочей версии — звонок через подменный номер: свой телефон вы не раскрываете."));
  const go = $("#go");
  if (go) go.onclick = () => startSim(t, pax);
}

/* ---------- поездка (симуляция) ---------- */
function stopSim() {
  if (!st.sim) return;
  cancelAnimationFrame(st.sim.raf);
  if (car) { map.geoObjects.remove(car); car = null; }
  st.sim = null;
}
function startSim(t, pax) {
  stopSim();
  const all = tripState.get(); all[t.id] = "started"; tripState.set(all);
  const g = geoms[t.route.id];
  const speed = g.total / (g.trafficSec || g.durSec);
  car = new ymaps.Placemark(g.coords[0], { hintContent: "Вы" }, { preset: "islands#autoCircleIcon", iconColor: t.route.color });
  map.geoObjects.add(car);
  st.sim = { t, pax, g, pos: 0, speed, factor: 10, last: performance.now(), raf: 0, met: new Set() };
  view.innerHTML = `
    <button class="link back" id="back">← К рейсу</button>
    <h2>${esc(t.route.from.name)} → ${esc(t.route.to.name)}</h2>
    <p class="muted tiny">Симуляция: машина едет по маршруту без реального GPS.</p>
    <div class="eta" id="eta">…</div>
    <div class="small muted" id="eta2"></div>
    <div class="progress"><i id="bar"></i></div>
    <div class="chips">${[1, 10, 30].map(f => `<button class="chip ${f === 10 ? "active" : ""}" data-f="${f}">×${f}</button>`).join("")}</div>
    <button class="btn danger" id="finish">Завершить рейс</button>`;
  $("#back").onclick = () => { stopSim(); renderTrip(t.id); };
  $("#finish").onclick = () => finish(t);
  view.querySelectorAll("[data-f]").forEach(b => b.onclick = () => { st.sim.factor = +b.dataset.f; view.querySelectorAll("[data-f]").forEach(x => x.classList.toggle("active", x === b)); });
  let lastText = 0;
  const tick = now => {
    const s = st.sim;
    if (!s) return;
    const dt = Math.min(0.25, (now - s.last) / 1000);
    s.last = now;
    s.pos = Math.min(g.total, s.pos + s.speed * dt * s.factor);
    car.geometry.setCoordinates(pointAt(g, s.pos));
    s.pax.forEach(p => { if (!s.met.has(p.seat.id) && s.pos >= p.along - 20) { s.met.add(p.seat.id); toast(`Подберите пассажира: ${p.name}, ${p.seat.label}`); } });
    if (now - lastText > 200) {
      lastText = now;
      const next = s.pax.find(p => p.along > s.pos + 20);
      $("#eta").textContent = next ? `Пассажир ${next.name} через ${minutes((next.along - s.pos) / s.speed)}` : `До финиша ${minutes((g.total - s.pos) / s.speed)}`;
      $("#eta2").textContent = next ? `ждёт: ${next.where}` : t.route.to.name;
      $("#bar").style.width = (100 * s.pos / g.total).toFixed(1) + "%";
    }
    if (s.pos >= g.total) { finish(t); return; }
    s.raf = requestAnimationFrame(tick);
  };
  st.sim.raf = requestAnimationFrame(tick);
}
function finish(t) {
  stopSim();
  const all = tripState.get(); all[t.id] = "finished"; tripState.set(all);
  toast(`Рейс завершён. Вам начислено ${amd(paidOf(t) * SHARE)}.`);
  renderTrip(t.id);
}

/* ---------- вкладка «Заработок» ---------- */
function nextMonday() { const d = dayStart(0); d.setDate(d.getDate() + ((8 - d.getDay()) % 7 || 7)); return d; }
function renderMoney() {
  const done = [];
  for (let d = -6; d <= 0; d++) myTrips(d).forEach(t => { if (statusOf(t) === "finished" && paidOf(t) > 0) done.push(t); });
  done.sort((a, b) => b.dep - a.dep);
  const total = done.reduce((s, t) => s + paidOf(t) * SHARE, 0);
  view.innerHTML = `
    <div class="balance">
      <div class="small muted">К выплате ${nextMonday().toLocaleDateString("ru-RU", { weekday: "long", day: "numeric", month: "long" })}</div>
      <div class="sum">${amd(total)}</div>
      <div class="small muted">на карту Visa •••• 4821 · рейсов за неделю: ${done.length}</div>
    </div>
    <p class="tiny muted">Деньги за рейс становятся доступными через 24 часа после него — это время на жалобы пассажиров. Выплаты раз в неделю.</p>
    <h3>Завершённые рейсы</h3>
    ${done.length ? done.map(t => `
      <div class="op">
        <div><div class="small"><b>${t.dep.toLocaleDateString("ru-RU", { day: "numeric", month: "short" })}, ${hhmm(t.dep)}</b> · ${esc(t.route.from.name)} → ${esc(t.route.to.name)}</div>
        <div class="tiny muted">оплачено ${amd(paidOf(t))} − комиссия ${D.commissionPercent}% − госпошлина ${D.statePercent}%</div></div>
        <strong>+${amd(paidOf(t) * SHARE)}</strong>
      </div>`).join("") : '<div class="empty">Пока нет завершённых рейсов.</div>'}
    <h3>Прошлые выплаты</h3>
    <div class="op"><span class="small">Понедельник, неделю назад</span><strong>${amd(38700)}</strong></div>
    <div class="op"><span class="small">Понедельник, две недели назад</span><strong>${amd(41280)}</strong></div>`;
}

/* ---------- вкладка «Профиль» ---------- */
function renderProfile() {
  view.innerHTML = `
    <div class="driver" style="--c:var(--primary)">
      <div class="avatar">${esc(ME.name[0])}</div>
      <div style="flex:1"><div class="row"><strong>${esc(ME.name)}</strong><span class="small">★ ${ME.rating} · ${ME.trips} поездок</span></div>
      <div class="small muted">${esc(ME.car)}, ${esc(ME.color)}</div>
      <div style="margin-top:4px"><span class="plate">${esc(ME.plate)}</span></div></div>
    </div>
    <h3>Документы</h3>
    ${["Водительское удостоверение", "Техпаспорт машины", "Фото машины (2)", "Селфи с документом", "ИНН (для госпошлины и чеков)"].map(x => `<div class="check"><span class="ok">✓</span><span style="flex:1">${x}</span><span class="tiny muted">проверено</span></div>`).join("")}
    <h3>Выплаты</h3>
    <div class="check"><span>💳</span><span style="flex:1">Visa •••• 4821</span><span class="tiny muted">основная</span></div>
    <h3>Договор</h3>
    <div class="check"><span class="ok">✓</span><span style="flex:1">Оферта платформы принята: вы — перевозчик, платформа принимает оплату от вашего имени</span></div>
    <p class="tiny muted" style="margin-top:12px">Демо: в прототипе вы вошли как водитель ${esc(ME.name)}.</p>`;
}

/* ---------- старт ---------- */
renderTrips();
