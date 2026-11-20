/// Адрес сервера и публичный ключ приложения.
///
/// Публичный ключ (publishable) рассчитан на то, чтобы лежать в приложении: сам по себе он ничего не открывает.
/// Что видит и может человек, решают правила сервера после входа по SMS. Секретные ключи сервера
/// (service_role, пароль базы) в приложения и в репозиторий не попадают.
library;

/// Тестовый проект в облаке: transportapp-test (Франкфурт).
const serverUrl = String.fromEnvironment('SERVER_URL', defaultValue: 'https://xfocvxrkwzzcscjwtcnq.supabase.co');

const serverPublishableKey =
    String.fromEnvironment('SERVER_KEY', defaultValue: 'sb_publishable_yYVbKv1tgxyrJ9dQavoeog_bfaJR2Ua');
