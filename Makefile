.PHONY: help build test app run stop clean check snapshots diagnose

APP := build/Chelka.app

help: ## Показать список команд
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Собрать в debug
	swift build

test: ## Прогнать тесты ядра
	swift test

app: ## Собрать Chelka.app (release + ad-hoc подпись)
	@bash scripts/build-app.sh

run: stop app ## Пересобрать и запустить
	@open $(APP)
	@echo "запущено — иконка в меню-баре"

stop: ## Остановить запущенный экземпляр
	@pkill -x Chelka 2>/dev/null || true

snapshots: build ## Отрендерить виды в docs/snapshots (обе темы, оба состояния)
	@.build/debug/Chelka --snapshot docs/snapshots

diagnose: build ## Показать, что приложение видит на этой машине
	@.build/debug/Chelka --diagnose

check: test ## Полная проверка перед коммитом
	@CONFIG=debug bash scripts/build-app.sh >/dev/null
	@echo "проверка пройдена"

clean: ## Удалить артефакты сборки
	swift package clean
	rm -rf build .build
