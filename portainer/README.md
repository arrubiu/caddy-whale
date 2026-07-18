# Portainer

UI di gestione Docker ([Portainer CE](https://www.portainer.io/), ultima
versione via tag `latest`), esposta dietro Caddy tramite le label di
[caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) —
stesso meccanismo usato dagli altri servizi dello stack.

## Accesso

L'istanza risponde su `https://portainer.whalestudio.dev`.

> **Per ora nessuna autenticazione dedicata**: il sito non è protetto da
> Authelia (nessuna label `forward_auth`, nessuna `access_control` in
> [authelia/configuration.yml](../authelia/configuration.yml)). L'unica
> protezione è quella nativa di Portainer (creazione dell'utente admin al
> primo avvio). Da configurare al primo accesso — vedi TODO Authelia sotto.

## Reti e volumi

| Rete | Scopo |
|------|-------|
| `caddy` | Rete condivisa — Caddy raggiunge Portainer sulla porta 9000 |

| Volume | Contenuto |
|--------|-----------|
| `portainer_data` | Stato Portainer (utenti, endpoint, config) |

Il container monta anche `/var/run/docker.sock` per gestire il Docker
dell'host — accesso equivalente a root sull'host, da tenere presente quando
si deciderà l'autenticazione.

## Avvio

```bash
docker network create caddy   # se non già creata da caddy/

./script.sh portainer up
```

Al primo accesso a `https://portainer.whalestudio.dev` va creato l'utente
amministratore entro pochi minuti dall'avvio, altrimenti Portainer richiede
un riavvio del container per sbloccare la creazione.

## Comandi utili

```bash
./script.sh portainer up       # Avvia
./script.sh portainer down     # Ferma e rimuove
./script.sh portainer restart  # Ricrea
./script.sh portainer logs     # Log
./script.sh portainer ps       # Stato container
./script.sh portainer shell    # Shell nel container
```

Nessun comando specifico oltre a quelli Docker comuni, per ora.

## TODO Authelia

Quando si deciderà di agganciare Portainer al login centralizzato, le
opzioni sono le stesse già documentate per gli altri siti in
[authelia/README.md](../authelia/README.md):

- `forward_auth` classico (label su questo `docker-compose.yml` + regola in
  `access_control`), oppure
- client OIDC dedicato in `authelia/oidc.yml` (Portainer supporta login
  OAuth/OIDC nativamente in CE) — il `.gitignore` della root prevede già
  questo caso ("client OIDC reali (Drupal/Grafana/Portainer, quando
  attivati)").

## Struttura file

```
portainer/
├── docker-compose.yml
└── README.md
```
