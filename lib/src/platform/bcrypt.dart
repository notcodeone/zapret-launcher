// AES через Windows CNG (bcrypt.dll): аппаратный AES вместо таблиц на Dart.
// В CNG нет режима CTR, поэтому гамма — это номера блоков, зашифрованные в ECB
// одним вызовом на весь кусок данных.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../telegram/aes_ctr.dart';

final _bcrypt = DynamicLibrary.open('bcrypt.dll');

final _BCryptOpenAlgorithmProvider = _bcrypt
    .lookupFunction<
      Int32 Function(Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>, Uint32),
      int Function(Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>, int)
    >('BCryptOpenAlgorithmProvider');
final _BCryptSetProperty = _bcrypt
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint8>, Uint32, Uint32),
      int Function(int, Pointer<Utf16>, Pointer<Uint8>, int, int)
    >('BCryptSetProperty');
final _BCryptGenerateSymmetricKey = _bcrypt
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<IntPtr>,
        Pointer<Uint8>,
        Uint32,
        Pointer<Uint8>,
        Uint32,
        Uint32,
      ),
      int Function(
        int,
        Pointer<IntPtr>,
        Pointer<Uint8>,
        int,
        Pointer<Uint8>,
        int,
        int,
      )
    >('BCryptGenerateSymmetricKey');
final _BCryptEncrypt = _bcrypt
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<Uint8>,
        Uint32,
        Pointer<Void>,
        Pointer<Uint8>,
        Uint32,
        Pointer<Uint8>,
        Uint32,
        Pointer<Uint32>,
        Uint32,
      ),
      int Function(
        int,
        Pointer<Uint8>,
        int,
        Pointer<Void>,
        Pointer<Uint8>,
        int,
        Pointer<Uint8>,
        int,
        Pointer<Uint32>,
        int,
      )
    >('BCryptEncrypt');
final _BCryptDestroyKey = _bcrypt
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'BCryptDestroyKey',
    );

/// Провайдер AES в режиме ECB — один на изолят; 0 — CNG недоступен.
final int _aesEcb = _openAesEcb();

int _openAesEcb() {
  return using((arena) {
    final handle = arena<IntPtr>();
    if (_BCryptOpenAlgorithmProvider(
          handle,
          'AES'.toNativeUtf16(allocator: arena),
          nullptr,
          0,
        ) !=
        0) {
      return 0;
    }
    const mode = 'ChainingModeECB';
    final value = mode.toNativeUtf16(allocator: arena);
    final ok = _BCryptSetProperty(
      handle.value,
      'ChainingMode'.toNativeUtf16(allocator: arena),
      value.cast(),
      (mode.length + 1) * 2,
      0,
    );
    return ok == 0 ? handle.value : 0;
  });
}

/// AES-CTR через CNG. Буферы в нативной памяти живут, пока шифр не освобождён.
class CngAesCtr implements AesCtr {
  CngAesCtr._(this._key, Uint8List iv) {
    _counter.setAll(0, iv);
  }

  /// null — CNG недоступен (тогда шифруем на Dart).
  static CngAesCtr? tryCreate(Uint8List key, Uint8List iv) {
    final int alg;
    try {
      alg = _aesEcb;
    } on Object {
      return null;
    }
    if (alg == 0) return null;
    final handle = using((arena) {
      final out = arena<IntPtr>();
      final secret = arena<Uint8>(key.length);
      secret.asTypedList(key.length).setAll(0, key);
      final r = _BCryptGenerateSymmetricKey(
        alg,
        out,
        nullptr,
        0,
        secret,
        key.length,
        0,
      );
      return r == 0 ? out.value : 0;
    });
    return handle == 0 ? null : CngAesCtr._(handle, iv);
  }

  int _key;
  final _counter = Uint8List(16);

  /// Остаток гаммы от прошлого куска: [_tail] байт в конце последнего блока.
  final _last = Uint8List(16);
  int _tail = 0;

  Pointer<Uint8> _in = nullptr;
  Pointer<Uint8> _out = nullptr;
  final _written = calloc<Uint32>();
  int _capacity = 0;

  @override
  Uint8List process(Uint8List data) {
    if (_key == 0) throw StateError('Шифр уже освобождён');
    final out = Uint8List(data.length);
    var i = 0;
    // Сначала — гамма, оставшаяся от прошлого вызова.
    while (_tail > 0 && i < data.length) {
      out[i] = data[i] ^ _last[16 - _tail];
      i++;
      _tail--;
    }
    final rest = data.length - i;
    if (rest == 0) return out;

    final blocks = (rest + 15) >> 4;
    final size = blocks << 4;
    _ensure(size);
    final counters = _in.asTypedList(size);
    for (var b = 0; b < size; b += 16) {
      counters.setRange(b, b + 16, _counter);
      incrementCounter(_counter);
    }
    final r = _BCryptEncrypt(
      _key,
      _in,
      size,
      nullptr,
      nullptr,
      0,
      _out,
      size,
      _written,
      0,
    );
    if (r != 0) {
      throw StateError(
        'BCryptEncrypt: 0x${r.toUnsigned(32).toRadixString(16)}',
      );
    }
    final stream = _out.asTypedList(size);
    for (var j = 0; j < rest; j++) {
      out[i + j] = data[i + j] ^ stream[j];
    }
    _tail = size - rest;
    if (_tail > 0) _last.setRange(0, 16, stream, size - 16);
    return out;
  }

  void _ensure(int size) {
    if (size <= _capacity) return;
    if (_capacity > 0) {
      calloc.free(_in);
      calloc.free(_out);
    }
    _capacity = size < 4096 ? 4096 : size;
    _in = calloc<Uint8>(_capacity);
    _out = calloc<Uint8>(_capacity);
  }

  @override
  void dispose() {
    if (_key == 0) return;
    _BCryptDestroyKey(_key);
    _key = 0;
    if (_capacity > 0) {
      calloc.free(_in);
      calloc.free(_out);
      _capacity = 0;
    }
    calloc.free(_written);
  }
}
