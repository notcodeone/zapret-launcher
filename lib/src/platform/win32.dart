// Минимальные привязки к Win32 через dart:ffi: процессы, службы, реестр,
// права администратора и диалог выбора папки. Только то, что нужно лаунчеру.
// Имена структур и констант — как в Windows SDK, чтобы их было легко найти в документации.
// ignore_for_file: non_constant_identifier_names, constant_identifier_names, camel_case_types

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _advapi32 = DynamicLibrary.open('advapi32.dll');
final _shell32 = DynamicLibrary.open('shell32.dll');
final _user32 = DynamicLibrary.open('user32.dll');
final _comdlg32 = DynamicLibrary.open('comdlg32.dll');
final _ole32 = DynamicLibrary.open('ole32.dll');

const _INVALID_HANDLE_VALUE = -1;
const _TH32CS_SNAPPROCESS = 0x2;
const _PROCESS_TERMINATE = 0x0001;
const _PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
const _SYNCHRONIZE = 0x00100000;
const _TOKEN_QUERY = 0x0008;
const _TokenElevation = 20;

const _SC_MANAGER_CONNECT = 0x0001;
const _SC_MANAGER_CREATE_SERVICE = 0x0002;
const _SERVICE_QUERY_STATUS = 0x0004;
const _SERVICE_START = 0x0010;
const _SERVICE_STOP = 0x0020;
const _DELETE = 0x00010000;
const _SERVICE_ALL_ACCESS = 0xF01FF;
const _SERVICE_WIN32_OWN_PROCESS = 0x10;
const _SERVICE_AUTO_START = 0x2;
const _SERVICE_ERROR_NORMAL = 0x1;
const _SERVICE_CONTROL_STOP = 0x1;
const _SERVICE_CONFIG_DESCRIPTION = 1;
const _SERVICE_CONFIG_FAILURE_ACTIONS = 2;
const _SC_ACTION_RESTART = 1;

const _HKEY_LOCAL_MACHINE = 0x80000002;
const _HKEY_CURRENT_USER = 0x80000001;
const _KEY_READ = 0x20019;
const _REG_SZ = 1;
const _RRF_RT_REG_DWORD = 0x10;
const _SERVICE_WIN32 = 0x30;
const _SERVICE_ACTIVE = 0x1;
const _SERVICE_STATE_ALL = 0x3;
const _SC_MANAGER_ENUMERATE_SERVICE = 0x0004;
const _SC_ENUM_PROCESS_INFO = 0;
const _ERROR_MORE_DATA = 234;
// RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND: строки читаем как есть.
const _RRF_STRING = 0x2 | 0x4 | 0x10000000;

const ERROR_ACCESS_DENIED = 5;
const ERROR_SERVICE_ALREADY_RUNNING = 1056;
const ERROR_SERVICE_DOES_NOT_EXIST = 1060;
const ERROR_SERVICE_NOT_ACTIVE = 1062;
const ERROR_SERVICE_MARKED_FOR_DELETE = 1072;
const ERROR_SERVICE_EXISTS = 1073;

// ── Структуры ───────────────────────────────────────────────────────────────

final class PROCESSENTRY32W extends Struct {
  @Uint32()
  external int dwSize;
  @Uint32()
  external int cntUsage;
  @Uint32()
  external int th32ProcessID;
  @UintPtr()
  external int th32DefaultHeapID;
  @Uint32()
  external int th32ModuleID;
  @Uint32()
  external int cntThreads;
  @Uint32()
  external int th32ParentProcessID;
  @Int32()
  external int pcPriClassBase;
  @Uint32()
  external int dwFlags;
  @Array(260)
  external Array<Uint16> szExeFile;
}

final class SERVICE_STATUS extends Struct {
  @Uint32()
  external int dwServiceType;
  @Uint32()
  external int dwCurrentState;
  @Uint32()
  external int dwControlsAccepted;
  @Uint32()
  external int dwWin32ExitCode;
  @Uint32()
  external int dwServiceSpecificExitCode;
  @Uint32()
  external int dwCheckPoint;
  @Uint32()
  external int dwWaitHint;
}

