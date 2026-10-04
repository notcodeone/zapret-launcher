#!/usr/bin/env bash
# Текст сообщения о выпуске для Telegram (HTML): заголовок, у выпусков X.Y.0 — описание
# проекта (tool/telegram_about.txt), затем раздел версии из CHANGELOG.md (его готовит
# tool/release_notes.sh). «### Новое» — жирным, «- пункт» — «• пункт», `код` — моноширинным.
#
#   bash tool/telegram_message.sh 0.3.2 notes.md
set -euo pipefail

version="$1"
notes="$2"
about="$(dirname "$0")/telegram_about.txt"

html() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$@"
}

body=$(html "$notes" | sed \
  -e 's/^### \(.*\)$/<b>\1<\/b>/' \
  -e 's/^- /• /' \
  -e 's/`\([^`]*\)`/<code>\1<\/code>/g' |
  sed -e '/./,$!d')

printf '<b>ZapretLauncher %s</b>\n\n' "$version"
# Минорные и мажорные выпуски (X.Y.0) — для тех, кто только пришёл в канал: что это за проект.
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.0$ ]] && [ -s "$about" ]; then
  html "$about" | sed -e '/./,$!d'
  echo
fi
# Telegram принимает до 4096 знаков: длинный раздел — только ссылкой на выпуск.
if [ "${#body}" -gt 3000 ]; then
  echo 'Что нового — на странице выпуска.'
else
  printf '%s\n' "$body"
fi
