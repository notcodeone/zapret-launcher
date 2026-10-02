import '../zapret/install.dart';

/// Профиль сети: как работать с zapret у этого провайдера.
class NetworkProfile {
  const NetworkProfile({
    required this.asn,
    required this.name,
    this.isp,
    this.country,
    this.strategy,
    this.gameFilter = GameFilterMode.disabled,
    this.ipset = IpsetMode.none,
    this.zapretOff = false,
    required this.lastSeen,
  });

  /// Номер AS провайдера — по нему узнаём сеть: «AS12389».
  final String asn;

  /// Как человек называет сеть: «Дом», «Телефон». Сначала — название провайдера.
  final String name;

  /// Название провайдера от сервиса.
  final String? isp;
  final String? country;

  /// Стратегия (имя файла без .bat); null — не выбрана.
  final String? strategy;
  final GameFilterMode gameFilter;
  final IpsetMode ipset;

  /// В этой сети zapret не нужен — сторож выключит его.
  final bool zapretOff;
  final DateTime lastSeen;

  NetworkProfile copyWith({
    String? name,
    String? isp,
    String? country,
    String? strategy,
    GameFilterMode? gameFilter,
    IpsetMode? ipset,
    bool? zapretOff,
    DateTime? lastSeen,
  }) =>
      NetworkProfile(
        asn: asn,
        name: name ?? this.name,
        isp: isp ?? this.isp,
        country: country ?? this.country,
        strategy: strategy ?? this.strategy,
        gameFilter: gameFilter ?? this.gameFilter,
        ipset: ipset ?? this.ipset,
        zapretOff: zapretOff ?? this.zapretOff,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  Map<String, Object?> toJson() => {
        'asn': asn,
        'name': name,
        'isp': isp,
        'country': country,
        'strategy': strategy,
        'gameFilter': gameFilter.name,
        'ipset': ipset.name,
        'zapretOff': zapretOff,
        'lastSeen': lastSeen.toIso8601String(),
      };

  static NetworkProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final asn = raw['asn'];
    final name = raw['name'];
    if (asn is! String || name is! String) return null;
    T byName<T extends Enum>(List<T> values, Object? v, T fallback) =>
        values.firstWhere((e) => e.name == v, orElse: () => fallback);
    return NetworkProfile(
      asn: asn,
      name: name,
      isp: raw['isp'] as String?,
      country: raw['country'] as String?,
      strategy: raw['strategy'] as String?,
      gameFilter: byName(GameFilterMode.values, raw['gameFilter'], GameFilterMode.disabled),
      ipset: byName(IpsetMode.values, raw['ipset'], IpsetMode.none),
      zapretOff: raw['zapretOff'] as bool? ?? false,
      lastSeen: DateTime.tryParse(raw['lastSeen'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

/// Короткое имя провайдера: без «LLC», «PJSC» и прочих хвостов.
String providerShortName(String? isp, String asn) {
  if (isp == null || isp.trim().isEmpty) return asn;
  var s = isp.trim();
  s = s.replaceAll(RegExp(r'^(PJSC|OJSC|JSC|LLC|OOO|ООО|ПАО|АО|ZAO|CJSC)\s+', caseSensitive: false), '');
  s = s.replaceAll(
      RegExp(r'[,\s]+(PJSC|OJSC|JSC|LLC|Ltd\.?|Inc\.?|GmbH|B\.V\.|networks?|telecom)$', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'^"|"$'), '').trim();
  return s.isEmpty ? asn : s;
}
