import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'aes_ctr.dart';

// Обфускация MTProto (obfuscated2) — как в Flowseal/tg-ws-proxy (proxy/tg_ws_proxy.py
// и proxy/bridge.py): Telegram Desktop шифрует поток ключом из своего первого пакета
// и секрета прокси; прокси расшифровывает его и шифрует заново — уже для серверов
// Telegram, своим первым пакетом без секрета.

/// Длина первого пакета обфускации.
const handshakeLength = 64;
const _skip = 8;
const _prekey = 32;
const _iv = 16;
const _tagPos = 56;
const _dcPos = 60;

/// Транспорт MTProto внутри обфускации — по метке в первом пакете.
enum MtprotoTransport {
  abridged(0xef),
  intermediate(0xee),
  paddedIntermediate(0xdd);

  const MtprotoTransport(this.tagByte);

  /// Метка — четыре одинаковых байта.
  final int tagByte;

  static MtprotoTransport? fromTag(Uint8List b, int offset) {
    for (final t in values) {
      if (b[offset] == t.tagByte &&
          b[offset + 1] == t.tagByte &&
          b[offset + 2] == t.tagByte &&
          b[offset + 3] == t.tagByte) {
        return t;
      }
    }
    return null;
  }
}

/// Куда просится клиент: дата-центр, медиа или нет, тестовый ли.
class TelegramTarget {
  const TelegramTarget(this.dc, {this.media = false, this.test = false});

  final int dc;
  final bool media;

  /// Тестовые DC Telegram (в рукопожатии — номера от 10000).
  final bool test;

  /// Номер DC в первом пакете для серверов: у медиа — отрицательный.
  int get index => media ? -dc : dc;

  @override
  String toString() => 'DC$dc${media ? ' медиа' : ''}${test ? ' тест' : ''}';
}

/// Разобранный первый пакет клиента.
class ClientHandshake {
  const ClientHandshake._(this.target, this.transport, this._prekeyIv);

  final TelegramTarget target;
  final MtprotoTransport transport;

  /// Байты 8–56 первого пакета: из них и секрета — ключи клиента.
  final Uint8List _prekeyIv;

  /// null — неверный секрет или не MTProto.
  static ClientHandshake? parse(Uint8List init, Uint8List secret) {
    if (init.length != handshakeLength) return null;
    final prekeyIv = Uint8List.fromList(
      init.sublist(_skip, _skip + _prekey + _iv),
    );
    final cipher = AesCtr(
      _sha256(prekeyIv.sublist(0, _prekey), secret),
      prekeyIv.sublist(_prekey),
    );
    final plain = cipher.process(init);
    cipher.dispose();
    final transport = MtprotoTransport.fromTag(plain, _tagPos);
    if (transport == null) return null;
    final index = ByteData.sublistView(plain).getInt16(_dcPos, Endian.little);
    var dc = index.abs();
    final test = dc >= 10000;
    if (test) dc -= 10000;
    return ClientHandshake._(
      TelegramTarget(dc, media: index < 0, test: test),
      transport,
      prekeyIv,
    );
  }
}

/// Первый пакет для серверов Telegram: случайный, но не похожий на начало другого
/// протокола (HTTP, TLS, транспорты без обфускации), с меткой транспорта и номером DC.
Uint8List relayHandshake(
  MtprotoTransport transport,
  TelegramTarget target, {
  Random? random,
}) {
  final rnd = random ?? Random.secure();
  final init = Uint8List(handshakeLength);
  do {
    for (var i = 0; i < handshakeLength; i++) {
      init[i] = rnd.nextInt(256);
    }
  } while (_reserved(init));

  final cipher = AesCtr(
    init.sublist(_skip, _skip + _prekey),
    init.sublist(_skip + _prekey, _skip + _prekey + _iv),
  );
  final encrypted = cipher.process(init);
  cipher.dispose();
  final tail = Uint8List(8);
  tail.fillRange(0, 4, transport.tagByte);
  ByteData.sublistView(tail).setInt16(4, target.index, Endian.little);
  tail[6] = rnd.nextInt(256);
  tail[7] = rnd.nextInt(256);
  // Хвост — метка и DC, зашифрованные той же гаммой; начало пакета остаётся открытым.
  for (var i = 0; i < 8; i++) {
    init[_tagPos + i] = tail[i] ^ encrypted[_tagPos + i] ^ init[_tagPos + i];
  }
  return init;
}

bool _reserved(Uint8List b) {
  if (b[0] == 0xef) return true;
  final start = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  const starts = {
    0x48454144, // HEAD
    0x504f5354, // POST
    0x47455420, // GET
    0xeeeeeeee,
    0xdddddddd,
    0x16030102, // TLS ClientHello
    0x4f505449, // OPTI(ONS)
  };
  if (starts.contains(start)) return true;
  return b[4] == 0 && b[5] == 0 && b[6] == 0 && b[7] == 0;
}

