.PHONY: help build test app pkg run stop clean check snapshots diagnose

APP := build/Chelka.app

help: ## Показать список команд
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Собрать в debug
	swift build

test: ## Прогнать тесты ядра
	swift test

identity: ## Создать постоянный сертификат подписи (один раз)
	@bash scripts/make-identity.sh

app: ## Собрать Chelka.app (release, arm64 + x86_64, с подписью)
	@bash scripts/build-app.sh

dist: app ## Собрать архив для переноса на другой Mac (+ контрольная сумма)
	@rm -f build/Chelka.zip build/Chelka.zip.sha256
	@cd build && ditto -c -k --keepParent Chelka.app Chelka.zip
	@cd build && shasum -a 256 Chelka.zip > Chelka.zip.sha256
	@echo "архив: build/Chelka.zip"
	@echo "сумма: $$(cat build/Chelka.zip.sha256)"
	@echo ""
	@echo "на другом Mac после скачивания сверить:"
	@echo "  shasum -a 256 Chelka.zip"
	@echo "(не совпало с суммой выше — файл побился при передаче, качать заново)"
	@echo ""
	@echo "затем: распаковать, правая кнопка → Открыть"
	@echo "(приложение подписано локальным сертификатом, обычный двойной клик его не пустит)"

pkg: app ## Собрать .pkg-установщик — надёжнее ручной распаковки zip
	@bash scripts/build-pkg.sh
	@echo ""
	@echo "на другом Mac: двойной клик по Chelka.pkg → Installer сам положит в /Applications"
	@echo "первый запуск всё равно потребует правая кнопка → Открыть (сертификат тот же)"

run: stop app ## Пересобрать и запустить
	@open $(APP)
	@echo "запущено — иконка в меню-баре"

stop: ## Остановить запущенный экземпляр
	@pkill -x Chelka 2>/dev/null || true

snapshots: build ## Отрендерить виды в docs/snapshots (обе темы, оба состояния)
	@.build/debug/Chelka --snapshot docs/snapshots

diagnose: build ## Показать, что приложение видит на этой машине
	@.build/debug/Chelka --diagnose

hover-demo: build stop ## Прогнать сценарий наведения и сверить состояния
	@.build/debug/Chelka --hover-demo

clipboard-demo: build stop ## Сквозная проверка буфера на живой системе
	@.build/debug/Chelka --clipboard-demo

metrics-demo: build stop ## Проверка метрик на живой машине
	@.build/debug/Chelka --metrics-demo

music-demo: build stop ## Проверка музыкального модуля (плееры не запускает)
	@.build/debug/Chelka --music-demo

settings-demo: build stop ## Проверка окна настроек
	@.build/debug/Chelka --settings-demo

verify: test hover-demo clipboard-demo metrics-demo music-demo settings-demo snapshots ## Все проверки разом
	@echo "все проверки пройдены"

check: test ## Полная проверка перед коммитом
	@CONFIG=debug bash scripts/build-app.sh >/dev/null
	@echo "проверка пройдена"

clean: ## Удалить артефакты сборки
	swift package clean
	rm -rf build .build
