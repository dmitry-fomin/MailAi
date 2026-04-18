#!/usr/bin/env bash
# A9: lint-проверка тем и Dynamic Type.
# Запрещаем hardcoded цвета/размеры — должны использоваться только
# семантические (.secondary, .accentColor, .tint), а шрифты — relative
# (.body/.caption/.title*), чтобы корректно работали Dark/Light и Dynamic Type.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Сканируем весь UI/AppShell-код. Исключения: build-artefacts.
TARGETS=(
  "Packages/UI/Sources"
  "Packages/AppShell/Sources"
  "MailAi"
)

# Паттерны-нарушения. Каждый элемент: "regex|описание".
# Используем ERE (grep -E). Экранируем скобки.
FORBIDDEN=(
  "Color\\(red:|RGB-литерал Color(red:green:blue:) — используйте системные цвета"
  "Color\\(white:|Color(white:) — используйте системные цвета"
  "Color\\(hex|Color(hex:) — используйте системные цвета"
  "NSColor\\(red:|NSColor(red:) — используйте семантические NSColor"
  "UIColor\\(red:|UIColor(red:) — iOS API в macOS-проекте? используйте семантические цвета"
  "\\.system\\(size:|.system(size:) — используйте relative-шрифты (.body/.title/.caption)"
  "\\.font\\(\\.system\\(\\.|.font(.system(.*) с fixed — используйте semantic font styles"
)

failed=0

for target in "${TARGETS[@]}"; do
  [[ -d "$target" ]] || continue
  while IFS= read -r file; do
    for entry in "${FORBIDDEN[@]}"; do
      regex="${entry%%|*}"
      descr="${entry##*|}"
      # Исключаем строки-комментарии: одиночные //, /// и блочные // lines.
      if matches=$(grep -nE "$regex" "$file" 2>/dev/null | grep -vE "^[0-9]+:[[:space:]]*(//|\*)"); then
        echo "✘ $file — $descr"
        echo "$matches" | sed 's/^/    /'
        failed=1
      fi
    done
  done < <(find "$target" -name '*.swift' -type f)
done

if [[ $failed -eq 0 ]]; then
  echo "✓ lint-theming: запрещённых паттернов не найдено"
else
  echo ""
  echo "✘ lint-theming: обнаружены нарушения (см. выше)"
  exit 1
fi
