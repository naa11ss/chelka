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

COMPONENT_PLIST="$ROOT/build/component.plist"

echo "==> готовлю дерево установки"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/Applications"
# ditto вместо cp -R: правильно переносит бандл целиком, не задевая подпись.
#
# Файлы-спутники вида ._Chelka в нагрузке при этом остаются: их порождает
# com.apple.provenance — атрибут, который macOS вешает на исполняемые файлы
# сама и возвращает снова, сколько его ни снимай. Они безвредны (система их
# игнорирует), а вычищать атрибуты агрессивнее — риск задеть подпись ради
# косметики. Проверено: подпись после ditto цела.
ditto --norsrc "$BUNDLE" "$PKG_ROOT/Applications/$APP_NAME.app"

# Запрет на перемещение бандла — не косметика, а починка установки.
#
# pkgbuild по умолчанию помечает бандл «перемещаемым», и Installer,
# обнаружив на диске другой бандл с тем же CFBundleIdentifier, ставит
# ПОВЕРХ НЕГО, а не в /Applications. Проверено по /var/log/install.log:
#     Applications/Chelka.app relocated to Users/…/build/Chelka.app
#     Applications/Chelka.app relocated to Applications/kakoitobar/build/Chelka.app
# То есть у любого, у кого рядом лежала прежняя копия (например, сборка
# из исходников), приложение «устанавливалось успешно», но в /Applications
# не появлялось никогда — ровно то, что мы полдня не могли объяснить
# на чужой машине.
echo "==> запрещаю перемещение бандла"
pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENT_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"

echo "==> собираю пакет"
pkgbuild \
	--root "$PKG_ROOT" \
	--component-plist "$COMPONENT_PLIST" \
	--identifier "$IDENTIFIER" \
	--version "$VERSION" \
	--install-location "/" \
	"$PKG_OUT" >/dev/null

rm -rf "$PKG_ROOT" "$COMPONENT_PLIST"

echo "готово: $PKG_OUT"
echo "контрольная сумма: $(shasum -a 256 "$PKG_OUT" | awk '{print $1}')"
