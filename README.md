# Caddy + CrowdSec

Reverse proxy Caddy con label-based routing e protezione CrowdSec.

## ⚠️ TODO: riattivare CrowdSec (modalità globale)

Al momento CrowdSec è **disattivato**: il plugin è compilato nell'immagine
Caddy (`Dockerfile`), ma non è collegato a nulla (blocco `crowdsec {}` nel
`Caddyfile` commentato, rete `crowdsec` e variabile `CROWDSEC_BOUNCER_API_KEY`
commentate in `docker-compose.yml`). Questo per poter avviare Caddy la prima
volta esattamente come si comportava prima (`docker-compose-old.yml`), senza
dipendenze da CrowdSec.

L'obiettivo è passare a CrowdSec **a livello di server** (protezione globale
via Firewall Bouncer sull'host, non solo bouncer HTTP per singolo sito). Step
da fare, in ordine:

1. **Decidere l'architettura definitiva**: far girare CrowdSec (LAPI) come
   servizio unico condiviso a livello di server, non legato al ciclo di vita
   di questo singolo stack Caddy (valutare se spostare
   `docker-compose.crowdsec.yml` fuori da questa directory o comunque
   trattarlo come componente "di sistema").
2. Creare le risorse esterne mancanti se non già presenti:
   ```bash
   docker network create crowdsec   # se non già fatto
   docker volume create caddy_logs  # se non già fatto
   ```
3. Avviare CrowdSec e attendere che sia pronto:
   ```bash
   docker compose -f docker-compose.crowdsec.yml up -d
   docker logs -f crowdsec   # aspetta "Starting processing data"
   ```
4. Registrare il bouncer HTTP di Caddy e copiare la API key generata:
   ```bash
   docker exec crowdsec cscli bouncers add caddy-bouncer
   ```
5. Configurare `.env` (copiare da `.env.example` se non esiste) con
   `CROWDSEC_BOUNCER_API_KEY=<key del passo 4>`.
6. Ricollegare Caddy a CrowdSec, decommentando:
   - in `docker-compose.yml`: la riga `- crowdsec` nella sezione `networks:`
     del servizio `caddy`, il blocco `crowdsec: / external: true` nella
     sezione `networks:` top-level, e la riga
     `- CROWDSEC_BOUNCER_API_KEY=${CROWDSEC_BOUNCER_API_KEY}` in `environment:`;
   - in `Caddyfile`: le righe `order crowdsec first` e l'intero blocco
     `crowdsec { ... }`.
7. Rebuild e riavvio di Caddy:
   ```bash
   docker compose up -d --build
   ```
8. Verificare che il bouncer risulti connesso:
   ```bash
   docker exec crowdsec cscli bouncers list   # controlla "last_pull" recente
   ```
9. **Modalità globale vera e propria**: installare il Firewall Bouncer
   sull'host (vedi sezione "Firewall Bouncer sull'host" più sotto) così la
   protezione copre a livello iptables/nftables tutto il traffico del
   server, non solo i siti con label Caddy esplicite.
10. (Opzionale, per sito) Attivare il rilevamento locale via log HTTP solo
    dove serve, aggiungendo le label `caddy.log.output` / `caddy.log.format`
    ai docker-compose dei singoli siti (vedi sezione dedicata più sotto).

## Architettura

```
Internet
   │
   ▼
Caddy :80/:443
├── caddy-docker-proxy plugin  → routing via Docker label (invariato)
└── caddy-crowdsec-bouncer     → blocco IP a livello HTTP (per nuovi siti)
   │
   ▼ interroga ogni 15s
CrowdSec LAPI :8080
├── agent locale → analizza i log di Caddy (quando configurati per sito)
└── CAPI         → riceve blocklist dalla community CrowdSec
   │
   ▼ (opzionale, installato sull'host)
Firewall Bouncer → regole iptables/nftables
                   blocca prima che il traffico raggiunga Caddy
```

### Reti Docker

| Rete | Scopo |
|------|-------|
| `caddy` | Rete esistente — tutti i servizi proxiati si collegano qui |
| `crowdsec` | Rete interna Caddy ↔ CrowdSec LAPI |

### Volumi

| Volume | Contenuto |
|--------|-----------|
| `caddy_data` | Certificati TLS, stato Caddy |
| `caddy_config` | Configurazione Caddy runtime |
| `caddy_logs` | Log operativi + log di accesso HTTP (se configurati per sito) |
| `crowdsec_data` | Database decisioni CrowdSec |
| `crowdsec_config` | Configurazione CrowdSec, parser, scenari |

---

## Setup iniziale

### 1. Crea reti e volumi

```bash
docker network create caddy
docker network create crowdsec
docker volume create caddy_logs
```

Il volume `caddy_logs` è dichiarato `external: true` in entrambi i compose
perché deve esistere prima di avviare qualsiasi servizio.

### 2. Build dell'immagine Caddy custom

```bash
docker compose build
```

xcaddy compila il binario Caddy con i plugin:
- `caddy-docker-proxy` — routing via Docker label
- `caddy-crowdsec-bouncer` — bouncer HTTP CrowdSec

La build richiede qualche minuto (compila in Go).

### 3. Avvia CrowdSec

```bash
docker compose -f docker-compose.crowdsec.yml up -d
```

Al primo avvio CrowdSec scarica la collection `crowdsecurity/caddy`
(parser + scenari). Attendi che sia pronto:

```bash
docker logs -f crowdsec
# Aspetta "Starting processing data"
```

### 4. Registra il bouncer HTTP di Caddy

```bash
docker exec crowdsec cscli bouncers add caddy-bouncer
```

L'output mostra la API key generata. Copiala.

### 5. Configura le variabili d'ambiente

