// Демо-данные прототипа. Координаты остановок приблизительные:
// в настоящем сервисе их задаёт администратор в редакторе маршрутов.

window.DEMO = {
  commissionPercent: 10, // комиссия платформы, %
  statePercent: 4,       // госпошлина онлайн-платформы (безнал, с 2026), %

  routes: [
    {
      id: "M1",
      name: "Давташен — Площадь Республики",
      color: "#2563eb",
      price: 500,
      minutes: 28,
      stops: [
        { name: "Давташен", lat: 40.2264, lon: 44.4930 },
        { name: "Метро Барекамутюн", lat: 40.1962, lon: 44.5026 },
        { name: "Метро Маршал Баграмян", lat: 40.1916, lon: 44.5105 },
        { name: "Опера", lat: 40.1860, lon: 44.5150 },
        { name: "Площадь Республики", lat: 40.1777, lon: 44.5126 }
      ]
    },
    {
      id: "M2",
      name: "Нор Норк — Площадь Республики",
      color: "#16a34a",
      price: 400,
      minutes: 25,
      stops: [
        { name: "Нор Норк", lat: 40.1990, lon: 44.5600 },
        { name: "Площадь Мясникяна", lat: 40.1915, lon: 44.5395 },
        { name: "Метро Еритасардакан", lat: 40.1860, lon: 44.5210 },
        { name: "Площадь Республики", lat: 40.1777, lon: 44.5126 }
      ]
    },
    {
      id: "M3",
      name: "Аэропорт Звартноц — Площадь Республики",
      color: "#dc2626",
      price: 1200,
      minutes: 35,
      stops: [
        { name: "Аэропорт Звартноц", lat: 40.1473, lon: 44.3959 },
        { name: "Малатия", lat: 40.1717, lon: 44.4553 },
        { name: "Мост Победы", lat: 40.1757, lon: 44.4986 },
        { name: "Площадь Республики", lat: 40.1777, lon: 44.5126 }
      ]
    },
    {
      id: "M4",
      name: "Эребуни — Каскад",
      color: "#9333ea",
      price: 400,
      minutes: 26,
      stops: [
        { name: "Эребуни", lat: 40.1440, lon: 44.5300 },
        { name: "Вокзал Сасунци Давид", lat: 40.1563, lon: 44.5163 },
        { name: "Площадь Республики", lat: 40.1777, lon: 44.5126 },
        { name: "Каскад", lat: 40.1913, lon: 44.5155 }
      ]
    }
  ],

  drivers: [
    { name: "Арам", rating: 4.9, trips: 214, car: "Toyota Camry", color: "белая", plate: "35 OO 123", verified: true },
    { name: "Гаяне", rating: 4.8, trips: 156, car: "Kia K5", color: "серая", plate: "01 LL 777", verified: true },
    { name: "Давид", rating: 4.7, trips: 98, car: "Hyundai Sonata", color: "чёрная", plate: "77 AA 450", verified: true },
    { name: "Нарек", rating: 4.9, trips: 301, car: "Toyota Prius", color: "синяя", plate: "18 SS 902", verified: true },
    { name: "Ани", rating: 5.0, trips: 47, car: "Kia Optima", color: "белая", plate: "11 KK 315", verified: false },
    { name: "Тигран", rating: 4.6, trips: 120, car: "Opel Astra", color: "красная", plate: "44 TT 208", verified: true }
  ],

  // Время отправления от первой остановки маршрута
  departures: ["07:30", "08:15", "09:00", "13:00", "17:30", "18:15", "19:00", "20:30"]
};
