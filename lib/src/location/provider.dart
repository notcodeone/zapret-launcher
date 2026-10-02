import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_info.dart';

/// Провайдер, через которого компьютер выходит в интернет: номер AS и название.
/// Как блокировать — решает провайдер, поэтому и стратегия у каждого своя.
typedef ProviderResult = ({String asn, String? isp, String? country, String source});
typedef ProviderLookup = Future<ProviderResult> Function();

/// Сервис, который по IP называет провайдера. Без ключей.
class ProviderSource {
  const ProviderSource(this.name, this.url, this.parse);

  final String name;
  final String url;
  final ({String? asn, String? isp, String? country}) Function(Map<String, dynamic> json) parse;

  static const all = [
    ProviderSource(
      'ipwho.is',
      'https://ipwho.is/?fields=success,country_code,connection',
      _ipwho,
    ),
    ProviderSource('ipapi.co', 'https://ipapi.co/json/', _ipapi),
  ];

  /// `{"success": true, "country_code": "RU", "connection": {"asn": 12389, "isp": "Rostelecom"}}`
  static ({String? asn, String? isp, String? country}) _ipwho(Map<String, dynamic> json) {
    if (json['success'] == false) return (asn: null, isp: null, country: null);
    final c = json['connection'];
    final asn = c is Map ? c['asn'] : null;
    final isp = c is Map ? (c['isp'] ?? c['org']) as String? : null;
    return (asn: asn == null ? null : 'AS$asn', isp: isp, country: json['country_code'] as String?);
  }

  /// `{"asn": "AS12389", "org": "Rostelecom", "country_code": "RU"}`
  static ({String? asn, String? isp, String? country}) _ipapi(Map<String, dynamic> json) {
    if (json['error'] == true) return (asn: null, isp: null, country: null);
    return (
      asn: json['asn'] as String?,
      isp: json['org'] as String?,
      country: json['country_code'] as String?,
    );
  }
}

/// Номер AS в одном виде: «AS12389».
String? normalizeAsn(String? raw) {
  if (raw == null) return null;
  final m = RegExp(r'^(?:AS)?(\d+)$', caseSensitive: false).firstMatch(raw.trim());
  return m == null ? null : 'AS${m[1]}';
}

class ProviderLookupException implements Exception {
  const ProviderLookupException(this.errors);

  final List<String> errors;

  @override
  String toString() => errors.isEmpty ? 'нет ответа' : errors.join('; ');
}

/// Провайдер по IP: спрашиваем сервисы по очереди — следующий, если прежний
/// не ответил за [stagger] или ответил ошибкой.
Future<ProviderResult> lookupProvider({
  List<ProviderSource> sources = ProviderSource.all,
  Duration timeout = const Duration(seconds: 5),
  Duration stagger = const Duration(milliseconds: 800),
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = ((_) => 'DIRECT')
    ..userAgent = AppInfo.name;
  final result = Completer<ProviderResult>();
  final errors = <String>[];
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
        (r) {
          if (!result.isCompleted) result.complete(r);
        },
        onError: (Object e) {
          errors.add('${source.name}: $e');
        },
      ).whenComplete(() {
        if (!settled.isCompleted) settled.complete();
      }));
    }
    await Future.any([result.future, Future.wait(asked)]);
    if (result.isCompleted) return await result.future;
    throw ProviderLookupException(errors);
  } finally {
    client.close(force: true);
  }
}

Future<ProviderResult> _ask(HttpClient client, ProviderSource source, Duration timeout) async {
  final request = await client.getUrl(Uri.parse(source.url)).timeout(timeout);
  final response = await request.close().timeout(timeout);
  final body = await utf8.decodeStream(response).timeout(timeout);
  if (response.statusCode != HttpStatus.ok) throw Exception('HTTP ${response.statusCode}');
  final json = jsonDecode(body);
  if (json is! Map<String, dynamic>) throw const FormatException('не JSON');
  final parsed = source.parse(json);
  final asn = normalizeAsn(parsed.asn);
  if (asn == null) throw const FormatException('провайдер не указан');
  final isp = parsed.isp?.trim();
  return (
    asn: asn,
    isp: isp == null || isp.isEmpty ? null : isp,
    country: parsed.country?.toUpperCase(),
    source: source.name,
  );
}
