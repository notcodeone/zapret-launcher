import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../app_info.dart';

/// Обращение: ошибка или предложение. Имя — как в API сервера.
enum FeedbackKind { bug, idea }

class FeedbackException implements Exception {
  const FeedbackException(this.message, {this.retryAfter});

  /// Можно показать человеку как есть.
  final String message;
  final Duration? retryAfter;

  @override
  String toString() => message;
}

/// Сколько символов принимает сервер (длина — как `String.length`).
const feedbackTextMin = 3;
const feedbackTextMax = 3000;
const feedbackLogMax = 8000;

const _failed = 'Не удалось отправить обращение, попробуйте позже.';

/// Убирает из текста имя пользователя, имя компьютера, пути профиля и адреса IPv4.
/// Длинные значения заменяются раньше коротких: APPDATA лежит внутри USERPROFILE.
String anonymizeLocal(String text, {Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  const marks = [
    ('LOCALAPPDATA', '%LOCALAPPDATA%'),
    ('APPDATA', '%APPDATA%'),
    ('USERPROFILE', '%USERPROFILE%'),
    ('COMPUTERNAME', '<host>'),
    ('USERNAME', '<user>'),
    ('USERDOMAIN', '<host>'),
  ];
  var out = text;
  for (final (name, mark) in marks) {
    final value = env[name];
    if (value == null || value.length < 3) continue;
    out = out.replaceAll(
      RegExp(RegExp.escape(value), caseSensitive: false),
      mark,
    );
  }
  return out
      .replaceAll(
        RegExp(r'[A-Za-z]:[\\/]+Users[\\/]+[^\\/\r\n]+', caseSensitive: false),
        '%USERPROFILE%',
      )
      .replaceAll(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'), '<ip>');
}

int _leadingZeroBits(List<int> bytes) {
  var n = 0;
  for (final b in bytes) {
    if (b == 0) {
      n += 8;
      continue;
    }
    var x = b;
    while (x & 0x80 == 0) {
      n++;
      x <<= 1;
    }
    break;
  }
  return n;
}

/// Задача сервера: первый `nonce`, у SHA-256 от `challenge:nonce` которого
/// первые [difficulty] бит нулевые. Защита от массовой рассылки: человеку —
/// доли секунды, спамеру — дорого.
String solvePow(String challenge, int difficulty) {
  final prefix = utf8.encode('$challenge:');
  for (var nonce = 0; ; nonce++) {
    final digest = sha256.convert([...prefix, ...ascii.encode('$nonce')]);
    if (_leadingZeroBits(digest.bytes) >= difficulty) return '$nonce';
  }
}

/// Отправка обращений на сервер поддержки. Сервер — только после нажатия
/// «Отправить»: ровно запрос задачи и само обращение, без фоновых повторов.
class FeedbackClient {
  FeedbackClient({String? server, http.Client? client})
    : server = server ?? AppInfo.feedbackServer,
      _http = client ?? http.Client();

  /// Адрес сервера без «/» в конце; пустой — отправка в этой сборке не настроена.
  final String server;
  final http.Client _http;

  bool get configured => server.isNotEmpty;

  static const _timeout = Duration(seconds: 15);

  /// Отправляет обращение и возвращает его номер.
  /// [details] — только поля из договорённости с сервером, значения String или bool.
  /// [log] — уже обезличенный журнал.
  Future<int> send({
    required FeedbackKind kind,
    required String text,
    Map<String, Object>? details,
    String? log,
  }) async {
    if (!configured) {
      throw const FeedbackException(
        'Отправка обращений в этой сборке не настроена.',
      );
    }
    try {
      // Задача устарела или уже использована — один раз сразу берём новую.
      for (var attempt = 0; attempt < 2; attempt++) {
        final ch = await _http
            .get(Uri.parse('$server/v1/challenge'))
            .timeout(_timeout);
        if (ch.statusCode != 200) throw _error(ch);
        final task = _json(ch);
        final challenge = task['challenge'];
        final difficulty = task['difficulty'];
        if (challenge is! String || difficulty is! int) {
          throw const FeedbackException(_failed);
        }
        final nonce = await Isolate.run(() => solvePow(challenge, difficulty));

        final res = await _http
            .post(
              Uri.parse('$server/v1/feedback'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({
                'kind': kind.name,
                'text': text,
                if (details != null && details.isNotEmpty) 'details': details,
                if (log != null && log.trim().isNotEmpty) 'log': log,
                'pow': {'challenge': challenge, 'nonce': nonce},
              }),
            )
            .timeout(_timeout);
        if (res.statusCode == 201) {
          final id = _json(res)['id'];
          if (id is int) return id;
          throw const FeedbackException(_failed);
        }
        final error = _json(res)['error'];
        if (attempt == 0 && error is String && error.startsWith('pow_')) {
          continue;
        }
        throw _error(res);
      }
      throw const FeedbackException(_failed);
    } on FeedbackException {
      rethrow;
    } on Object {
      // Сеть, тайм-аут, сертификат — человеку всё равно, почему.
      throw const FeedbackException(_failed);
    }
  }

  void close() => _http.close();

  static Map<String, dynamic> _json(http.Response r) {
    try {
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } on Object {
      return const {};
    }
  }

  static FeedbackException _error(http.Response r) {
    final body = _json(r);
    final retry = body['retryAfter'];
    final message = body['message'];
    return FeedbackException(
      r.statusCode < 500 && message is String ? message : _failed,
      retryAfter: retry is int ? Duration(seconds: retry) : null,
    );
  }
}
