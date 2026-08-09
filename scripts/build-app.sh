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

# Универсальный бинарник по умолчанию для release.
#
# Сборка только под arm64 на Intel-маке даёт «программа не поддерживается
# этим компьютером Mac» — при том, что и система, и подпись в порядке.
# Отладочные сборки собираем под текущую машину: вдвое быстрее.
if [[ "${UNIVERSAL:-}" == "0" || "$CONFIG" != "release" ]]; then
	echo "==> swift build -c $CONFIG (текущая архитектура)"
	swift build --package-path "$ROOT" -c "$CONFIG"
	BIN_PATH="$ROOT/.build/$CONFIG/$APP_NAME"
else
	echo "==> swift build -c $CONFIG (arm64 + x86_64)"
	swift build --package-path "$ROOT" -c "$CONFIG" --arch arm64 --arch x86_64
	BIN_PATH="$ROOT/.build/apple/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}/$APP_NAME"
fi

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
IDENTITY="${SIGN_IDENTITY:-}"

# Если постоянный сертификат создан — подписываем им без лишних слов.
# Ищем именно сертификат, а не «валидную личность»: самоподписанный
# сертификат системой не доверен и в списке валидных не появляется,
# хотя подписывать им можно.
if [[ -z "$IDENTITY" ]]; then
	if security find-certificate -c "Chelka Dev" >/dev/null 2>&1; then
		IDENTITY="Chelka Dev"
	else
		IDENTITY="-"
	fi
fi

if [[ "$IDENTITY" == "-" ]]; then
	echo "==> подпись (ad-hoc — разрешения будут теряться после каждой сборки)"
	echo "    постоянная подпись: make identity"
else
	echo "==> подпись ($IDENTITY)"
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$BUNDLE" >/dev/null

echo "==> проверка подписи"
codesign --verify --deep --strict "$BUNDLE"

echo "==> архитектуры: $(lipo -archs "$BUNDLE/Contents/MacOS/$APP_NAME")"

echo "готово: $BUNDLE"