final class SERVICE_DESCRIPTIONW extends Struct {
  external Pointer<Utf16> lpDescription;
}

final class SC_ACTION extends Struct {
  @Int32()
  external int Type;
  @Uint32()
  external int Delay;
}

final class SERVICE_FAILURE_ACTIONSW extends Struct {
  @Uint32()
  external int dwResetPeriod;
  external Pointer<Utf16> lpRebootMsg;
  external Pointer<Utf16> lpCommand;
  @Uint32()
  external int cActions;
  external Pointer<SC_ACTION> lpsaActions;
}

final class ENUM_SERVICE_STATUS_PROCESSW extends Struct {
  external Pointer<Utf16> lpServiceName;
  external Pointer<Utf16> lpDisplayName;
  @Uint32()
  external int dwServiceType;
  @Uint32()
  external int dwCurrentState;
  @Uint32()
  external int dwControlsAccepted;
  @Uint32()
  external int dwWin32ExitCode;
  @Uint32()
  external int dwServiceSpecificExitCode;
  @Uint32()
  external int dwCheckPoint;
  @Uint32()
  external int dwWaitHint;
  @Uint32()
  external int dwProcessId;
  @Uint32()
  external int dwServiceFlags;
}

final class OPENFILENAMEW extends Struct {
  @Uint32()
  external int lStructSize;
  @IntPtr()
  external int hwndOwner;
  @IntPtr()
  external int hInstance;
  external Pointer<Utf16> lpstrFilter;
  external Pointer<Utf16> lpstrCustomFilter;
  @Uint32()
  external int nMaxCustFilter;
  @Uint32()
  external int nFilterIndex;
  external Pointer<Utf16> lpstrFile;
  @Uint32()
  external int nMaxFile;
  external Pointer<Utf16> lpstrFileTitle;
  @Uint32()
  external int nMaxFileTitle;
  external Pointer<Utf16> lpstrInitialDir;
  external Pointer<Utf16> lpstrTitle;
  @Uint32()
  external int Flags;
  @Uint16()
  external int nFileOffset;
  @Uint16()
  external int nFileExtension;
  external Pointer<Utf16> lpstrDefExt;
  @IntPtr()
  external int lCustData;
  external Pointer<Void> lpfnHook;
  external Pointer<Utf16> lpTemplateName;
  external Pointer<Void> pvReserved;
  @Uint32()
  external int dwReserved;
  @Uint32()
  external int FlagsEx;
}

final class BROWSEINFOW extends Struct {
  @IntPtr()
  external int hwndOwner;
  external Pointer<Void> pidlRoot;
  external Pointer<Utf16> pszDisplayName;
  external Pointer<Utf16> lpszTitle;
  @Uint32()
  external int ulFlags;
  external Pointer<Void> lpfn;
  @IntPtr()
  external int lParam;
  @Int32()
  external int iImage;
}

// ── Функции ─────────────────────────────────────────────────────────────────

final _GetLastError =
    _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError', isLeaf: true);
final _CloseHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle', isLeaf: true);
final _CreateToolhelp32Snapshot = _kernel32.lookupFunction<IntPtr Function(Uint32, Uint32),
    int Function(int, int)>('CreateToolhelp32Snapshot', isLeaf: true);
final _Process32FirstW = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Pointer<PROCESSENTRY32W>),
    int Function(int, Pointer<PROCESSENTRY32W>)>('Process32FirstW', isLeaf: true);
final _Process32NextW = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Pointer<PROCESSENTRY32W>),
    int Function(int, Pointer<PROCESSENTRY32W>)>('Process32NextW', isLeaf: true);
final _OpenProcess = _kernel32.lookupFunction<IntPtr Function(Uint32, Int32, Uint32),
    int Function(int, int, int)>('OpenProcess', isLeaf: true);
final _TerminateProcess = _kernel32.lookupFunction<Int32 Function(IntPtr, Uint32),
    int Function(int, int)>('TerminateProcess', isLeaf: true);
