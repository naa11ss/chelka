#!/usr/bin/env bash
#
# Собирает Chelka.app из SPM-продукта.
#
# Xcode-проекта в репозитории нет намеренно: SwiftUI и AppKit доступны
# из системного SDK, а .app-бандл — это всего лишь директория с Info.plist.
# Так сборка воспроизводится одинаково локально и в CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP_NAME="Chelka"
BUNDLE="$ROOT/build/$APP_NAME.app"
BIN_PATH="$ROOT/.build/$CONFIG/$APP_NAME"

echo "==> swift build -c $CONFIG"
swift build --package-path "$ROOT" -c "$CONFIG"

if [[ ! -x "$BIN_PATH" ]]; then
	echo "!! бинарник не найден: $BIN_PATH" >&2
	exit 1
fi

echo "==> собираю бандл"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Локализации кладём прямо в Contents/Resources: ядро слинковано статически,
# и NSLocalizedString ищет переводы в Bundle.main, а не в отдельном бандле.
for LPROJ in "$ROOT/Resources"/*.lproj; do
	[[ -d "$LPROJ" ]] && cp -R "$LPROJ" "$BUNDLE/Contents/Resources/"
done

# SPM кладёт ресурсные бандлы рядом с бинарником — переносим их внутрь .app,
# иначе Bundle.module не найдёт локализации.
shopt -s nullglob
for RESOURCE_BUNDLE in "$ROOT/.build/$CONFIG"/*.bundle; do
	cp -R "$RESOURCE_BUNDLE" "$BUNDLE/Contents/Resources/"
done
shopt -u nullglob

# Личность подписи.
#
# Ad-hoc (`-`) меняется при каждой пересборке, а связка ключей и TCC
# привязывают выданные разрешения именно к личности приложения. Поэтому
# на ad-hoc сборке macOS переспрашивает доступ после каждой сборки.
# Постоянный сертификат снимает это: SIGN_IDENTITY="Chelka Dev" make app
IDENTITY="${SIGN_IDENTITY:--}"

if [[ "$IDENTITY" == "-" ]]; then
	echo "==> подпись (ad-hoc — разрешения будут переспрашиваться после каждой сборки)"
else
	echo "==> подпись ($IDENTITY)"
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$BUNDLE" >/dev/null

echo "==> проверка подписи"
codesign --verify --deep --strict "$BUNDLE"

echo "готово: $BUNDLE"
