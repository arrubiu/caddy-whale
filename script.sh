#!/usr/bin/env bash
# Wrapper unico per la gestione dei servizi dello stack (authelia, caddy, crowdsec).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SERVICES=(authelia caddy crowdsec)
AUTHELIA_IMAGE="authelia/authelia:4.39.20"

usage() {
  cat <<EOF
Uso: ./script.sh <servizio> <comando> [argomenti]

Servizi disponibili:
  authelia    caddy    crowdsec

Comandi Docker comuni (validi per ogni servizio):
  up          Avvia il servizio (docker compose up -d)
  down        Ferma e rimuove i container
  stop        Ferma i container senza rimuoverli
  restart     Ricrea e riavvia (up -d --force-recreate)
  ps          Stato dei container
  logs        Segue i log (Ctrl+C per uscire)
  build       Builda l'immagine (rilevante soprattutto per caddy)
  shell       Apre una shell nel container

Comandi specifici per servizio:

  authelia validate            Valida configuration.yml
  authelia gen-secrets         Genera i secret mancanti in authelia/secrets/
  authelia hash <pwd>          Hash argon2 di una password (users_database.yml)
  authelia hash-oidc <secret>  Hash pbkdf2-sha512 di un client secret (oidc.yml)

  caddy fmt                    Formatta/valida il Caddyfile in uso nel container

  crowdsec decisions           Elenca i ban attivi
  crowdsec ban <ip> [motivo]   Banna un IP
  crowdsec unban <ip>          Rimuove un ban
  crowdsec alerts              Elenca gli alert rilevati
  crowdsec bouncers            Stato dei bouncer registrati
  crowdsec metrics             Metriche cscli
  crowdsec hub-update          Aggiorna hub (parser/scenari/collezioni)

Esempi:
  ./script.sh caddy up
  ./script.sh authelia logs
  ./script.sh crowdsec ban 1.2.3.4 "scan"
EOF
}

authelia_cmd() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    validate)
      "${COMPOSE[@]}" run --rm --no-deps authelia \
        authelia config validate --config /config/configuration.yml
      ;;
    gen-secrets)
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
      ;;
    hash)
      local password="${1:?Uso: ./script.sh authelia hash <password>}"
      docker run --rm "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --password "$password"
      ;;
    hash-oidc)
      local secret="${1:?Uso: ./script.sh authelia hash-oidc <secret>}"
      docker run --rm "$AUTHELIA_IMAGE" authelia crypto hash generate pbkdf2 --variant sha512 --password "$secret"
      ;;
    "")
      usage; exit 1 ;;
    *)
      echo "Comando sconosciuto per authelia: $cmd"; echo; usage; exit 1 ;;
  esac
}

caddy_cmd() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    fmt)
      "${COMPOSE[@]}" exec caddy caddy fmt "${CADDY_DOCKER_CADDYFILE_PATH:-/etc/caddy/Caddyfile}"
      ;;
    "")
      usage; exit 1 ;;
    *)
      echo "Comando sconosciuto per caddy: $cmd"; echo; usage; exit 1 ;;
  esac
}

crowdsec_cmd() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    decisions)
      "${COMPOSE[@]}" exec crowdsec cscli decisions list "$@"
      ;;
    ban)
      local ip="${1:?Uso: ./script.sh crowdsec ban <ip> [motivo]}"; shift || true
      local reason="${*:-manuale}"
      "${COMPOSE[@]}" exec crowdsec cscli decisions add --ip "$ip" --reason "$reason"
      ;;
    unban)
      local ip="${1:?Uso: ./script.sh crowdsec unban <ip>}"
      "${COMPOSE[@]}" exec crowdsec cscli decisions delete --ip "$ip"
      ;;
    alerts)
      "${COMPOSE[@]}" exec crowdsec cscli alerts list
      ;;
    bouncers)
      "${COMPOSE[@]}" exec crowdsec cscli bouncers list
      ;;
    metrics)
      "${COMPOSE[@]}" exec crowdsec cscli metrics
      ;;
    hub-update)
      "${COMPOSE[@]}" exec crowdsec cscli hub update
      "${COMPOSE[@]}" exec crowdsec cscli hub upgrade
      ;;
    "")
      usage; exit 1 ;;
    *)
      echo "Comando sconosciuto per crowdsec: $cmd"; echo; usage; exit 1 ;;
  esac
}

if [ $# -lt 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "help" ]; then
  usage
  [ $# -lt 1 ] && exit 1 || exit 0
fi

SERVICE="$1"; shift

case "$SERVICE" in
  authelia|caddy|crowdsec) ;;
  *)
    echo "Servizio sconosciuto: $SERVICE"
    echo
    usage
    exit 1
    ;;
esac

COMPOSE_FILE="$SERVICE/docker-compose.yml"
COMPOSE=(docker compose -f "$COMPOSE_FILE")

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

COMMAND="$1"; shift

case "$COMMAND" in
  up)      "${COMPOSE[@]}" up -d ;;
  down)    "${COMPOSE[@]}" down ;;
  stop)    "${COMPOSE[@]}" stop ;;
  restart) "${COMPOSE[@]}" up -d --force-recreate ;;
  ps)      "${COMPOSE[@]}" ps ;;
  logs)    "${COMPOSE[@]}" logs -f ;;
  build)   "${COMPOSE[@]}" build ;;
  shell)   "${COMPOSE[@]}" exec "$SERVICE" sh ;;
  *)
    case "$SERVICE" in
      authelia) authelia_cmd "$COMMAND" "$@" ;;
      caddy)    caddy_cmd "$COMMAND" "$@" ;;
      crowdsec) crowdsec_cmd "$COMMAND" "$@" ;;
    esac
    ;;
esac