final _WaitForSingleObject = _kernel32.lookupFunction<Uint32 Function(IntPtr, Uint32),
    int Function(int, int)>('WaitForSingleObject');
final _QueryFullProcessImageNameW = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>),
    int Function(int, int, Pointer<Utf16>, Pointer<Uint32>)>('QueryFullProcessImageNameW',
    isLeaf: true);
final _GetCurrentProcess = _kernel32
    .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess', isLeaf: true);

final _OpenProcessToken = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
    int Function(int, int, Pointer<IntPtr>)>('OpenProcessToken', isLeaf: true);
final _GetTokenInformation = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
    int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)>('GetTokenInformation',
    isLeaf: true);

final _OpenSCManagerW = _advapi32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
    int Function(Pointer<Utf16>, Pointer<Utf16>, int)>('OpenSCManagerW', isLeaf: true);
final _OpenServiceW = _advapi32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<Utf16>, Uint32),
    int Function(int, Pointer<Utf16>, int)>('OpenServiceW', isLeaf: true);
final _CloseServiceHandle = _advapi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseServiceHandle', isLeaf: true);
final _QueryServiceStatus = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<SERVICE_STATUS>),
    int Function(int, Pointer<SERVICE_STATUS>)>('QueryServiceStatus', isLeaf: true);
final _CreateServiceW = _advapi32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Uint32, Uint32, Uint32,
        Pointer<Utf16>, Pointer<Utf16>, Pointer<Uint32>, Pointer<Utf16>, Pointer<Utf16>,
        Pointer<Utf16>),
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, int, int, int, Pointer<Utf16>,
        Pointer<Utf16>, Pointer<Uint32>, Pointer<Utf16>, Pointer<Utf16>,
        Pointer<Utf16>)>('CreateServiceW', isLeaf: true);
final _ChangeServiceConfig2W = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<Void>),
    int Function(int, int, Pointer<Void>)>('ChangeServiceConfig2W', isLeaf: true);
final _StartServiceW = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<Pointer<Utf16>>),
    int Function(int, int, Pointer<Pointer<Utf16>>)>('StartServiceW', isLeaf: true);
final _ControlService = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<SERVICE_STATUS>),
    int Function(int, int, Pointer<SERVICE_STATUS>)>('ControlService', isLeaf: true);
final _DeleteService = _advapi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteService', isLeaf: true);

final _RegSetKeyValueW = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Void>, Uint32),
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Void>, int)>(
    'RegSetKeyValueW',
    isLeaf: true);
final _RegGetValueW = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Uint32>,
        Pointer<Void>, Pointer<Uint32>),
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint32>, Pointer<Void>,
        Pointer<Uint32>)>('RegGetValueW', isLeaf: true);

final _RegOpenKeyExW = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
    int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>('RegOpenKeyExW', isLeaf: true);
final _RegEnumKeyExW = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
        Pointer<Utf16>, Pointer<Uint32>, Pointer<Void>),
    int Function(int, int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Utf16>,
        Pointer<Uint32>, Pointer<Void>)>('RegEnumKeyExW', isLeaf: true);
final _RegCloseKey = _advapi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey', isLeaf: true);
final _EnumServicesStatusExW = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Int32, Uint32, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint32>,
        Pointer<Uint32>, Pointer<Uint32>, Pointer<Utf16>),
    int Function(int, int, int, int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint32>,
        Pointer<Uint32>, Pointer<Utf16>)>('EnumServicesStatusExW', isLeaf: true);

final _ShellExecuteW = _shell32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
        Int32),
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
        int)>('ShellExecuteW');
final _SHBrowseForFolderW = _shell32.lookupFunction<
    Pointer<Void> Function(Pointer<BROWSEINFOW>),
    Pointer<Void> Function(Pointer<BROWSEINFOW>)>('SHBrowseForFolderW');
