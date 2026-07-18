# Portainer

UI di gestione Docker ([Portainer CE](https://www.portainer.io/), ultima
versione via tag `latest`), esposta dietro Caddy tramite le label di
[caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) —
stesso meccanismo usato dagli altri servizi dello stack.

## Accesso

L'istanza risponde su `https://portainer.whalestudio.dev`, protetta da
**due livelli distinti** (non ridondanti, vedi commento sulle label in
[docker-compose.yml](docker-compose.yml)):

1. **Gate di rete** — `forward_auth` verso Authelia (label su questo
   `docker-compose.yml` + regola `access_control` in
   [authelia/configuration.yml](../authelia/configuration.yml)): serve
   two_factor e i gruppi `admins` **e** `portainer` insieme (AND esplicito)
   solo per raggiungere Portainer, login incluso.
2. **Login applicativo OIDC** — una volta dentro, il pulsante "Login with
   OAuth" di Portainer autentica l'utente reale via il client `portainer` in
   [authelia/oidc.yml](../authelia/oidc.yml) (stessa policy
   `admins`+`portainer`, two_factor). Auto-provisioning utenti disattivato in
   Portainer: un nuovo utente va comunque creato a mano in **Settings →
   Users** prima che possa entrare via SSO.

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

## Note sull'autenticazione

- Chi deve accedere a Portainer serve **entrambi** i gruppi in
  `authelia/users_database.yml`: `admins` **e** `portainer` — avere solo
  `admins` (es. un admin di un altro sito) non basta né per il gate di rete
  né per la policy OIDC.
- Il logout da Portainer non chiude la sessione Authelia da solo: il campo
  "Logout URL" nelle impostazioni OAuth di Portainer va puntato a
  `https://auth.whalestudio.dev/logout?rd=https://portainer.whalestudio.dev`,
  altrimenti il prossimo giro l'SSO riloga silenziosamente.
- L'account admin locale di Portainer (creato al primo avvio) va tenuto come
  *break-glass* in caso Authelia sia irraggiungibile — non disattivare
  l'autenticazione interna di Portainer.

## Struttura file

```
portainer/
├── docker-compose.yml
└── README.md
```
