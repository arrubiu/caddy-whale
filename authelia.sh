#!/usr/bin/env bash
# Wrapper per il ciclo di vita di Authelia in questo stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.authelia.yml"
IMAGE="authelia/authelia:4.39.20"

usage() {
  cat <<EOF
Uso: ./authelia.sh <comando> [argomenti]

  start         Avvia Authelia (docker compose up -d)
  stop          Ferma il container senza rimuoverlo
  restart       Ricrea e riavvia Authelia — necessario dopo aver modificato
                configuration.yml, oidc.yml o un file in authelia/secrets/
                (non si ricaricano a caldo; solo users_database.yml lo fa,
                grazie a "watch: true")
  status        Stato del container
  logs          Segue i log (Ctrl+C per uscire)
  shell         Apre una shell nel container
  validate      Valida la sintassi di configuration.yml (utile prima di un
                restart, per non scoprire un errore a container fermo)
  gen-secrets   Genera i file mancanti in authelia/secrets/
                (jwt_secret, session_secret, storage_encryption_key)
  hash <pwd>            Hash argon2 di una password (per users_database.yml)
  hash-oidc <secret>    Hash pbkdf2-sha512 di un client secret (per oidc.yml)
EOF
}

cmd_start() {
  docker compose -f "$COMPOSE_FILE" up -d
}

cmd_stop() {
  docker compose -f "$COMPOSE_FILE" stop
}

cmd_restart() {
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate
}

cmd_status() {
  docker compose -f "$COMPOSE_FILE" ps
}

cmd_logs() {
  docker compose -f "$COMPOSE_FILE" logs -f authelia
}

cmd_shell() {
  docker compose -f "$COMPOSE_FILE" exec authelia sh
}

cmd_validate() {
  docker compose -f "$COMPOSE_FILE" run --rm --no-deps authelia \
    authelia config validate --config /config/configuration.yml
}

cmd_gen_secrets() {
  mkdir -p authelia/secrets
  local created=0
  for f in jwt_secret session_secret storage_encryption_key; do
    if [ ! -f "authelia/secrets/$f" ]; then
      openssl rand -hex 32 > "authelia/secrets/$f"
      echo "Generato authelia/secrets/$f"
      created=1
    fi
  done
  [ "$created" -eq 0 ] && echo "Esistono già tutti, nulla da generare."
  return 0
}

cmd_hash() {
  local password="${1:?Uso: ./authelia.sh hash <password>}"
  docker run --rm "$IMAGE" authelia crypto hash generate argon2 --password "$password"
}

cmd_hash_oidc() {
  local secret="${1:?Uso: ./authelia.sh hash-oidc <secret>}"
  docker run --rm "$IMAGE" authelia crypto hash generate pbkdf2 --variant sha512 --password "$secret"
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_restart ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  shell) cmd_shell ;;
  validate) cmd_validate ;;
  gen-secrets) cmd_gen_secrets ;;
  hash) shift; cmd_hash "$@" ;;
  hash-oidc) shift; cmd_hash_oidc "$@" ;;
  *) usage; exit 1 ;;
esac