final _SHGetPathFromIDListW = _shell32.lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<Utf16>),
    int Function(Pointer<Void>, Pointer<Utf16>)>('SHGetPathFromIDListW');
final _CoTaskMemFree = _ole32
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CoTaskMemFree');
final _CoInitializeEx = _ole32.lookupFunction<Int32 Function(Pointer<Void>, Uint32),
    int Function(Pointer<Void>, int)>('CoInitializeEx');
final _GetOpenFileNameW = _comdlg32.lookupFunction<Int32 Function(Pointer<OPENFILENAMEW>),
    int Function(Pointer<OPENFILENAMEW>)>('GetOpenFileNameW');
final _GetSaveFileNameW = _comdlg32.lookupFunction<Int32 Function(Pointer<OPENFILENAMEW>),
    int Function(Pointer<OPENFILENAMEW>)>('GetSaveFileNameW');
final _FindWindowW = _user32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
    int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');

// ── Ошибки ──────────────────────────────────────────────────────────────────

class Win32Exception implements Exception {
  Win32Exception(this.operation, this.code);

  final String operation;
  final int code;

  bool get accessDenied => code == ERROR_ACCESS_DENIED;

  @override
  String toString() => '$operation: ошибка Windows $code';
}

// ── Процессы ────────────────────────────────────────────────────────────────

class ProcessEntry {
  const ProcessEntry(this.pid, this.name);

  final int pid;
  final String name;
}

/// Список процессов с заданным именем exe (без учёта регистра).
List<ProcessEntry> findProcesses(String exeName) {
  final snapshot = _CreateToolhelp32Snapshot(_TH32CS_SNAPPROCESS, 0);
  if (snapshot == _INVALID_HANDLE_VALUE) return const [];
  final entry = calloc<PROCESSENTRY32W>();
  final result = <ProcessEntry>[];
  final target = exeName.toLowerCase();
  try {
    entry.ref.dwSize = sizeOf<PROCESSENTRY32W>();
    var ok = _Process32FirstW(snapshot, entry);
    while (ok != 0) {
      final chars = <int>[];
      for (var i = 0; i < 260; i++) {
        final c = entry.ref.szExeFile[i];
        if (c == 0) break;
        chars.add(c);
      }
      final name = String.fromCharCodes(chars);
      if (name.toLowerCase() == target) {
        result.add(ProcessEntry(entry.ref.th32ProcessID, name));
      }
      ok = _Process32NextW(snapshot, entry);
    }
  } finally {
    calloc.free(entry);
    _CloseHandle(snapshot);
  }
  return result;
}

/// Полный путь к exe процесса или null, если нет доступа.
String? processImagePath(int pid) {
  final h = _OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
  if (h == 0) return null;
  final buf = calloc<Uint16>(1024).cast<Utf16>();
  final size = calloc<Uint32>()..value = 1024;
  try {
    if (_QueryFullProcessImageNameW(h, 0, buf, size) == 0) return null;
    return buf.toDartString(length: size.value);
  } finally {
    calloc.free(buf);
    calloc.free(size);
    _CloseHandle(h);
  }
}

/// Завершает процесс и ждёт до [timeoutMs] мс, пока он закроется.
void terminateProcess(int pid, {int timeoutMs = 3000}) {
  final h = _OpenProcess(_PROCESS_TERMINATE | _SYNCHRONIZE, 0, pid);
  if (h == 0) {
    final code = _GetLastError();
    throw Win32Exception('Не удалось открыть процесс $pid', code);
  }
  try {
    if (_TerminateProcess(h, 1) == 0) {
      final code = _GetLastError();
      throw Win32Exception('Не удалось завершить процесс $pid', code);
    }
    _WaitForSingleObject(h, timeoutMs);
  } finally {
    _CloseHandle(h);
  }
}

// ── Права ───────────────────────────────────────────────────────────────────

