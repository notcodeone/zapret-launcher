import 'dart:io';
import 'dart:typed_data';

import '../platform/bcrypt.dart' as bcrypt;

/// AES-256-CTR — шифрование обфускации MTProto. В CTR шифрование и расшифровка —
/// одно и то же: поток XOR-ится с гаммой, поэтому один метод на оба направления.
abstract interface class AesCtr {
  /// Без [native] — на чистом Dart. По умолчанию в Windows — через CNG
  /// (аппаратный AES), если он доступен и прошёл проверку [cngWorks].
  factory AesCtr(Uint8List key, Uint8List iv, {bool? native}) {
    if ((native ?? Platform.isWindows) && cngWorks) {
      final cng = bcrypt.CngAesCtr.tryCreate(key, iv);
      if (cng != null) return cng;
    }
    return DartAesCtr(key, iv);
  }

  /// CNG доступен и шифрует так же, как эталон: сверяется один раз на изолят —
  /// с вектором NIST SP 800-38A и с реализацией на Dart на кусках разной длины.
  /// Любое расхождение или ошибка — шифруем на Dart: неверная гамма сломала бы
  /// каждое подключение Telegram, а Dart лишь медленнее.
  static bool get cngWorks => _cngWorks ??= _checkCng();
  static bool? _cngWorks;

  static bool _checkCng() {
    AesCtr? cng;
    try {
      final key = Uint8List.fromList(List.generate(32, (i) => i * 7 + 3));
      final iv = Uint8List.fromList(List.generate(16, (i) => 0xf0 + i));
      // Младшие байты счётчика у края — проверяется и перенос.
      iv.fillRange(12, 16, 0xff);
      cng = bcrypt.CngAesCtr.tryCreate(key, iv);
      if (cng == null) return false;
      final dart = DartAesCtr(key, iv);
      final data = Uint8List.fromList(List.generate(4099, (i) => i * 31));
      var i = 0;
      for (final n in const [1, 5, 16, 17, 60, 1000, 3000]) {
        final end = i + n < data.length ? i + n : data.length;
        final chunk = Uint8List.sublistView(data, i, end);
        final a = cng.process(chunk);
        final b = dart.process(chunk);
        for (var j = 0; j < a.length; j++) {
          if (a[j] != b[j]) return false;
        }
        i = end;
      }
      return _nistVector();
    } on Object {
      return false;
    } finally {
      cng?.dispose();
    }
  }

  /// NIST SP 800-38A F.5.5 (CTR-AES256), первые два блока — через CNG.
  static bool _nistVector() {
    Uint8List hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);
    final cng = bcrypt.CngAesCtr.tryCreate(
      hex('603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4'),
      hex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff'),
    );
    if (cng == null) return false;
    try {
      final out = cng.process(
        hex('6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51'),
      );
      final want = hex(
        '601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5',
      );
      for (var j = 0; j < want.length; j++) {
        if (out[j] != want[j]) return false;
      }
      return true;
    } finally {
      cng.dispose();
    }
  }

  /// Следующий кусок потока: возвращает новый буфер той же длины.
  Uint8List process(Uint8List data);

  /// Освобождает ключ в CNG; после этого шифр не используется.
  void dispose();
}

/// Номер блока CTR — 128-битное число big-endian, как в cryptography (Python):
/// при переполнении младших байт перенос идёт в старшие.
void incrementCounter(Uint8List counter) {
  for (var i = 15; i >= 0; i--) {
    counter[i] = (counter[i] + 1) & 0xff;
    if (counter[i] != 0) return;
  }
}

/// AES-CTR на чистом Dart (табличная реализация). Нужен там, где нет CNG, —
/// в тестах вне Windows, — и как запасной вариант.
class DartAesCtr implements AesCtr {
  DartAesCtr(Uint8List key, Uint8List iv)
    : _rk = _expandKey(key),
      _rounds = key.length ~/ 4 + 6 {
    if (iv.length != 16) throw ArgumentError.value(iv.length, 'iv', '16 байт');
    _counter.setAll(0, iv);
  }

  final Uint32List _rk;
  final int _rounds;
  final _counter = Uint8List(16);
  final _stream = Uint8List(16);

  /// Сколько байт гаммы из [_stream] уже израсходовано (16 — нужен новый блок).
  int _used = 16;

