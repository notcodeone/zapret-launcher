#!/usr/bin/env bash
# Текст выпуска версии — её раздел из CHANGELOG.md, с пунктами в одну строку:
# в CHANGELOG.md они перенесены по ширине, а GitHub в тексте выпуска показывает
# каждый перенос как новую строку.
#
#   bash tool/release_notes.sh 0.2.0 > notes.md
set -euo pipefail

version="${1:?Укажите версию, например: bash tool/release_notes.sh 0.2.0}"

awk -v v="$version" '
  /^## / { on = ($2 == v); next }
  !on { next }
  # Продолжение пункта: отступ и текст (а не вложенный список) — к прошлой строке.
  /^ +[^ -]/ && held != "" { sub(/^ +/, ""); held = held " " $0; next }
  { if (started) print held; held = $0; started = 1 }
  END { if (started) print held }
' CHANGELOG.md
