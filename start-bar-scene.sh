#!/usr/bin/env bash
#
# Локальный запуск bar_scene_client + bar_scene_ws_server в Docker.
#
# Клиент собирается в production-вид и раздаётся Caddy, запросы к /chatHub
# проксируются в SignalR-сервер. Всё доступно на http://localhost:<порт>.
#
# Если каталоги проектов отсутствуют, скрипт склонирует их из GitHub,
# после чего всегда собирает исходники из этих каталогов.
#
# Использование:
#   ./start-bar-scene.sh            # собрать и запустить (по умолчанию)
#   ./start-bar-scene.sh logs       # смотреть логи
#   ./start-bar-scene.sh restart    # перезапустить
#   ./start-bar-scene.sh down       # остановить и удалить контейнеры
#
# Порт можно изменить: WEB_PORT=8090 ./start-bar-scene.sh
# Репозитории: CLIENT_REPO=... SERVER_REPO=... ./start-bar-scene.sh
#
# Файлы .dockerignore, docker-compose.local.yml и .local-docker/ генерируются
# при каждом запуске и в репозиторий не попадают.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$ROOT_DIR/bar_scene_client"
SERVER_DIR="$ROOT_DIR/bar_scene_ws_server"
CLIENT_REPO="${CLIENT_REPO:-https://github.com/Koshelenok/bar_scene_client.git}"
SERVER_REPO="${SERVER_REPO:-https://github.com/Koshelenok/bar_scene_ws_server.git}"
CONF_DIR="$ROOT_DIR/.local-docker"
COMPOSE_FILE="$ROOT_DIR/docker-compose.local.yml"
WEB_PORT="${WEB_PORT:-8080}"
# Своя подсеть нужна, чтобы docker не зависел от исчерпания стандартного пула.
DOCKER_SUBNET="${DOCKER_SUBNET:-172.30.0.0/24}"
export WEB_PORT DOCKER_SUBNET

log()  { echo -e "\033[1;36m==> $*\033[0m"; }
fail() { echo -e "\033[1;31m[!] $*\033[0m" >&2; exit 1; }

check_requirements() {
  command -v docker >/dev/null 2>&1 || fail "Docker не установлен."
  docker compose version >/dev/null 2>&1 || fail "Нужен Docker Compose plugin (docker compose)."
}

clone_if_missing() {
  local repo="$1"
  local dest="$2"
  local name="$3"

  if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    return
  fi

  command -v git >/dev/null 2>&1 || fail "Каталог $dest не найден, а git не установлен."
  log "Каталог $name отсутствует — клонирую $repo"
  git clone --depth=1 "$repo" "$dest"
}

ensure_sources() {
  clone_if_missing "$CLIENT_REPO" "$CLIENT_DIR" "bar_scene_client"
  clone_if_missing "$SERVER_REPO" "$SERVER_DIR" "bar_scene_ws_server"

  [ -f "$CLIENT_DIR/package.json" ] || fail "$CLIENT_DIR не похож на клиентский проект (нет package.json)."
  [ -f "$SERVER_DIR/WebApplication2.csproj" ] || fail "$SERVER_DIR не похож на серверный проект (нет WebApplication2.csproj)."
}

generate_files() {
  log "Готовлю конфигурацию в .local-docker"
  mkdir -p "$CONF_DIR"

  # Контекст сборки — корень проекта, поэтому мусор исключаем здесь.
  cat > "$ROOT_DIR/.dockerignore" <<'EOF'
**/node_modules
**/bin
**/obj
**/.git
EOF

  cat > "$CONF_DIR/Dockerfile.client" <<'EOF'
FROM node:20-alpine AS build
WORKDIR /app

COPY bar_scene_client/package.json bar_scene_client/package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY bar_scene_client/ ./

ARG REACT_APP_HUB_URL=/chatHub
ENV REACT_APP_HUB_URL=$REACT_APP_HUB_URL
RUN npm run build

FROM caddy:2-alpine
COPY .local-docker/Caddyfile /etc/caddy/Caddyfile
COPY --from=build /app/build /srv
EOF

  cat > "$CONF_DIR/Dockerfile.server" <<'EOF'
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

COPY bar_scene_ws_server/WebApplication2.csproj ./
RUN dotnet restore WebApplication2.csproj

COPY bar_scene_ws_server/ ./
RUN dotnet publish WebApplication2.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /app ./

ENV ASPNETCORE_URLS=http://+:5201
ENV ASPNETCORE_ENVIRONMENT=Production
EXPOSE 5201

ENTRYPOINT ["dotnet", "WebApplication2.dll"]
EOF

  cat > "$CONF_DIR/Caddyfile" <<'EOF'
:80 {
	encode zstd gzip
	root * /srv

	handle /chatHub* {
		reverse_proxy server:5201
	}

	handle {
		try_files {path} /index.html
		file_server
	}
}
EOF

  cat > "$COMPOSE_FILE" <<'EOF'
name: bar_scene_local

services:
  server:
    build:
      context: .
      dockerfile: .local-docker/Dockerfile.server
    restart: unless-stopped
    environment:
      ASPNETCORE_ENVIRONMENT: Production
      ASPNETCORE_URLS: http://+:5201
    expose:
      - "5201"

  web:
    build:
      context: .
      dockerfile: .local-docker/Dockerfile.client
      args:
        REACT_APP_HUB_URL: /chatHub
    restart: unless-stopped
    depends_on:
      - server
    ports:
      - "${WEB_PORT:-8080}:80"

networks:
  default:
    ipam:
      config:
        - subnet: "${DOCKER_SUBNET:-172.30.0.0/24}"
EOF
}

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

up() {
  check_requirements
  ensure_sources
  generate_files
  log "Собираю образы (первый раз может занять несколько минут)"
  compose up -d --build --remove-orphans
  log "Контейнеры запущены"
  compose ps
  echo
  echo "Клиент:  http://localhost:${WEB_PORT}/"
  echo "Хаб:     http://localhost:${WEB_PORT}/chatHub"
  echo
  echo "Логи:    ./start-bar-scene.sh logs"
  echo "Стоп:    ./start-bar-scene.sh down"
}

down() {
  check_requirements
  [ -f "$COMPOSE_FILE" ] || { log "Конфигурация ещё не создавалась — останавливать нечего"; return 0; }
  log "Останавливаю контейнеры"
  compose down --remove-orphans
}

logs() {
  check_requirements
  [ -f "$COMPOSE_FILE" ] || fail "Сначала запусти ./start-bar-scene.sh"
  compose logs -f --tail=100
}

case "${1:-up}" in
  up|start)   up ;;
  down|stop)  down ;;
  restart)    down; up ;;
  logs)       logs ;;
  -h|--help|help)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    fail "Неизвестная команда: $1 (доступно: up, down, restart, logs)"
    ;;
esac
