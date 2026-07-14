# Rate limiting per sito con caddy-ratelimit

Guida all'uso di [`caddy-ratelimit`](https://github.com/mholt/caddy-ratelimit)
(già compilato nell'immagine, vedi [Dockerfile](Dockerfile)) per limitare le
richieste sui singoli siti tramite le label di caddy-docker-proxy.

A differenza di CrowdSec o caddy-security, `rate_limit` **non richiede alcun
blocco globale** nel [Caddyfile](Caddyfile) base: ogni sito definisce le
proprie "zone" di rate limit interamente tramite le proprie label, in modo
del tutto indipendente dagli altri siti.

## Concetti chiave

- **Zona**: un limite (`window` + `events`) identificato da un nome a tua
  scelta.
- **Key**: cosa identifica il "cliente" da limitare. Può essere statica
  (un solo limite condiviso da tutti) o dinamica con un placeholder Caddy
  (es. `{remote_host}` per IP, `{http.request.header.X-Api-Key}` per API key).
- **Sliding window**: se in `window` ci sono già `events` richieste, la
  richiesta successiva riceve `429 Too Many Requests` con header
  `Retry-After` calcolato automaticamente.
- **Ordine**: `rate_limit` è già registrato da Caddy per girare prima di
  `basic_auth` — nella maggior parte dei casi non serve alcun `order`
  esplicito né un blocco `route`, come mostrato negli esempi semplici. Per
  catene con più moduli di terze parti (es. insieme ad `authorize` di
  caddy-security) conviene invece un `route` con ordine esplicito, vedi
  l'esempio avanzato in fondo.

---

## Esempio semplice 1 — limite globale sul sito (key statica)

Utile per proteggere un endpoint pesante da un picco di traffico
complessivo, indipendentemente da chi lo genera: max 100 richieste GET al
minuto, in totale, su tutto il sito.

```yaml
services:
  mysite:
    image: mysite:latest
    networks:
      - caddy
    labels:
      caddy: mysite.example.com
      caddy.rate_limit.zone.mysite_global.match.method: GET
      caddy.rate_limit.zone.mysite_global.key: static
      caddy.rate_limit.zone.mysite_global.events: 100
      caddy.rate_limit.zone.mysite_global.window: 1m
      caddy.reverse_proxy: "{{upstreams 8080}}"
```

Genera:
```caddyfile
mysite.example.com {
    rate_limit {
        zone mysite_global {
            match {
                method GET
            }
            key    static
            events 100
            window 1m
        }
    }
    reverse_proxy {{upstreams 8080}}
}
```

## Esempio semplice 2 — limite per IP client (il caso più comune)

Max 20 richieste ogni 10 secondi, per singolo indirizzo IP.

```yaml
labels:
  caddy: mysite.example.com
  caddy.rate_limit.zone.mysite_ip.key: "{remote_host}"
  caddy.rate_limit.zone.mysite_ip.events: 20
  caddy.rate_limit.zone.mysite_ip.window: 10s
  caddy.reverse_proxy: "{{upstreams 8080}}"
```

Genera:
```caddyfile
mysite.example.com {
    rate_limit {
        zone mysite_ip {
            key    {remote_host}
            events 20
            window 10s
        }
    }
    reverse_proxy {{upstreams 8080}}
}
```

---

## Esempio avanzato 1 — più zone, una più severa su path sensibili

Limite generale per IP su tutto il sito, più uno **specifico e più severo**
solo su `/login` e `/wp-login.php` (tipico bersaglio di brute force), con
protezione dagli IP che eludono il limite cambiando indirizzo dentro lo
stesso blocco `/64` IPv6.

```yaml
labels:
  caddy: mysite.example.com

  # zona generale: 60 richieste al minuto per IP
  caddy.rate_limit.zone.mysite_general.key: "{remote_host}"
  caddy.rate_limit.zone.mysite_general.events: 60
  caddy.rate_limit.zone.mysite_general.window: 1m
  caddy.rate_limit.zone.mysite_general.ipv6_prefix: 64

  # zona login: 5 tentativi ogni 5 minuti per IP
  caddy.rate_limit.zone.mysite_login.match.path: /login /wp-login.php
  caddy.rate_limit.zone.mysite_login.key: "{remote_host}"
  caddy.rate_limit.zone.mysite_login.events: 5
  caddy.rate_limit.zone.mysite_login.window: 5m
  caddy.rate_limit.zone.mysite_login.ipv6_prefix: 64

  caddy.rate_limit.log_key:
  caddy.rate_limit.jitter: 10

  caddy.reverse_proxy: "{{upstreams 8080}}"
```

Genera:
```caddyfile
mysite.example.com {
    rate_limit {
        zone mysite_general {
            key         {remote_host}
            events      60
            window      1m
            ipv6_prefix 64
        }
        zone mysite_login {
            match {
                path /login /wp-login.php
            }
            key         {remote_host}
            events      5
            window      5m
            ipv6_prefix 64
        }
        log_key
        jitter 10
    }
    reverse_proxy {{upstreams 8080}}
}
```

- `ipv6_prefix 64` raggruppa tutti gli indirizzi dello stesso `/64` in un
  unico contatore: un attaccante non può eludere il limite ruotando indirizzi
  IPv6 all'interno dello stesso prefisso.
- `log_key` scrive nei log quale chiave ha superato il limite (utile per
  debug/audit).
- `jitter 10` aggiunge il ±10% di variazione casuale al tempo di
  `Retry-After`, per evitare che tutti i client bloccati ritentino nello
  stesso istante ("thundering herd").

## Esempio avanzato 2 — rate limit per API key su un endpoint API

Limita le richieste in base a un header, non all'IP — utile per API
pubbliche con client autenticati via API key.

```yaml
labels:
  caddy: api.example.com
  caddy.rate_limit.zone.api_by_key.match.path: /api/*
  caddy.rate_limit.zone.api_by_key.key: "{http.request.header.X-Api-Key}"
  caddy.rate_limit.zone.api_by_key.events: 1000
  caddy.rate_limit.zone.api_by_key.window: 1h
  caddy.reverse_proxy: "{{upstreams 3000}}"
```

## Esempio avanzato 3 — combinato con caddy-security (`authorize`), ordine esplicito

Quando più direttive di terze parti (es. `authorize` + `rate_limit`)
convivono sullo stesso sito, meglio garantire l'ordine con un `route` e
prefissi numerati invece di affidarsi all'ordine di default — stesso pattern
già usato per CrowdSec/caddy-security in [README.md](README.md):

```yaml
labels:
  caddy: app.example.com
  caddy.route.0_authorize: with mypolicy
  caddy.route.1_rate_limit.zone.app_ip.key: "{remote_host}"
  caddy.route.1_rate_limit.zone.app_ip.events: 30
  caddy.route.1_rate_limit.zone.app_ip.window: 1m
  caddy.route.2_reverse_proxy: "{{upstreams 8080}}"
```

Genera:
```caddyfile
app.example.com {
    route {
        authorize with mypolicy
        rate_limit {
            zone app_ip {
                key    {remote_host}
                events 30
                window 1m
            }
        }
        reverse_proxy {{upstreams 8080}}
    }
}
```
Così il rate limit si applica *dopo* l'autenticazione (limita per utente
autenticato, non anonimo prima del login) — inverti l'ordine (`0_rate_limit`,
`1_authorize`) se vuoi invece limitare anche i tentativi di login non
autenticati.

---

## Testare un limite

```bash
for i in $(seq 1 25); do
  curl -s -o /dev/null -w "%{http_code}\n" https://mysite.example.com/login
done
```
Dopo aver superato `events` richieste dentro `window`, le risposte
diventano `429` con header `Retry-After` valorizzato.

## Rate limit distribuito (più repliche Caddy)

Non necessario con una singola istanza Caddy (il tuo caso attuale). Se in
futuro scali a più container Caddy dietro lo stesso storage, basta
aggiungere `distributed` alla zona per sincronizzare i contatori tra le
istanze:

```yaml
caddy.rate_limit.distributed:
```