```bash
cp .env.example .env
# Imposta CROWDSEC_BOUNCER_API_KEY=<key copiata al passo 4>
```

### 6. Avvia Caddy

```bash
docker compose up -d
```

### 7. Verifica

```bash
# Caddy risponde
curl -I http://localhost

# CrowdSec vede il bouncer connesso
docker exec crowdsec cscli bouncers list

# Decisioni attive (vuota all'inizio)
docker exec crowdsec cscli decisions list

# Metriche bouncer
docker exec crowdsec cscli metrics
```

---

## Come funziona la protezione

### Protezione immediata — siti esistenti, zero modifiche

Il bouncer **HTTP di Caddy agisce solo sui siti che hanno la label `crowdsec`
nella loro route** (vedi sezione successiva). I siti esistenti non vengono
toccati.

Per bloccare IP su tutti i siti senza modificare i compose esistenti,
usa il **Firewall Bouncer** sull'host (vedi sotto): opera a livello iptables
prima che il traffico raggiunga Docker.

### Blocklist dalla community (CrowdSec CAPI)

CrowdSec condivide IP malevoli con la community. Per iscriversi:

```bash
docker exec crowdsec cscli capi register
docker restart crowdsec
```

Dopo la registrazione, CrowdSec riceve automaticamente blocklist di IP
noti come scanner, botnet, ecc. Il firewall bouncer sull'host applica
queste decisioni a livello di rete.

---

## Firewall Bouncer sull'host (raccomandato per protezione globale)

Blocca gli IP a livello iptables/nftables **prima** che raggiungano Caddy.
Non richiede modifiche ai compose dei siti esistenti.

La LAPI è esposta su `127.0.0.1:8080` (non raggiungibile dall'esterno).

### Installazione su Ubuntu/Debian

```bash
curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | sudo bash
sudo apt install crowdsec-firewall-bouncer-iptables
```

### Registra il bouncer

```bash
docker exec crowdsec cscli bouncers add firewall-bouncer
# Copia la key generata
```

### Configura il bouncer

```bash
sudo nano /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
```

Modifica:
```yaml
api_url: http://127.0.0.1:8080
api_key: <key copiata sopra>
mode: iptables  # o nftables se preferisci
```

```bash
sudo systemctl enable crowdsec-firewall-bouncer
sudo systemctl start crowdsec-firewall-bouncer
sudo systemctl status crowdsec-firewall-bouncer
```

---

## Bouncer HTTP Caddy — attivazione per sito (opzionale)

Il bouncer HTTP agisce a livello Caddy e blocca prima che la richiesta
venga processata. Va abilitato esplicitamente su ogni sito tramite label.

Aggiungere al docker-compose del sito:

```yaml
labels:
  # ... label esistenti invariate ...
  caddy.route.0: crowdsec
```

Questo aggiunge `crowdsec` come primo handler nella route del sito.
La configurazione globale (URL LAPI, API key) è già nel `Caddyfile`
base — il sito si limita a dichiarare di usare il bouncer.

---

## Attivare il rilevamento locale via log HTTP

Per default, CrowdSec usa le blocklist della community. Per rilevare
attacchi localmente (brute force, scan, exploit) dal traffico HTTP,
CrowdSec deve leggere i log di accesso di Caddy.

Aggiungi queste label al docker-compose di ogni sito che vuoi monitorare:

```yaml
labels:
  # ... label esistenti invariate ...
  caddy.log.output: "file /var/log/caddy/access.log {roll_size 50mb roll_keep 5}"
  caddy.log.format: json
```

I log vengono scritti nel volume `caddy_logs`, che CrowdSec legge in
sola lettura tramite `crowdsec/acquis.yaml`.

---

## Comandi utili

```bash
# Vedere i ban attivi
docker exec crowdsec cscli decisions list

# Bannare manualmente un IP
docker exec crowdsec cscli decisions add --ip 1.2.3.4 --reason "test"

# Rimuovere un ban
docker exec crowdsec cscli decisions delete --ip 1.2.3.4

# Vedere gli alert rilevati
docker exec crowdsec cscli alerts list

# Aggiornare hub (parser, scenari, collezioni)
docker exec crowdsec cscli hub update
docker exec crowdsec cscli hub upgrade

# Stato bouncers
docker exec crowdsec cscli bouncers list

# Log CrowdSec
docker logs crowdsec -f

# Log Caddy
docker logs caddy -f
```

---

## Aggiornare l'immagine Caddy

Per aggiornare Caddy o i plugin:

```bash
docker compose build --no-cache
docker compose up -d
```

---

## Struttura file

```
caddy/
├── Dockerfile                    # Build xcaddy con i plugin
├── Caddyfile                     # Config globale (crowdsec + log)
├── docker-compose.yml            # Caddy
├── docker-compose.crowdsec.yml   # CrowdSec LAPI
├── .env                          # API key (non committare)
├── .env.example                  # Template variabili
└── crowdsec/
    └── acquis.yaml               # Sorgenti log per CrowdSec
```

---

## Note importanti

**Ordine di avvio**: CrowdSec deve essere avviato prima di Caddy.
Se Caddy parte senza LAPI disponibile, continua a servire traffico
normalmente (nessun blocco) e si riconnette quando CrowdSec è pronto.

**Volume `caddy_logs`**: è `external: true` in entrambi i compose.
Deve esistere prima di avviare i container (`docker volume create caddy_logs`).

**API key**: non committare `.env` nel repository. La key è sensibile —
chiunque la possieda può interrogare e modificare le decisioni della LAPI.

**Port 8080**: la LAPI è esposta solo su `127.0.0.1:8080` per permettere
al firewall bouncer sull'host di connettersi senza esporla su Internet.
