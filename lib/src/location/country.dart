import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_info.dart';
import 'countries.dart';

/// Публичный сервис, который по IP-адресу называет страну. Все — без ключей;
/// спрашиваем по очереди до первого внятного ответа. Как в ClaudeLauncher.
class CountrySource {
  const CountrySource(this.name, this.url, this.parse);

  final String name;
  final String url;

  /// Код страны из ответа; null — ответ не подошёл.
  final String? Function(String body) parse;

  static const all = [
    CountrySource('country.is', 'https://api.country.is/', _countryField),
    CountrySource('Cloudflare', 'https://www.cloudflare.com/cdn-cgi/trace', _traceLoc),
    CountrySource('ipwho.is', 'https://ipwho.is/?fields=success,country_code', _countryCodeField),
    CountrySource('ipapi.co', 'https://ipapi.co/country/', _plain),
  ];

  /// `{"ip": "…", "country": "DE"}`
  static String? _countryField(String body) => _jsonField(body, 'country');

  /// `{"success": true, "country_code": "DE"}`
  static String? _countryCodeField(String body) => _jsonField(body, 'country_code');

  /// Строки `ключ=значение`, страна — `loc=DE`.
  static String? _traceLoc(String body) =>
      RegExp(r'^loc=(\S+)$', multiLine: true).firstMatch(body)?.group(1);

  /// Просто `DE`.
  static String? _plain(String body) => body.trim();

  static String? _jsonField(String body, String field) {
    try {
      final json = jsonDecode(body);
      return json is Map ? json[field] as String? : null;
    } on FormatException {
      return null;
    }
  }
}

/// Не удалось узнать страну ни у одного сервиса.
class CountryLookupException implements Exception {
  const CountryLookupException(this.errors);

  final List<String> errors;

  @override
  String toString() => errors.isEmpty ? 'нет ответа' : errors.join('; ');
}

typedef CountryResult = ({String country, String source});
typedef CountryLookup = Future<CountryResult> Function();

String countryName(String code) => countryNames[code] ?? code;

/// Страна по IP-адресу: код ISO 3166-1 и какой сервис ответил.
///
/// Следующий сервис спрашиваем, если прежние не ответили за [stagger] или
/// ответили ошибкой: обычно хватает первого, а недоступный не задерживает.
Future<CountryResult> lookupCountry({
  List<CountrySource> sources = CountrySource.all,
  Duration timeout = const Duration(seconds: 4),
  Duration stagger = const Duration(milliseconds: 300),
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = ((_) => 'DIRECT')
    ..userAgent = AppInfo.name;
  final result = Completer<CountryResult>();
  final errors = List<String?>.filled(sources.length, null);
  final asked = <Future<void>>[];
  var settled = Completer<void>();
  try {
    for (final (index, source) in sources.indexed) {
      if (index > 0) {
        await Future.any([Future<void>.delayed(stagger), settled.future]);
        settled = Completer<void>();
      }
      if (result.isCompleted) break;
      asked.add(_ask(client, source, timeout).then(
        (country) {
          if (!result.isCompleted) result.complete((country: country, source: source.name));
        },
        onError: (Object error) {
          errors[index] = '${source.name}: $error';
        },
      ).whenComplete(() {
        if (!settled.isCompleted) settled.complete();
      }));
    }
    await Future.any([result.future, Future.wait(asked)]);
    if (result.isCompleted) return await result.future;
    throw CountryLookupException([...errors.nonNulls]);
  } finally {
    // Остальные запросы больше не нужны.
    client.close(force: true);
  }
}

Future<String> _ask(HttpClient client, CountrySource source, Duration timeout) async {
  final request = await client.getUrl(Uri.parse(source.url)).timeout(timeout);
  final response = await request.close().timeout(timeout);
  final body = await utf8.decodeStream(response).timeout(timeout);
  if (response.statusCode != HttpStatus.ok) throw _Failure('HTTP ${response.statusCode}');
  // Сервисы отвечают и не странами: XX — неизвестно, T1 — Tor.
  final code = source.parse(body)?.toUpperCase();
  if (code == null || !countryNames.containsKey(code)) throw const _Failure('страна не указана');
  return code;
}

class _Failure implements Exception {
  const _Failure(this.message);

  final String message;

  @override
  String toString() => message;
}
