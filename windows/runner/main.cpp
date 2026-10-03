#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Лаунчер живёт в трее, поэтому запущен должен быть один. Второй запуск
// показывает окно первого и выходит. Возвращает false, если надо выйти.
// В отладочной сборке не мешаем: `flutter run` при открытом лаунчере.
bool AcquireSingleInstance(bool relaunch, HANDLE* mutex) {
#ifdef NDEBUG
  // Владеем мьютексом до выхода: перезапуск ждёт именно его освобождения.
  *mutex = ::CreateMutexW(nullptr, TRUE, L"Local\\ZapretLauncher.SingleInstance");
  const DWORD error = ::GetLastError();
  if (*mutex && error != ERROR_ALREADY_EXISTS) {
    return true;
  }
  if (relaunch && *mutex) {
    // Перезапуск от администратора: прежний экземпляр вот-вот закроется — ждём его.
    const DWORD wait = ::WaitForSingleObject(*mutex, 10000);
    if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) return true;
  }
  // Уже запущен (в том числе от администратора — тогда мьютекс недоступен).
  HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"ZapretLauncher");
  if (existing) {
    ::AllowSetForegroundWindow(ASFW_ANY);
    ::PostMessageW(existing, ::RegisterWindowMessageW(kShowWindowMessage), 0, 0);
  }
  return false;
#else
  (void)relaunch;
  *mutex = nullptr;
  return true;
#endif
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool relaunch =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--relaunch") != command_line_arguments.end();
  HANDLE instance_mutex = nullptr;
  if (!AcquireSingleInstance(relaunch, &instance_mutex)) {
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // До передачи аргументов в Dart — после std::move вектор пуст.
  const bool minimized =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--minimized") != command_line_arguments.end();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, minimized);
  // Начальный размер окна — 560 × 680, по центру рабочей области. Высота — чтобы главная
  // со строкой предупреждения (например, о правах) помещалась целиком, не уходя под
  // затемнение подвала.
  const int width = 560;
  const int height = 680;
  RECT work{};
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  const double scale = ::GetDpiForSystem() / 96.0;
  Win32Window::Point origin(
      static_cast<unsigned int>((work.left + work.right) / 2.0 / scale - width / 2.0),
      static_cast<unsigned int>((work.top + work.bottom) / 2.0 / scale - height / 2.0));
  Win32Window::Size size(width, height);
  if (!window.Create(L"ZapretLauncher", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex) ::CloseHandle(instance_mutex);
  return EXIT_SUCCESS;
}