/// Четыре шифра сессии: клиент ↔ прокси и прокси ↔ Telegram, по шифру на направление.
class SessionCiphers {
  SessionCiphers(
    ClientHandshake client,
    Uint8List secret,
    Uint8List relayInit,
  ) {
    final dec = client._prekeyIv;
    fromClient = AesCtr(
      _sha256(dec.sublist(0, _prekey), secret),
      dec.sublist(_prekey),
    );
    // Первые 64 байта клиент уже отправил — гамма сдвигается на их длину.
    fromClient.process(Uint8List(handshakeLength));
    final enc = Uint8List.fromList(dec.reversed.toList());
    toClient = AesCtr(
      _sha256(enc.sublist(0, _prekey), secret),
      enc.sublist(_prekey),
    );

    final relay = relayInit.sublist(_skip, _skip + _prekey + _iv);
    toTelegram = AesCtr(relay.sublist(0, _prekey), relay.sublist(_prekey));
    toTelegram.process(Uint8List(handshakeLength));
    final back = Uint8List.fromList(relay.reversed.toList());
    fromTelegram = AesCtr(back.sublist(0, _prekey), back.sublist(_prekey));
  }

  late final AesCtr fromClient;
  late final AesCtr toClient;
  late final AesCtr toTelegram;
  late final AesCtr fromTelegram;

  /// Байты клиента → байты для Telegram; [plain] получает открытый текст (для нарезки).
  Uint8List upstream(Uint8List data, [void Function(Uint8List plain)? plain]) {
    final open = fromClient.process(data);
    plain?.call(open);
    return toTelegram.process(open);
  }

  /// Байты от Telegram → байты для клиента.
  Uint8List downstream(Uint8List data) =>
      toClient.process(fromTelegram.process(data));

  void dispose() {
    fromClient.dispose();
    toClient.dispose();
    toTelegram.dispose();
    fromTelegram.dispose();
  }
}

/// Режет поток к Telegram на пакеты транспорта: в WebSocket каждый пакет MTProto
/// уходит отдельным сообщением. Длину читает из открытого текста, режет зашифрованный —
/// в CTR их байты совпадают по позициям. Непонятная длина — дальше без нарезки.
class PacketSplitter {
  PacketSplitter(this.transport);

  final MtprotoTransport transport;
  final _cipher = BytesBuilder(copy: false);
  final _plain = BytesBuilder(copy: false);
  bool _disabled = false;

  /// Целые пакеты из накопленного; хвост ждёт следующего куска.
  List<Uint8List> split(Uint8List cipher, Uint8List plain) {
    if (cipher.isEmpty) return const [];
    if (_disabled) return [cipher];
    _cipher.add(cipher);
    _plain.add(plain);
    final c = _cipher.takeBytes();
    final p = _plain.takeBytes();

    final parts = <Uint8List>[];
    var offset = 0;
    while (offset < c.length) {
      final len = _packetLength(p, offset, c.length - offset);
      if (len == null) break;
      if (len <= 0) {
        parts.add(Uint8List.sublistView(c, offset));
        offset = c.length;
        _disabled = true;
        break;
      }
      parts.add(Uint8List.sublistView(c, offset, offset + len));
      offset += len;
    }
    if (offset < c.length) {
      _cipher.add(Uint8List.sublistView(c, offset));
      _plain.add(Uint8List.sublistView(p, offset));
    }
    return parts;
  }

  /// Недособранный хвост — когда клиент закрыл соединение.
  List<Uint8List> flush() {
    final tail = _cipher.takeBytes();
    _plain.clear();
    return tail.isEmpty ? const [] : [tail];
  }

  /// Длина пакета с заголовком; null — данных пока мало; 0 — не разобрать.
  int? _packetLength(Uint8List p, int offset, int available) {
    if (transport == MtprotoTransport.abridged) {
      final first = p[offset];
      final int header;
      final int payload;
      if (first == 0x7f || first == 0xff) {
        if (available < 4) return null;
        header = 4;
        payload =
            (p[offset + 1] | (p[offset + 2] << 8) | (p[offset + 3] << 16)) * 4;
      } else {
        header = 1;
        payload = (first & 0x7f) * 4;
      }
      if (payload <= 0) return 0;
      return available < header + payload ? null : header + payload;
    }
    if (available < 4) return null;
    final payload =
        ByteData.sublistView(
          p,
          offset,
          offset + 4,
        ).getUint32(0, Endian.little) &
        0x7fffffff;
    if (payload <= 0) return 0;
    return available < 4 + payload ? null : 4 + payload;
  }
}

Uint8List _sha256(List<int> a, List<int> b) =>
    Uint8List.fromList(sha256.convert([...a, ...b]).bytes);