/// Запущен ли процесс с повышенными правами (от имени администратора).
bool isElevated() {
  final token = calloc<IntPtr>();
  final elevation = calloc<Uint32>();
  final returned = calloc<Uint32>();
  try {
    if (_OpenProcessToken(_GetCurrentProcess(), _TOKEN_QUERY, token) == 0) return false;
    final ok = _GetTokenInformation(
        token.value, _TokenElevation, elevation.cast(), sizeOf<Uint32>(), returned);
    _CloseHandle(token.value);
    return ok != 0 && elevation.value != 0;
  } finally {
    calloc.free(token);
    calloc.free(elevation);
    calloc.free(returned);
  }
}

/// ShellExecute: открыть ссылку, папку или запустить программу.
/// Возвращает false, если Windows отказала (в том числе отмена UAC).
bool shellExecute(String file, {String verb = 'open', String? parameters, String? directory}) {
  return using((arena) {
    final r = _ShellExecuteW(
      0,
      verb.toNativeUtf16(allocator: arena),
      file.toNativeUtf16(allocator: arena),
      parameters?.toNativeUtf16(allocator: arena) ?? nullptr,
      directory?.toNativeUtf16(allocator: arena) ?? nullptr,
      1, // SW_SHOWNORMAL
    );
    return r > 32;
  });
}

/// Перезапускает текущую программу от имени администратора.
/// true — новый процесс запущен (текущий можно закрывать).
bool relaunchElevated() => shellExecute(Platform.resolvedExecutable,
    verb: 'runas', parameters: '--relaunch', directory: Directory.current.path);

// ── Службы ──────────────────────────────────────────────────────────────────

enum ServiceState { stopped, startPending, stopPending, running, continuePending, pausePending, paused }

ServiceState _stateFromCode(int code) => switch (code) {
      1 => ServiceState.stopped,
      2 => ServiceState.startPending,
      3 => ServiceState.stopPending,
      4 => ServiceState.running,
      5 => ServiceState.continuePending,
      6 => ServiceState.pausePending,
      7 => ServiceState.paused,
      _ => ServiceState.stopped,
    };

class ServiceInfo {
  const ServiceInfo({required this.state, this.binaryPath});

  final ServiceState state;
  final String? binaryPath;

  bool get running =>
      state == ServiceState.running || state == ServiceState.startPending;
}

T _withScm<T>(int access, T Function(int scm) body) {
  final scm = _OpenSCManagerW(nullptr, nullptr, access);
  if (scm == 0) {
    final code = _GetLastError();
    throw Win32Exception('Нет доступа к диспетчеру служб', code);
  }
  try {
    return body(scm);
  } finally {
    _CloseServiceHandle(scm);
  }
}

/// Состояние службы или null, если её нет.
ServiceInfo? queryService(String name) {
  return using((arena) {
    final scm = _OpenSCManagerW(nullptr, nullptr, _SC_MANAGER_CONNECT);
    if (scm == 0) return null;
    try {
      final svc = _OpenServiceW(scm, name.toNativeUtf16(allocator: arena), _SERVICE_QUERY_STATUS);
      if (svc == 0) return null;
      try {
        final status = arena<SERVICE_STATUS>();
        if (_QueryServiceStatus(svc, status) == 0) return null;
        // QueryServiceConfig не отдаёт командную строку длиннее 8 КБ (ошибка 1734),
        // а у zapret она как раз такая — поэтому читаем ImagePath из реестра.
        final binPath =
            readRegistryString('SYSTEM\\CurrentControlSet\\Services\\$name', 'ImagePath');
        return ServiceInfo(state: _stateFromCode(status.ref.dwCurrentState), binaryPath: binPath);
      } finally {
        _CloseServiceHandle(svc);
      }
    } finally {
      _CloseServiceHandle(scm);
    }
  });
}

class ServiceEntry {
  const ServiceEntry(this.name, this.displayName, this.state);

  final String name;
  final String displayName;
  final ServiceState state;
}

