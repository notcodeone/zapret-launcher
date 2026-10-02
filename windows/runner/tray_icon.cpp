#include "tray_icon.h"

#include <shellapi.h>

#include <algorithm>

#include "resource.h"

namespace {

constexpr UINT kIconId = 1;

// Значок из пикселей: 32-битный DIB с альфа-каналом и пустая маска.
HICON CreateIconFromRgba(const std::vector<uint8_t>& rgba, int size) {
  if (size <= 0 || rgba.size() < static_cast<size_t>(size) * size * 4) {
    return nullptr;
  }
  BITMAPV5HEADER header = {};
  header.bV5Size = sizeof(header);
  header.bV5Width = size;
  header.bV5Height = -size;  // Строки сверху вниз, как у Flutter.
  header.bV5Planes = 1;
  header.bV5BitCount = 32;
  header.bV5Compression = BI_BITFIELDS;
  header.bV5RedMask = 0x00FF0000;
  header.bV5GreenMask = 0x0000FF00;
  header.bV5BlueMask = 0x000000FF;
  header.bV5AlphaMask = 0xFF000000;

  void* bits = nullptr;
  HDC dc = GetDC(nullptr);
  HBITMAP color = CreateDIBSection(dc, reinterpret_cast<BITMAPINFO*>(&header),
                                   DIB_RGB_COLORS, &bits, nullptr, 0);
  ReleaseDC(nullptr, dc);
  if (!color) return nullptr;

  auto* dst = static_cast<uint8_t*>(bits);
  for (int i = 0; i < size * size; i++) {
    dst[i * 4 + 0] = rgba[i * 4 + 2];  // B
    dst[i * 4 + 1] = rgba[i * 4 + 1];  // G
    dst[i * 4 + 2] = rgba[i * 4 + 0];  // R
    dst[i * 4 + 3] = rgba[i * 4 + 3];  // A
  }

  HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
  ICONINFO info = {};
  info.fIcon = TRUE;
  info.hbmMask = mask;
  info.hbmColor = color;
  HICON icon = CreateIconIndirect(&info);
  DeleteObject(color);
  DeleteObject(mask);
  return icon;
}

template <size_t N>
void CopyText(wchar_t (&dst)[N], const std::wstring& src) {
  const size_t n = std::min(src.size(), N - 1);
  std::copy_n(src.c_str(), n, dst);
  dst[n] = L'\0';
}

}  // namespace

TrayIcon::~TrayIcon() {
  Remove();
  if (icon_) DestroyIcon(icon_);
}

void TrayIcon::SetIcon(const std::vector<uint8_t>& rgba, int size) {
  HICON icon = CreateIconFromRgba(rgba, size);
  if (!icon) return;
  if (icon_) DestroyIcon(icon_);
  icon_ = icon;
  Sync();
}

void TrayIcon::SetTooltip(const std::wstring& tooltip) {
  tooltip_ = tooltip;
  Sync();
}

void TrayIcon::Sync() {
  if (!window_) return;
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kCallbackMessage;
  data.hIcon = icon_ ? icon_
                     : LoadIcon(GetModuleHandle(nullptr),
                                MAKEINTRESOURCE(IDI_APP_ICON));
  CopyText(data.szTip, tooltip_);
  if (!added_) {
    added_ = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
  } else if (!Shell_NotifyIconW(NIM_MODIFY, &data)) {
    // Значок мог пропасть вместе с Проводником — пробуем добавить заново.
    added_ = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
  }
}

void TrayIcon::ShowBalloon(const std::wstring& title, const std::wstring& text) {
  if (!added_) return;
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON;
  data.hBalloonIcon = icon_;
  CopyText(data.szInfoTitle, title);
  CopyText(data.szInfo, text);
  Shell_NotifyIconW(NIM_MODIFY, &data);
}

void TrayIcon::Remove() {
  if (!added_ || !window_) return;
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  added_ = false;
}

void TrayIcon::Readd() {
  if (!added_) return;
  added_ = false;
  Sync();
}

int TrayIcon::ShowMenu() {
  if (!window_ || menu_.empty()) return 0;
  HMENU menu = CreatePopupMenu();
  for (const auto& item : menu_) {
    if (item.separator) {
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      continue;
    }
    UINT flags = MF_STRING | (item.enabled ? 0 : MF_GRAYED);
    AppendMenuW(menu, flags, static_cast<UINT_PTR>(item.id), item.label.c_str());
    if (item.is_default) SetMenuDefaultItem(menu, item.id, FALSE);
  }
  POINT point;
  GetCursorPos(&point);
  // Без этого меню не закроется кликом мимо.
  SetForegroundWindow(window_);
  const int id = TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
      point.x, point.y, window_, nullptr);
  PostMessage(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  return id;
}
