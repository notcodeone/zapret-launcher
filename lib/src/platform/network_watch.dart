import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Сетевые адреса компьютера — меняются, когда включается или отключается VPN,
/// меняется Wi-Fi или кабель. Сравнить их дёшево и без запросов в интернет.
///
/// Только IPv4: временные IPv6-адреса система меняет сама каждые несколько
/// часов. Без адаптеров виртуальных машин (WSL, Hyper-V): их запуск — не смена сети.
/// Адаптеры VPN (Wintun, WireGuard, TAP) остаются. Как в ClaudeLauncher.
Future<String> networkFingerprint() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    includeLinkLocal: false,
    type: InternetAddressType.IPv4,
  );
  return ([
    for (final interface in interfaces)
      if (!isVirtualMachineAdapter(interface.name))
        for (final address in interface.addresses)
          '${interface.name}=${address.address}',
  ]..sort()).join(',');
}

/// Адаптер для виртуальных машин, а не выход в сеть.
bool isVirtualMachineAdapter(String name) => RegExp(
  r'^(bridge\d+|vmenet\d+|vEthernet \((Default Switch|WSL.*|.*cowork.*)\))$',
  caseSensitive: false,
).hasMatch(name);

/// Мгновенное событие Windows о смене сети: на любом адаптере (Wi-Fi, кабель, VPN)
/// появился или пропал IP-адрес (`NotifyUnicastIpAddressChange`) — не ждём опроса.
///
/// Колбэк система вызывает из своего потока, поэтому он — [NativeCallable.listener]:
/// событие приходит в Dart асинхронно, данные строки не читаем.
class WindowsNetworkWatch {
  NativeCallable<_ChangeCallback>? _callback;
  Pointer<Pointer<Void>>? _handle;

  /// Начинает следить; [onChange] — при каждой смене адресов.
  void start(void Function() onChange) {
    if (_handle != null) return;
    try {
      final callback = NativeCallable<_ChangeCallback>.listener(
        (Pointer<Void> context, Pointer<Void> row, int type) => onChange(),
      );
      final handle = calloc<Pointer<Void>>();
      final result = _notifyUnicastIpAddressChange(
        0, // AF_UNSPEC
        callback.nativeFunction,
        nullptr,
        0, // Без первого «уведомления» обо всех адресах сразу.
        handle,
      );
      if (result != 0) {
        callback.close();
        calloc.free(handle);
        debugPrint('События сети недоступны (код $result)');
        return;
      }
      _callback = callback;
      _handle = handle;
    } on Object catch (error) {
      debugPrint('События сети недоступны: $error');
    }
  }

  void stop() {
    final handle = _handle;
    if (handle != null) {
      _cancelMibChangeNotify2(handle.value);
      calloc.free(handle);
    }
    _callback?.close();
    _handle = null;
    _callback = null;
  }
}

typedef _ChangeCallback = Void Function(
  Pointer<Void> context,
  Pointer<Void> row,
  Int32 type,
);

final _iphlpapi = DynamicLibrary.open('iphlpapi.dll');

final _notifyUnicastIpAddressChange = _iphlpapi
    .lookupFunction<
      Uint32 Function(
        Uint16 family,
        Pointer<NativeFunction<_ChangeCallback>> callback,
        Pointer<Void> context,
        Uint8 initialNotification,
        Pointer<Pointer<Void>> handle,
      ),
      int Function(
        int family,
        Pointer<NativeFunction<_ChangeCallback>> callback,
        Pointer<Void> context,
        int initialNotification,
        Pointer<Pointer<Void>> handle,
      )
    >('NotifyUnicastIpAddressChange');

final _cancelMibChangeNotify2 = _iphlpapi
    .lookupFunction<
      Uint32 Function(Pointer<Void> handle),
      int Function(Pointer<Void> handle)
    >('CancelMibChangeNotify2');