  @override
  Uint8List process(Uint8List data) {
    final out = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) {
      if (_used == 16) {
        _encryptBlock(_counter, _stream);
        incrementCounter(_counter);
        _used = 0;
      }
      out[i] = data[i] ^ _stream[_used++];
    }
    return out;
  }

  @override
  void dispose() {}

  void _encryptBlock(Uint8List input, Uint8List output) {
    final rk = _rk;
    var s0 = _be32(input, 0) ^ rk[0];
    var s1 = _be32(input, 4) ^ rk[1];
    var s2 = _be32(input, 8) ^ rk[2];
    var s3 = _be32(input, 12) ^ rk[3];
    var k = 4;
    for (var r = 1; r < _rounds; r++) {
      final t0 =
          _te0[s0 >> 24] ^
          _te1[(s1 >> 16) & 0xff] ^
          _te2[(s2 >> 8) & 0xff] ^
          _te3[s3 & 0xff] ^
          rk[k];
      final t1 =
          _te0[s1 >> 24] ^
          _te1[(s2 >> 16) & 0xff] ^
          _te2[(s3 >> 8) & 0xff] ^
          _te3[s0 & 0xff] ^
          rk[k + 1];
      final t2 =
          _te0[s2 >> 24] ^
          _te1[(s3 >> 16) & 0xff] ^
          _te2[(s0 >> 8) & 0xff] ^
          _te3[s1 & 0xff] ^
          rk[k + 2];
      final t3 =
          _te0[s3 >> 24] ^
          _te1[(s0 >> 16) & 0xff] ^
          _te2[(s1 >> 8) & 0xff] ^
          _te3[s2 & 0xff] ^
          rk[k + 3];
      s0 = t0;
      s1 = t1;
      s2 = t2;
      s3 = t3;
      k += 4;
    }
    _put32(output, 0, _lastRound(s0, s1, s2, s3) ^ rk[k]);
    _put32(output, 4, _lastRound(s1, s2, s3, s0) ^ rk[k + 1]);
    _put32(output, 8, _lastRound(s2, s3, s0, s1) ^ rk[k + 2]);
    _put32(output, 12, _lastRound(s3, s0, s1, s2) ^ rk[k + 3]);
  }

  static int _lastRound(int a, int b, int c, int d) =>
      (_sbox[a >> 24] << 24) |
      (_sbox[(b >> 16) & 0xff] << 16) |
      (_sbox[(c >> 8) & 0xff] << 8) |
      _sbox[d & 0xff];

  static Uint32List _expandKey(Uint8List key) {
    if (key.length != 16 && key.length != 24 && key.length != 32) {
      throw ArgumentError.value(key.length, 'key', '16, 24 или 32 байта');
    }
    final nk = key.length ~/ 4;
    final total = 4 * (nk + 7);
    final w = Uint32List(total);
    for (var i = 0; i < nk; i++) {
      w[i] = _be32(key, 4 * i);
    }
    var rcon = 1;
    for (var i = nk; i < total; i++) {
      var t = w[i - 1];
      if (i % nk == 0) {
        t = _subWord((t << 8 | t >> 24) & 0xffffffff) ^ (rcon << 24);
        rcon = _xtime(rcon);
      } else if (nk > 6 && i % nk == 4) {
        t = _subWord(t);
      }
      w[i] = w[i - nk] ^ t;
    }
    return w;
  }

  static int _subWord(int w) =>
      (_sbox[w >> 24] << 24) |
      (_sbox[(w >> 16) & 0xff] << 16) |
      (_sbox[(w >> 8) & 0xff] << 8) |
      _sbox[w & 0xff];
}

int _be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

void _put32(Uint8List b, int o, int v) {
  b[o] = v >> 24;
  b[o + 1] = v >> 16;
  b[o + 2] = v >> 8;
  b[o + 3] = v;
}

int _xtime(int x) => ((x << 1) ^ ((x & 0x80) != 0 ? 0x1b : 0)) & 0xff;

// S-блок и таблицы раундов считаются один раз при первом обращении.
final Uint8List _sbox = _buildSbox();
final Uint32List _te0 = _buildTe(0);
final Uint32List _te1 = _buildTe(8);
final Uint32List _te2 = _buildTe(16);
final Uint32List _te3 = _buildTe(24);

Uint8List _buildSbox() {
  final sbox = Uint8List(256);
  int rotl(int x, int s) => ((x << s) | (x >> (8 - s))) & 0xff;
  // p пробегает все ненулевые элементы GF(2^8), q — обратный к нему.
  var p = 1, q = 1;
  do {
    p = p ^ _xtime(p);
    q ^= q << 1;
    q ^= q << 2;
    q ^= q << 4;
    q &= 0xff;
    if (q & 0x80 != 0) q ^= 0x09;
    sbox[p] = q ^ rotl(q, 1) ^ rotl(q, 2) ^ rotl(q, 3) ^ rotl(q, 4) ^ 0x63;
  } while (p != 1);
  sbox[0] = 0x63;
  return sbox;
}

Uint32List _buildTe(int rotate) {
  final te = Uint32List(256);
  for (var x = 0; x < 256; x++) {
    final s = _sbox[x];
    final s2 = _xtime(s);
    final v = (s2 << 24) | (s << 16) | (s << 8) | (s2 ^ s);
    te[x] = rotate == 0
        ? v
        : ((v >> rotate) | (v << (32 - rotate))) & 0xffffffff;
  }
  return te;
}