/// Службы Windows (не драйверы). [activeOnly] — только запущенные, как `sc query`.
List<ServiceEntry> enumServices({bool activeOnly = true}) {
  return using((arena) {
    final scm = _OpenSCManagerW(nullptr, nullptr, _SC_MANAGER_ENUMERATE_SERVICE);
    if (scm == 0) return const <ServiceEntry>[];
    const bufSize = 64 * 1024;
    final buf = arena<Uint8>(bufSize);
    final needed = arena<Uint32>();
    final returned = arena<Uint32>();
    final resume = arena<Uint32>()..value = 0;
    final out = <ServiceEntry>[];
    try {
      while (true) {
        final ok = _EnumServicesStatusExW(scm, _SC_ENUM_PROCESS_INFO, _SERVICE_WIN32,
            activeOnly ? _SERVICE_ACTIVE : _SERVICE_STATE_ALL, buf, bufSize, needed, returned,
            resume, nullptr);
        final more = ok == 0 && _GetLastError() == _ERROR_MORE_DATA;
        if (ok == 0 && !more) break;
        final items = buf.cast<ENUM_SERVICE_STATUS_PROCESSW>();
        for (var i = 0; i < returned.value; i++) {
          final e = items[i];
          out.add(ServiceEntry(
            e.lpServiceName.toDartString(),
            e.lpDisplayName == nullptr ? '' : e.lpDisplayName.toDartString(),
            _stateFromCode(e.dwCurrentState),
          ));
        }
        if (!more) break;
      }
    } finally {
      _CloseServiceHandle(scm);
    }
    return out;
  });
}

/// Создаёт службу с автозапуском. Если служба уже есть — ошибка ERROR_SERVICE_EXISTS.
void createService({
  required String name,
  required String displayName,
  required String binaryPath,
  String? description,
  bool restartOnFailure = false,
}) {
  using((arena) {
    _withScm(_SC_MANAGER_CONNECT | _SC_MANAGER_CREATE_SERVICE, (scm) {
      final svc = _CreateServiceW(
        scm,
        name.toNativeUtf16(allocator: arena),
        displayName.toNativeUtf16(allocator: arena),
        _SERVICE_ALL_ACCESS,
        _SERVICE_WIN32_OWN_PROCESS,
        _SERVICE_AUTO_START,
        _SERVICE_ERROR_NORMAL,
        binaryPath.toNativeUtf16(allocator: arena),
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
      );
      if (svc == 0) {
        final code = _GetLastError();
        throw Win32Exception('Не удалось создать службу $name', code);
      }
      if (description != null) {
        final d = arena<SERVICE_DESCRIPTIONW>();
        d.ref.lpDescription = description.toNativeUtf16(allocator: arena);
        _ChangeServiceConfig2W(svc, _SERVICE_CONFIG_DESCRIPTION, d.cast());
      }
      if (restartOnFailure) {
        // Упал сам — Windows перезапустит через 5, 10 и 30 секунд; счётчик сбрасывается за сутки.
        final actions = arena<SC_ACTION>(3);
        for (final (i, delay) in const [(0, 5000), (1, 10000), (2, 30000)]) {
          actions[i]
            ..Type = _SC_ACTION_RESTART
            ..Delay = delay;
        }
        final fa = arena<SERVICE_FAILURE_ACTIONSW>();
        fa.ref
          ..dwResetPeriod = 24 * 60 * 60
          ..lpRebootMsg = nullptr
          ..lpCommand = nullptr
          ..cActions = 3
          ..lpsaActions = actions;
        _ChangeServiceConfig2W(svc, _SERVICE_CONFIG_FAILURE_ACTIONS, fa.cast());
      }
      _CloseServiceHandle(svc);
    });
  });
}

void _withService(String name, int access, String what, void Function(int svc) body) {
  using((arena) {
    _withScm(_SC_MANAGER_CONNECT, (scm) {
      final svc = _OpenServiceW(scm, name.toNativeUtf16(allocator: arena), access);
      if (svc == 0) {
        final code = _GetLastError();
        throw Win32Exception('$what: служба $name', code);
      }
      try {
        body(svc);
      } finally {
        _CloseServiceHandle(svc);
      }
    });
  });
}

