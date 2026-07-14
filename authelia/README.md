# Authelia

Login/SSO condiviso per proteggere singoli siti con
[Authelia](https://www.authelia.com/) tramite `forward_auth` di Caddy —
**niente OIDC**: un solo login su Authelia, niente client/secret/redirect_uri
per app, niente restart di Authelia quando aggiungi un nuovo sito (solo
quando cambi utenti/policy in modo strutturale).

> Nota: il plugin `caddy-security` resta compilato nell'immagine Caddy (vedi
> [caddy/Dockerfile](../caddy/Dockerfile)) ma non è la strada scelta —
> richiedeva OIDC/local identity store con reload non garantito. Questo
> documento descrive la soluzione effettivamente in uso: Authelia.

## Setup

Config base in [configuration.yml](configuration.yml) (versionata, nessun
segreto), utenti in `users_database.yml` (copia da
[users_database.yml.example](users_database.yml.example), ignorato da git),
segreti su file in `secrets/` (ignorati da git). Gestione del servizio con
[script.sh](../script.sh) dalla root del repository.

```bash
docker network create caddy   # se non già creata (condivisa con Caddy)
cp authelia/users_database.yml.example authelia/users_database.yml
./script.sh authelia gen-secrets   # crea i secret mancanti in authelia/secrets/
./script.sh authelia up
```

## Concetti chiave

- **Un solo backend utenti**, condiviso da tutti i siti protetti — non c'è
  nulla da configurare per app, a differenza di OIDC (niente client_id/secret).
- **`access_control`**: le regole in `authelia/configuration.yml` decidono
  *quale policy* (`one_factor` / `two_factor` / `deny`) si applica a una
  richiesta, in base al dominio. Non decidono *chi* viene gateato — quello lo
  decide Caddy, sito per sito, con `forward_auth` nelle sue label.
- **Dominio wildcard**: una sola regola `*.example.com` copre tutti i
  sottodomini presenti e futuri — non serve mappare ogni sito uno per uno.
- **Nessun reload a caldo** per `access_control`/client/policy: dopo aver
  cambiato `configuration.yml` o `oidc.yml` serve `./script.sh authelia restart`.
  Solo `users_database.yml` si ricarica da solo (`watch: true`).

---

## Aggiungere un dominio con wildcard sui sottodomini

In [authelia/configuration.yml](authelia/configuration.yml):

```yaml
access_control:
  default_policy: 'deny'
  rules:
    # Regole SPECIFICHE prima — Authelia valuta in ordine e si ferma alla
    # prima che matcha. Una regola generica messa per prima "vince" sempre
    # su quelle più specifiche scritte dopo.
    - domain: 'internal-tools.example.com'
      subject: 'user:admin'
      policy: 'two_factor'

    - domain: 'staging.example.com'
      policy: 'one_factor'   # es. staging meno rigido di produzione

    # Regola generica, DOPO le eccezioni: copre tutto il resto sotto lo
    # stesso dominio, presente e futuro, senza altre modifiche.
    - domain: '*.example.com'
      policy: 'one_factor'

session:
  cookies:
    - domain: 'example.com'   # dominio padre reale, per la SSO tra sottodomini
      name: 'authelia_session'
```

Punti da tenere a mente (già verificati, non teoria):
- `domain` (o `domain_regex`) è **obbligatorio** su ogni regola — non esiste
  un modo di "non mappare" del tutto; il wildcard `*.example.com` è già la
  forma più generica sensata.
- Non usare un wildcard completamente aperto (`domain_regex: '^.*$'`): non fa
  risparmiare nulla rispetto a `*.example.com` (comunque una riga), ma elimina
  l'unico confine di sicurezza rimasto (la regola si applicherebbe a
  *qualunque* Host header inoltrato a Authelia, anche un dominio non tuo).
- **Rischio reale del wildcard**: non è tecnico, è di disciplina — un nuovo
  sottodominio sensibile aggiunto in futuro eredita silenziosamente la policy
  generica finché non aggiungi tu una regola specifica sopra. Non c'è modo di
  farselo ricordare automaticamente: è una checklist mentale, non una
  protezione del sistema.
