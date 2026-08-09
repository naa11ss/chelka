#!/usr/bin/env bash
#
# Собирает Chelka.pkg — установщик поверх уже готового Chelka.app.
#
# Зачем это существует рядом с .zip: у .zip установка идёт руками —
# скачать, распаковать, перетащить, иногда мимо (вложенная папка,
# частичная распаковка, второй экземпляр рядом со старым). Пакет
# устанавливает через системный Installer.app: один файл, один клик,
# кладёт туда, куда нужно, сам. Меньше шагов — меньше способов ошибиться
# посередине.
#
# Пакет НЕ решает вопрос доверия Gatekeeper — сертификат тот же
# самоподписанный, читай README про Открыть через правую кнопку.
# Это чинит только надёжность самой распаковки/переноса.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Chelka"
BUNDLE="$ROOT/build/$APP_NAME.app"
PKG_ROOT="$ROOT/build/pkg-root"
PKG_OUT="$ROOT/build/$APP_NAME.pkg"
IDENTIFIER="com.ivan.chelka.installer"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUNDLE/Contents/Info.plist" 2>/dev/null || echo "0.1.0")"

if [[ ! -d "$BUNDLE" ]]; then
	echo "!! $BUNDLE не найден — сначала make app" >&2
	exit 1
fi

echo "==> готовлю дерево установки"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$BUNDLE" "$PKG_ROOT/Applications/"

echo "==> собираю пакет"
pkgbuild \
	--root "$PKG_ROOT" \
	--identifier "$IDENTIFIER" \
	--version "$VERSION" \
	--install-location "/" \
	"$PKG_OUT" >/dev/null

rm -rf "$PKG_ROOT"

echo "готово: $PKG_OUT"
echo "контрольная сумма: $(shasum -a 256 "$PKG_OUT" | awk '{print $1}')"