void startService(String name) {
  _withService(name, _SERVICE_START, 'Не удалось запустить', (svc) {
    if (_StartServiceW(svc, 0, nullptr) == 0) {
      final code = _GetLastError();
      if (code != ERROR_SERVICE_ALREADY_RUNNING) {
        throw Win32Exception('Не удалось запустить службу $name', code);
      }
    }
  });
}

/// Отправляет команду остановки. Не ждёт — ожидание делает вызывающий код.
void stopService(String name) {
  _withService(name, _SERVICE_STOP | _SERVICE_QUERY_STATUS, 'Не удалось остановить', (svc) {
    final status = calloc<SERVICE_STATUS>();
    try {
      if (_ControlService(svc, _SERVICE_CONTROL_STOP, status) == 0) {
        final code = _GetLastError();
        if (code != ERROR_SERVICE_NOT_ACTIVE) {
          throw Win32Exception('Не удалось остановить службу $name', code);
        }
      }
    } finally {
      calloc.free(status);
    }
  });
}

void deleteService(String name) {
  _withService(name, _DELETE, 'Не удалось удалить', (svc) {
    if (_DeleteService(svc) == 0) {
      final code = _GetLastError();
      if (code != ERROR_SERVICE_MARKED_FOR_DELETE) {
        throw Win32Exception('Не удалось удалить службу $name', code);
      }
    }
  });
}

// ── Реестр ──────────────────────────────────────────────────────────────────

/// Строка из HKLM (или HKCU, если [currentUser]). null — значения нет.
String? readRegistryString(String subKey, String valueName, {bool currentUser = false}) {
  final root = currentUser ? _HKEY_CURRENT_USER : _HKEY_LOCAL_MACHINE;
  return using((arena) {
    final size = arena<Uint32>()..value = 0;
    final key = subKey.toNativeUtf16(allocator: arena);
    final value = valueName.toNativeUtf16(allocator: arena);
    if (_RegGetValueW(root, key, value, _RRF_STRING, nullptr, nullptr, size) != 0 ||
        size.value == 0) {
      return null;
    }
    final buf = arena<Uint8>(size.value);
    if (_RegGetValueW(root, key, value, _RRF_STRING, nullptr, buf.cast(), size) != 0) {
      return null;
    }
    return buf.cast<Utf16>().toDartString();
  });
}

/// Число (REG_DWORD) из HKLM или HKCU. null — значения нет.
int? readRegistryDword(String subKey, String valueName, {bool currentUser = false}) {
  final root = currentUser ? _HKEY_CURRENT_USER : _HKEY_LOCAL_MACHINE;
  return using((arena) {
    final data = arena<Uint32>();
    final size = arena<Uint32>()..value = sizeOf<Uint32>();
    final r = _RegGetValueW(root, subKey.toNativeUtf16(allocator: arena),
        valueName.toNativeUtf16(allocator: arena), _RRF_RT_REG_DWORD, nullptr, data.cast(), size);
    return r == 0 ? data.value : null;
  });
}

/// Имена подразделов ключа HKLM. Пустой список — ключа нет.
List<String> registrySubkeys(String subKey) {
  return using((arena) {
    final hkey = arena<IntPtr>();
    if (_RegOpenKeyExW(_HKEY_LOCAL_MACHINE, subKey.toNativeUtf16(allocator: arena), 0,
            _KEY_READ, hkey) !=
        0) {
      return const <String>[];
    }
    final names = <String>[];
    final name = arena<Uint16>(256).cast<Utf16>();
    final len = arena<Uint32>();
    try {
      for (var i = 0;; i++) {
        len.value = 256;
        final r = _RegEnumKeyExW(hkey.value, i, name, len, nullptr, nullptr, nullptr, nullptr);
        if (r != 0) break;
        names.add(name.toDartString(length: len.value));
      }
    } finally {
      _RegCloseKey(hkey.value);
    }
    return names;
  });
}

