/// Демо-данные: маршруты, места для подсказок, водители, расписание.
/// Координаты приблизительные; в рабочей версии всё это приходит с сервера.
library;

import 'models.dart';

class Demo {
  Demo._();

  /// Комиссия платформы, % (пример — окончательный размер не утверждён).
  static const commissionPercent = 10;

  /// Госпошлина онлайн-платформы при оплате картой (с 2026 года), %.
  static const statePercent = 4;

  /// Насколько далеко от линии маршрута может быть пассажир, метры.
  static const nearMeters = 1500.0;

  /// Демо-места посадки: на сколько метров от начала маршрута водитель ждёт пассажиров.
  /// Все в пределах начального района маршрута.
  static const meetSpots = <double>[0, 400, 900];

  /// Насколько далеко пассажир готов идти до места посадки: дальше — маршрут не предлагаем, метры.
  static const meetWalkMeters = 1000.0;

  /// То же, когда «откуда» выбрано точкой на карте: пассажир указал место точно — ищем ближе, метры.
  static const meetWalkMapPointMeters = 500.0;

  /// Начальный район маршрута: первые метры линии, где водитель может выбрать место посадки.
  static const startDistrictMeters = 1500.0;

  /// Конечный район маршрута: последние метры линии, где водитель может выбрать место высадки.
  static const endDistrictMeters = 1500.0;

  /// Надбавки к базовой цене места: переднее дороже. Сзади в легковой машине — не больше двух пассажиров.
  static const seatFrontExtra = 100;
  static const seatWindowExtra = 0;

  static const yerevanCenter = GeoPoint(40.1830, 44.5100);

  /// Куда смотрит карта при открытии, если местоположение пассажира неизвестно.
  static const republicSquare = _republic;

  static const _davtashen = Place('Давташен', GeoPoint(40.2264, 44.4930));
  static const _republic = Place('Площадь Республики', GeoPoint(40.1777, 44.5126));
  static const _norNork = Place('Нор Норк', GeoPoint(40.1990, 44.5600));
  static const _airport = Place('Аэропорт Звартноц', GeoPoint(40.1473, 44.3959));
  static const _erebuni = Place('Эребуни', GeoPoint(40.1440, 44.5300));
  static const _cascade = Place('Каскад', GeoPoint(40.1913, 44.5155));
  static const _yerevanMall = Place('Ереван Молл', GeoPoint(40.1595, 44.4880));
  static const _station = Place('Вокзал Сасунци Давид', GeoPoint(40.1563, 44.5163));
  // Места для тестовых маршрутов (координаты приблизительные).
  static const _avan = Place('Аван', GeoPoint(40.2160, 44.5650));
  static const _arabkir = Place('Арабкир', GeoPoint(40.2050, 44.5050));
  static const _achapnyak = Place('Ачапняк', GeoPoint(40.2050, 44.4600));
  static const _kanaker = Place('Канакер-Зейтун', GeoPoint(40.2090, 44.5330));
  static const _norkMarash = Place('Норк-Мараш', GeoPoint(40.1820, 44.5480));
  static const _bangladesh = Place('Бангладеш', GeoPoint(40.1630, 44.4430));
  static const _komitas = Place('Комитас', GeoPoint(40.2040, 44.5120));
  static const _dalma = Place('Далма Гарден Молл', GeoPoint(40.1800, 44.4890));
  static const _nzhdeh = Place('Метро Гарегин Нжде', GeoPoint(40.1635, 44.4960));

