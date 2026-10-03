#!/usr/bin/env bash
# Текст сообщения о выпуске для Telegram (HTML): заголовок и раздел версии из
# CHANGELOG.md (его готовит tool/release_notes.sh). «### Новое» — жирным,
# «- пункт» — «• пункт», `код` — моноширинным.
#
#   bash tool/telegram_message.sh 0.3.2 notes.md
set -euo pipefail

version="$1"
notes="$2"

body=$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
  -e 's/^### \(.*\)$/<b>\1<\/b>/' \
  -e 's/^- /• /' \
  -e 's/`\([^`]*\)`/<code>\1<\/code>/g' \
  "$notes" | sed -e '/./,$!d')

printf '<b>ZapretLauncher %s</b>\n\n' "$version"
# Telegram принимает до 4096 знаков: длинный раздел — только ссылкой на выпуск.
if [ "${#body}" -gt 3800 ]; then
  echo 'Что нового — на странице выпуска.'
else
  printf '%s\n' "$body"
fi
