# Caddy

Reverse proxy [Caddy](https://caddyserver.com/) con routing basato su label
via [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy):
ogni sito espone le proprie label Docker e Caddy genera/aggiorna la
configurazione automaticamente, senza bisogno di toccare il `Caddyfile` per
aggiungere o modificare un sito.

## Immagine

L'immagine è buildata da [Dockerfile](Dockerfile) con
[xcaddy](https://github.com/caddyserver/xcaddy) e i seguenti plugin:

| Plugin | Uso |
|--------|-----|
| `caddy-docker-proxy` | Routing via label Docker (sempre attivo) |
| `caddy-crowdsec-bouncer` | Bouncer HTTP per sito, opzionale — vedi [crowdsec/README.md](../crowdsec/README.md) |
| `caddy-security` | Compilato ma non usato — vedi nota sotto |
| `caddy-ratelimit` | Rate limiting per sito — vedi [RATELIMIT.md](RATELIMIT.md) |

> Nota: il plugin `caddy-security` resta compilato nell'immagine ma non è la
> strada scelta per login/SSO — richiedeva OIDC/local identity store con
> reload non garantito. La soluzione effettivamente in uso è Authelia, vedi
> [authelia/README.md](../authelia/README.md).

Il [Caddyfile](Caddyfile) contiene solo le opzioni globali (log operativi in
JSON); nessun sito è definito staticamente — tutti arrivano dalle label dei
rispettivi docker-compose.

## Reti e volumi

| Rete | Scopo |
|------|-------|
| `caddy` | Rete condivisa — tutti i servizi proxiati si collegano qui |
| `crowdsec` | Usata solo se si attiva il bouncer HTTP per sito (opzionale, vedi crowdsec/README.md) |

| Volume | Contenuto |
|--------|-----------|
| `caddy_data` | Certificati TLS, stato Caddy |
| `caddy_config` | Configurazione Caddy runtime |
| `caddy_logs` | Log operativi Caddy (+ log di accesso HTTP solo se configurati per sito, `external: true`, condiviso con CrowdSec) |

## Avvio

```bash
docker network create caddy
docker volume create caddy_logs   # richiesto anche se CrowdSec non è attivo

./script.sh caddy build
./script.sh caddy up
```

Caddy legge solo le label dei singoli servizi via caddy-docker-proxy, senza
alcuna dipendenza da CrowdSec o Authelia per partire.

## Aggiornare l'immagine

```bash
./script.sh caddy build   # aggiunge --no-cache se serve rebuildare i plugin
./script.sh caddy up
```

## Comandi utili

```bash
./script.sh caddy up       # Avvia
./script.sh caddy down     # Ferma e rimuove
./script.sh caddy restart  # Ricrea (dopo modifiche a Caddyfile/Dockerfile)
./script.sh caddy logs     # Log Caddy
./script.sh caddy ps       # Stato container
./script.sh caddy fmt      # Formatta/valida il Caddyfile nel container
./script.sh caddy shell    # Shell nel container
```

## Estensioni per sito

Funzionalità opzionali, attivabili sito per sito tramite label, senza
toccare la configurazione globale di Caddy:

- **[RATELIMIT.md](RATELIMIT.md)** — limiti di richieste per IP/API key con
  `caddy-ratelimit`.
- **[crowdsec/README.md](../crowdsec/README.md)** — protezione globale IP e
  bouncer HTTP opzionale per sito.
- **[authelia/README.md](../authelia/README.md)** — login/SSO con
  `forward_auth` per proteggere un sito.

## Struttura file

```
caddy/
├── Dockerfile          # Build xcaddy con i plugin
├── Caddyfile            # Config globale (crowdsec disattivato + log)
├── docker-compose.yml
├── .env.example
├── README.md
└── RATELIMIT.md         # Guida al rate limiting per sito
```
