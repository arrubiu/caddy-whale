# caddy-whale

Stack Docker per un reverse proxy [Caddy](https://caddyserver.com/) con
routing basato su label ([caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy)),
protezione perimetrale con [CrowdSec](https://www.crowdsec.net/) e login
centralizzato con [Authelia](https://www.authelia.com/).

## Struttura del repository

```
caddy-whale/
├── script.sh          # Wrapper unico per gestire i tre servizi (vedi sotto)
├── .env.example
├── caddy/             # Reverse proxy: build immagine, Caddyfile, rate limit
├── crowdsec/          # Protezione globale IP (Firewall Bouncer + LAPI)
├── authelia/          # Login/SSO per singoli siti via forward_auth
└── portainer/         # UI di gestione Docker (Portainer CE)
```

Ogni sottocartella è un servizio Docker Compose a sé stante, con il proprio
`docker-compose.yml`, `.env.example` e `README.md` dedicato:

- **[caddy/README.md](caddy/README.md)** — reverse proxy, label-based
  routing, build dell'immagine, rate limiting per sito.
- **[crowdsec/README.md](crowdsec/README.md)** — attivazione della
  protezione globale (Firewall Bouncer + LAPI + Console).
- **[authelia/README.md](authelia/README.md)** — login/SSO condiviso,
  `access_control`, protezione di un sito con `forward_auth`.
- **[portainer/README.md](portainer/README.md)** — UI di gestione Docker,
  per ora senza autenticazione dedicata.

## Gestione dei servizi

Tutti i servizi si avviano e gestiscono con `script.sh` dalla root del
repository:

```bash
./script.sh <servizio> <comando> [argomenti]
```

dove `<servizio>` è uno tra `caddy`, `crowdsec`, `authelia`. Lanciato senza
argomenti mostra l'elenco completo di comandi disponibili (sia quelli Docker
comuni — `up`, `down`, `stop`, `restart`, `ps`, `logs`, `build`, `shell` —
sia quelli specifici per servizio, es. `authelia validate` o
`crowdsec ban <ip>`).

## Avvio rapido

```bash
# Risorse Docker esterne condivise
docker network create caddy
docker volume create caddy_logs

# Caddy (di per sé sufficiente per servire i siti via label)
./script.sh caddy build
./script.sh caddy up

# Opzionale: protezione globale
./script.sh crowdsec up

# Opzionale: login/SSO per siti protetti
./script.sh authelia gen-secrets
./script.sh authelia up
```

Dettagli, prerequisiti e configurazione di ciascun servizio nei rispettivi
README linkati sopra.
