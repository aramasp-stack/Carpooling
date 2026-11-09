import 'package:shared_preferences/shared_preferences.dart';
import 'package:transport_core/transport_core.dart';

/// Хранение данных на телефоне через SharedPreferences.
class PrefsStore implements KeyValueStore {
  PrefsStore(this._prefs);
  final SharedPreferences _prefs;

  static Future<PrefsStore> open() async => PrefsStore(await SharedPreferences.getInstance());

  @override
  String? read(String key) => _prefs.getString(key);

  @override
  Future<void> write(String key, String value) => _prefs.setString(key, value);
}