- Dopo aver cambiato `access_control`: `./script.sh authelia validate` poi
  `./script.sh authelia restart`.

---

## Proteggere un sito dal suo docker-compose

Nessuna label sul lato Authelia — tutto sul docker-compose del sito, con
`forward_auth`. Il sito **deve** restare raggiungibile solo dalla rete
`caddy` (nessuna porta pubblicata): è l'unico modo per garantire che il gate
non sia aggirabile raggiungendo il container per un'altra via.

```yaml
services:
  app:
    image: myapp:latest
    networks:
      - caddy
    labels:
      caddy: app.example.com
      caddy.route.0_request_header: "-Remote-User"
      caddy.route.1_request_header: "-Remote-Groups"
      caddy.route.2_request_header: "-Remote-Email"
      caddy.route.3_forward_auth: authelia:9091
      caddy.route.3_forward_auth.uri: /api/authz/forward-auth
      caddy.route.3_forward_auth.copy_headers: Remote-User Remote-Groups Remote-Email
      caddy.route.4_reverse_proxy: "{{upstreams 8080}}"
```

Genera:
```caddyfile
app.example.com {
    route {
        request_header -Remote-User
        request_header -Remote-Groups
        request_header -Remote-Email
        forward_auth authelia:9091 {
            uri /api/authz/forward-auth
            copy_headers Remote-User Remote-Groups Remote-Email
        }
        reverse_proxy {{upstreams 8080}}
    }
}
```

**Perché i tre `request_header -...` prima di `forward_auth`**: esiste una
CVE reale su Caddy (CVE-2026-30851, CVSS 8.1, corretta in 2.11.2) in cui, se
il servizio di auth non restituiva un header, quello **fornito dal client
stesso** (es. `Remote-User: admin` scritto a mano da un attaccante) passava
indisturbato al backend — bypass identità con un token qualsiasi, non
privilegiato. Il [Dockerfile](Dockerfile) è già su `caddy:2.11.4` (patchata),
ma lo stripping esplicito è difesa in profondità indipendente dalla versione:
va sempre incluso, non è opzionale.

Il sito riceve, se autenticato, `Remote-User` / `Remote-Groups` /
`Remote-Email` — un'app che li sappia leggere (es. Grafana con
`[auth.proxy]` nativo) fa auto-login da sola. Un'app senza questo supporto
nativo (es. Drupal) resta comunque protetta a livello di rete (nessuno
sconosciuto la raggiunge), ma per un vero single-login serve un modulo/plugin
lato app che legga questi header e autentichi l'utente corrispondente —
vedi nota sotto sui rischi di farlo.

### Escludere un path dal gate (es. API consumate da un build tool)

Utile quando un sito ha sia contenuti da proteggere sia un endpoint machine-
to-machine con la propria autenticazione (es. Basic Auth applicativa) che
deve restare raggiungibile senza passare dal login umano di Authelia:

```yaml
labels:
  caddy: app.example.com
  caddy.route.0_request_header: "-Remote-User"
  caddy.route.1_request_header: "-Remote-Groups"
  caddy.route.2_request_header: "-Remote-Email"
  caddy.route.3.@api_path.path: /api*
  caddy.route.4_reverse_proxy: "@api_path {{upstreams 8080}}"
  caddy.route.5_forward_auth: authelia:9091
  caddy.route.5_forward_auth.uri: /api/authz/forward-auth
  caddy.route.5_forward_auth.copy_headers: Remote-User Remote-Groups Remote-Email
  caddy.route.6_reverse_proxy: "{{upstreams 8080}}"
```

Genera:
```caddyfile
app.example.com {
    route {
        request_header -Remote-User
        request_header -Remote-Groups
        request_header -Remote-Email

        @api_path path /api*
        reverse_proxy @api_path {{upstreams 8080}}

        forward_auth authelia:9091 {
            uri /api/authz/forward-auth
            copy_headers Remote-User Remote-Groups Remote-Email
        }
        reverse_proxy {{upstreams 8080}}
    }
}
```

