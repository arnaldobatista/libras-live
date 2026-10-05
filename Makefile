APP := build/Libras Live.app
PORT ?= 8765

.PHONY: help vlibras ollama build test app run zip dev clean say clear status devices scan e2e burst bench

help:
	@echo "make vlibras  baixa o player Unity do VLibras"
	@echo "make ollama   baixa o motor de IA local (Ollama, só Apple Silicon)"
	@echo "make test     roda os testes"
	@echo "make app      monta build/Libras Live.app"
	@echo "make run      monta e abre o app"
	@echo "make zip      monta o app e gera o .zip do release com o SHA-256"
	@echo "make dev      roda direto com swift run (debug)"
	@echo "make say T='bom dia'   injeta uma frase no app em execução"
	@echo "make clear    limpa a fila do app em execução"
	@echo "make status   estado atual em JSON"
	@echo "make devices  lista dispositivos de áudio e canais"
	@echo "make scan D='Soundcraft'   mostra o pico de cada canal por 8 s"
	@echo "make e2e      teste de ponta a ponta (Chrome headless + app rodando)"
	@echo "make burst    teste de rajada: aceleração e descarte"
	@echo "make bench    mede o tempo do avatar por tipo de glosa e velocidade"

vlibras:
	./Scripts/fetch-vlibras.sh

ollama:
	./Scripts/fetch-ollama.sh

build: vlibras ollama
	swift build

test:
	swift test

app:
	./Scripts/build-app.sh

run: app
	open "$(APP)"

zip:
	./Scripts/package-app.sh

dev: vlibras ollama
	swift run LibrasLive

say:
	@curl -s -X POST "http://127.0.0.1:$(PORT)/api/say" -H 'Content-Type: application/json' \
		-d "$$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$(T)")" -w "%{http_code}\n"

clear:
	@curl -s -X POST "http://127.0.0.1:$(PORT)/api/clear" -H 'Content-Type: application/json' -w "%{http_code}\n"

status:
	@curl -s "http://127.0.0.1:$(PORT)/api/status" | python3 -m json.tool

devices:
	swift run libras-probe devices

scan:
	swift run libras-probe scan "$(D)" 8

e2e:
	node Scripts/e2e-overlay.mjs --port $(PORT) --shot build/e2e.png

burst:
	node Scripts/e2e-overlay.mjs --port $(PORT) --burst

bench:
	node Scripts/bench-avatar.mjs --port $(PORT) --speeds 1,2,3 --trials 1

clean:
	rm -rf build .build