void writeRegistryString(String subKey, String valueName, String data) {
  using((arena) {
    final native = data.toNativeUtf16(allocator: arena);
    final r = _RegSetKeyValueW(
      _HKEY_LOCAL_MACHINE,
      subKey.toNativeUtf16(allocator: arena),
      valueName.toNativeUtf16(allocator: arena),
      _REG_SZ,
      native.cast(),
      (data.length + 1) * 2,
    );
    if (r != 0) throw Win32Exception('Не удалось записать в реестр $subKey', r);
  });
}

// ── Выбор папки ─────────────────────────────────────────────────────────────

int _mainWindow(Arena arena) => _FindWindowW(
    'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: arena),
    'ZapretLauncher'.toNativeUtf16(allocator: arena));

const _textFilter = 'Текстовые файлы (*.txt)\u0000*.txt\u0000Все файлы\u0000*.*\u0000';

/// Диалог «Открыть». null — пользователь отменил.
String? pickOpenFile({required String title}) {
  return using((arena) {
    const max = 4096;
    final file = arena<Uint16>(max).cast<Utf16>();
    final ofn = arena<OPENFILENAMEW>();
    ofn.ref
      ..lStructSize = sizeOf<OPENFILENAMEW>()
      ..hwndOwner = _mainWindow(arena)
      ..lpstrFilter = _textFilter.toNativeUtf16(allocator: arena)
      ..nFilterIndex = 1
      ..lpstrFile = file
      ..nMaxFile = max
      ..lpstrTitle = title.toNativeUtf16(allocator: arena)
      // OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_EXPLORER | OFN_NOCHANGEDIR
      ..Flags = 0x1000 | 0x800 | 0x80000 | 0x8;
    if (_GetOpenFileNameW(ofn) == 0) return null;
    return file.toDartString();
  });
}

/// Диалог «Сохранить как». null — пользователь отменил.
String? pickSaveFile({required String title, required String fileName}) {
  return using((arena) {
    const max = 4096;
    final file = arena<Uint16>(max);
    final units = fileName.codeUnits.take(max - 1).toList();
    for (var i = 0; i < units.length; i++) {
      file[i] = units[i];
    }
    final ofn = arena<OPENFILENAMEW>();
    ofn.ref
      ..lStructSize = sizeOf<OPENFILENAMEW>()
      ..hwndOwner = _mainWindow(arena)
      ..lpstrFilter = _textFilter.toNativeUtf16(allocator: arena)
      ..nFilterIndex = 1
      ..lpstrFile = file.cast()
      ..nMaxFile = max
      ..lpstrTitle = title.toNativeUtf16(allocator: arena)
      ..lpstrDefExt = 'txt'.toNativeUtf16(allocator: arena)
      // OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_EXPLORER | OFN_NOCHANGEDIR
      ..Flags = 0x2 | 0x800 | 0x80000 | 0x8;
    if (_GetSaveFileNameW(ofn) == 0) return null;
    return file.cast<Utf16>().toDartString();
  });
}

/// Стандартный диалог выбора папки. null — пользователь отменил.
String? pickFolder({required String title}) {
  return using((arena) {
    _CoInitializeEx(nullptr, 0x2); // COINIT_APARTMENTTHREADED; повторный вызов безопасен.
    final info = arena<BROWSEINFOW>();
    final display = arena<Uint16>(260).cast<Utf16>();
    info.ref
      ..hwndOwner = _FindWindowW('FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: arena),
          'ZapretLauncher'.toNativeUtf16(allocator: arena))
      ..pidlRoot = nullptr
      ..pszDisplayName = display
      ..lpszTitle = title.toNativeUtf16(allocator: arena)
      // BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE
      ..ulFlags = 0x0001 | 0x0040
      ..lpfn = nullptr
      ..lParam = 0;
    final pidl = _SHBrowseForFolderW(info);
    if (pidl == nullptr) return null;
    try {
      final path = arena<Uint16>(1024).cast<Utf16>();
      if (_SHGetPathFromIDListW(pidl, path) == 0) return null;
      return path.toDartString();
    } finally {
      _CoTaskMemFree(pidl);
    }
  });
}