Ordine importante:
1. Lo stripping degli header va **sempre per primo**, anche sulle richieste
   `/api` — altrimenti chi chiama `/api` direttamente (bypassando
   `forward_auth`) potrebbe forgiare `Remote-User` senza che nulla lo cancelli.
2. Il ramo `/api` va **prima** di `forward_auth`: una volta che
   `reverse_proxy @api_path` gestisce la richiesta, le direttive successive
   nella route non vengono eseguite per quella richiesta — è così che `/api`
   bypassa il login umano restando comunque sulla propria autenticazione
   applicativa (es. Basic Auth), invariata.

`uri /api/authz/forward-auth` nella direttiva `forward_auth` è un path sul
backend **Authelia** (`authelia:9091`), non sul sito protetto — nessuna
collisione reale con un `/api*` del sito stesso, anche se il nome coincide.

---

## Un modulo custom lato app che si fida degli header: è sicuro?

Può esserlo, con tre condizioni, tutte necessarie insieme:

1. **Vincolo di rete**: l'app non deve mai essere raggiungibile se non
   tramite Caddy (nessuna porta pubblicata, solo rete `caddy`).
2. **Stripping esplicito** dei tre header prima di `forward_auth` (vedi
   sopra) — difesa in profondità indipendente da eventuali bug futuri in
   Caddy o Authelia.
3. **Interruttore esplicito per ambiente**, mai rilevamento implicito: il
   modulo deve fidarsi dell'header solo se un flag di configurazione lo dice
   esplicitamente (es. una variabile d'ambiente diversa per ambiente),
   *fail-safe di default* (flag assente = non fidarsi, login nativo dell'app
   resta disponibile). Utile per un ambiente locale senza Caddy davanti, dove
   il login nativo dell'app deve continuare a funzionare normalmente.

Inoltre, per il matching per nome tra utente Authelia e utente dell'app:
non far **auto-creare** account nuovi al volo — il modulo deve solo
autenticare un account già esistente con quel nome, mai generarne uno a
sorpresa per qualunque utente Authelia (che magari esiste solo per
un'altra app protetta dallo stesso gate).

Anche rispettando tutto questo, resta una superficie di fiducia in più
rispetto a OIDC standard (che valida la relazione app↔identità per
progettazione, non per disciplina manuale) — è un compromesso consapevole
per avere un solo login, non un'opzione "gratis".

---

## Gestione del servizio

```bash
./script.sh authelia up             # avvia
./script.sh authelia stop           # ferma senza rimuovere
./script.sh authelia restart        # ricrea — necessario dopo modifiche a
                                     # configuration.yml, oidc.yml, authelia/secrets/
./script.sh authelia validate       # valida configuration.yml prima di riavviare
./script.sh authelia ps
./script.sh authelia logs
./script.sh authelia shell
./script.sh authelia gen-secrets            # crea i secret mancanti la prima volta
./script.sh authelia hash <password>        # hash per users_database.yml
./script.sh authelia hash-oidc <secret>     # hash per un eventuale client oidc.yml
```

---

## Nota: SSO tra domini separati

`session.cookies[].domain` funziona solo tra sottodomini dello stesso
dominio padre. Se due siti sono su domini di primo livello diversi (es.
`app.example.com` e `app.altro-dominio.it`), ciascuno richiede un proprio
login: niente sessione condivisa tra domini non imparentati, qualunque
meccanismo di autenticazione si usi.

## Struttura file

```
authelia/
├── docker-compose.yml
├── configuration.yml            # Config base (versionata, nessun segreto)
├── users_database.yml.example   # Template — copia in users_database.yml (ignorato da git)
├── secrets/                     # jwt/session/storage/oidc secret su file (ignorato da git)
├── .env.example
└── README.md
```