  static const routes = <RouteDef>[
    RouteDef(id: 'M1', color: 0xFF4F46E5, price: 500, minPrice: 400, minutes: 25, from: _davtashen, to: _republic),
    RouteDef(id: 'M2', color: 0xFF059669, price: 400, minPrice: 300, minutes: 22, from: _norNork, to: _republic),
    RouteDef(id: 'M3', color: 0xFFDC2626, price: 1200, minPrice: 1100, minutes: 30, from: _airport, to: _republic),
    RouteDef(id: 'M4', color: 0xFF9333EA, price: 400, minPrice: 300, minutes: 22, from: _erebuni, to: _cascade),
    RouteDef(id: 'M5', color: 0xFFEA580C, price: 500, minPrice: 400, minutes: 25, from: _davtashen, to: _yerevanMall),
    RouteDef(id: 'M6', color: 0xFF0891B2, price: 400, minPrice: 300, minutes: 24, from: _norNork, to: _station),
    // Обратно — к тем же маршрутам.
    RouteDef(id: 'M7', color: 0xFF2563EB, price: 500, minPrice: 400, minutes: 25, from: _republic, to: _davtashen),
    RouteDef(id: 'M8', color: 0xFF16A34A, price: 400, minPrice: 300, minutes: 22, from: _republic, to: _norNork),
    RouteDef(id: 'M9', color: 0xFFB91C1C, price: 1200, minPrice: 1100, minutes: 30, from: _republic, to: _airport),
    RouteDef(id: 'M10', color: 0xFFC026D3, price: 400, minPrice: 300, minutes: 22, from: _cascade, to: _erebuni),
    RouteDef(id: 'M11', color: 0xFFD97706, price: 500, minPrice: 400, minutes: 25, from: _yerevanMall, to: _davtashen),
    RouteDef(id: 'M12', color: 0xFF0D9488, price: 400, minPrice: 300, minutes: 24, from: _station, to: _norNork),
    // Новые направления, туда и обратно.
    RouteDef(id: 'M13', color: 0xFF7C3AED, price: 400, minPrice: 300, minutes: 18, from: _achapnyak, to: _republic),
    RouteDef(id: 'M14', color: 0xFF6D28D9, price: 400, minPrice: 300, minutes: 18, from: _republic, to: _achapnyak),
    RouteDef(id: 'M15', color: 0xFF0284C7, price: 500, minPrice: 400, minutes: 22, from: _avan, to: _republic),
    RouteDef(id: 'M16', color: 0xFF0369A1, price: 500, minPrice: 400, minutes: 22, from: _republic, to: _avan),
    RouteDef(id: 'M17', color: 0xFF65A30D, price: 400, minPrice: 300, minutes: 20, from: _bangladesh, to: _republic),
    // Короткие, 2–4 км.
    RouteDef(id: 'M18', color: 0xFFDB2777, price: 300, minPrice: 300, minutes: 8, from: _komitas, to: _cascade),
    RouteDef(id: 'M19', color: 0xFFBE185D, price: 300, minPrice: 300, minutes: 8, from: _cascade, to: _komitas),
    RouteDef(id: 'M20', color: 0xFF0E7490, price: 300, minPrice: 300, minutes: 10, from: _norkMarash, to: _republic),
    RouteDef(id: 'M21', color: 0xFF4D7C0F, price: 300, minPrice: 300, minutes: 10, from: _kanaker, to: _cascade),
    RouteDef(id: 'M22', color: 0xFFE11D48, price: 300, minPrice: 300, minutes: 10, from: _dalma, to: _republic),
    RouteDef(id: 'M23', color: 0xFF9A3412, price: 300, minPrice: 300, minutes: 8, from: _nzhdeh, to: _station),
    RouteDef(id: 'M24', color: 0xFF1D4ED8, price: 300, minPrice: 300, minutes: 12, from: _arabkir, to: _republic),
    RouteDef(id: 'M25', color: 0xFF1E40AF, price: 300, minPrice: 300, minutes: 12, from: _republic, to: _arabkir),
  ];

  /// Места для подсказок при вводе адреса (работают и без поиска Яндекса).
  static const places = <Place>[
    _republic,
    _cascade,
    Place('Опера', GeoPoint(40.1860, 44.5150)),
    _davtashen,
    _norNork,
    _avan,
    _arabkir,
    _achapnyak,
    _kanaker,
    _norkMarash,
    _bangladesh,
    _komitas,
    _dalma,
    _nzhdeh,
    Place('Метро Барекамутюн', GeoPoint(40.1962, 44.5026)),
    Place('Метро Маршал Баграмян', GeoPoint(40.1916, 44.5105)),
    Place('Метро Еритасардакан', GeoPoint(40.1860, 44.5210)),
    Place('Площадь Мясникяна', GeoPoint(40.1915, 44.5395)),
    Place('Малатия', GeoPoint(40.1717, 44.4553)),
    Place('Мост Победы', GeoPoint(40.1757, 44.4986)),
    _yerevanMall,
    _station,
    _erebuni,
    Place('Шенгавит', GeoPoint(40.1500, 44.4930)),
    _airport,
  ];

  static const drivers = <Driver>[
    Driver(name: 'Арам', rating: 4.9, trips: 214, car: 'Toyota Camry', carColor: 'белая', plate: '35 OO 123', verified: true),
    Driver(name: 'Гаяне', rating: 4.8, trips: 156, car: 'Kia K5', carColor: 'серая', plate: '01 LL 777', verified: true),
    Driver(name: 'Давид', rating: 4.7, trips: 98, car: 'Hyundai Sonata', carColor: 'чёрная', plate: '77 AA 450', verified: true),
    Driver(name: 'Нарек', rating: 4.9, trips: 301, car: 'Toyota Prius', carColor: 'синяя', plate: '18 SS 902', verified: true),
    Driver(name: 'Ани', rating: 5.0, trips: 47, car: 'Kia Optima', carColor: 'белая', plate: '11 KK 315', verified: false),
    Driver(name: 'Тигран', rating: 4.6, trips: 120, car: 'Opel Astra', carColor: 'красная', plate: '44 TT 208', verified: true),
  ];

  /// Демо-водитель в приложении водителя.
  static const meIndex = 0;

  /// Время выезда водителя с начальной точки.
  static const departures = <String>['07:30', '08:00', '08:30', '09:00', '13:00', '17:30', '18:00', '18:30', '19:30'];

  /// Демо-пассажиры, которые уже заняли места.
  static const demoPassengers = <String>['Ани', 'Сурен', 'Мари', 'Карен', 'Лилит', 'Артур', 'Нарине', 'Гор'];

  static RouteDef? routeById(String id) {
    for (final r in routes) {
      if (r.id == id) return r;
    }
    return null;
  }
}
