import 'package:yandex_maps_mapkit/init.dart' as init;

/// Ключ «MapKit – мобильный SDK» из кабинета разработчика Яндекса.
/// Передаётся при сборке: flutter run --dart-define=MAPKIT_API_KEY=ваш-ключ
const mapkitApiKey = String.fromEnvironment('MAPKIT_API_KEY');

bool get hasMapkitKey => mapkitApiKey.isNotEmpty;

/// Запуск Яндекс MapKit. Без ключа карта не показывается, остальное приложение работает.
Future<void> setupMapkit() async {
  if (!hasMapkitKey) return;
  await init.initMapkit(apiKey: mapkitApiKey, locale: 'ru_RU');
}
