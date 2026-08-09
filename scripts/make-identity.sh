#!/usr/bin/env bash
#
# Создаёт постоянный сертификат для локальной подписи.
#
# Зачем: ad-hoc подпись (`codesign -s -`) описывается требованием
# `designated => cdhash H"..."`, а cdhash меняется при каждой пересборке.
# macOS привязывает выданные разрешения — «Универсальный доступ», доступ
# к папкам, записи в связке ключей — именно к этому требованию. Поэтому
# на ad-hoc сборке приложение после каждой сборки становится для системы
# новым и разрешения теряет, даже если галочка в списке стоит.
#
# С постоянным сертификатом требование выглядит так:
#   designated => identifier "com.ivan.chelka" and certificate leaf = H"..."
# Идентификатор и сертификат не меняются, поэтому разрешения выдаются один раз.
#
# Сертификат самоподписанный и локальный: он ничего не подтверждает
# посторонним и нужен только чтобы личность приложения была постоянной.
# Удаляется одной командой, см. конец файла.
set -euo pipefail

NAME="${SIGN_IDENTITY:-Chelka Dev}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
	echo "сертификат «$NAME» уже есть"
	exit 0
fi

echo "==> создаю ключ и сертификат «$NAME»"
openssl req -x509 -newkey rsa:2048 \
	-keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
	-days 3650 -nodes -subj "/CN=$NAME" \
	-addext "basicConstraints=critical,CA:false" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=critical,codeSigning" \
	2>/dev/null

# Старые алгоритмы заданы намеренно: связка ключей macOS не читает
# PKCS#12, зашифрованный настройками OpenSSL 3 по умолчанию.
openssl pkcs12 -export \
	-inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" \
	-passout pass:chelka -name "$NAME" \
	-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

echo "==> кладу в связку ключей"
security import "$WORK/identity.p12" \
	-k "$HOME/Library/Keychains/login.keychain-db" \
	-P chelka -T /usr/bin/codesign -A

echo ""
echo "готово. Дальше:"
echo "  make app        — сборка теперь подписывается этим сертификатом"
echo ""
echo "Разрешения, выданные прошлым сборкам, придётся выдать заново один раз:"
echo "  Системные настройки → Конфиденциальность → Универсальный доступ"
echo "  убрать старую запись Chelka.app кнопкой «−», затем разрешить заново."
echo ""
echo "Удалить сертификат: security delete-certificate -c \"$NAME\""
