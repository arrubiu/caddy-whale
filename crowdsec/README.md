# CrowdSec

Protezione **globale a livello di server**, non legata ai singoli siti: il
Firewall Bouncer installato sull'host blocca gli IP malevoli a livello
iptables/nftables per **tutto** il traffico della macchina, prima ancora che
raggiunga Docker/Caddy. Non serve alcuna label o modifica ai docker-compose
dei singoli siti.

```
Internet
   │
   ▼
Firewall Bouncer (host, iptables/nftables) → blocca IP malevoli PRIMA di Docker
   │
   ▼
Caddy :80/:443
└── caddy-docker-proxy plugin  → routing via Docker label (invariato)
   │
   ▼ CrowdSec LAPI :8080 (127.0.0.1, non esposta su Internet)
├── agent locale → riceve le decisioni prese dagli scenari attivi
└── CAPI         → riceve blocklist dalla community CrowdSec
```

Il plugin `caddy-crowdsec-bouncer` è compilato nell'immagine Caddy (vedi
[caddy/Dockerfile](../caddy/Dockerfile)) ma **non è collegato a nulla per
default**: il blocco `crowdsec {}` nel [Caddyfile](../caddy/Caddyfile) resta
commentato e Caddy non dipende in alcun modo da CrowdSec per partire o
funzionare. È un'estensione opzionale per sito, descritta più sotto, non
necessaria per la protezione globale.

### Reti Docker

| Rete | Scopo |
|------|-------|
| `caddy` | Rete esistente — tutti i servizi proxiati si collegano qui |
| `crowdsec` | Rete interna, usata solo se in futuro si attiva il bouncer HTTP per sito (vedi sezione opzionale) |

### Volumi

| Volume | Contenuto |
|--------|-----------|
| `caddy_logs` | Log operativi Caddy (+ log di accesso HTTP solo se in futuro configurati per sito) |
| `crowdsec_data` | Database decisioni CrowdSec |
| `crowdsec_config` | Configurazione CrowdSec, parser, scenari |

---

## Attivazione (protezione globale)

Passi in ordine per attivare la protezione, incluso il collegamento alla
dashboard remota (CrowdSec Console).

1. **Crea le risorse Docker esterne** (se non già presenti):
   ```bash
   docker network create crowdsec
   docker volume create caddy_logs
   ```

2. **Avvia CrowdSec** e attendi che sia pronto:
   ```bash
   ./script.sh crowdsec up
   docker logs -f crowdsec   # aspetta "Starting processing data"
   ```

3. **Iscrivi l'istanza alla blocklist della community** (CAPI) — riceve
   automaticamente IP noti come scanner/botnet/malevoli:
   ```bash
   docker exec crowdsec cscli capi register
   docker restart crowdsec
   ```

4. **Installa il Firewall Bouncer sull'host** (non in Docker — Ubuntu/Debian):
   ```bash
   curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | sudo bash
   sudo apt install crowdsec-firewall-bouncer-iptables
   ```

5. **Registra il bouncer** e copia la API key generata:
   ```bash
   docker exec crowdsec cscli bouncers add firewall-bouncer
   ```

6. **Configura il bouncer** sull'host:
   ```bash
   sudo nano /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
   ```
   ```yaml
   api_url: http://127.0.0.1:8080
   api_key: <key copiata al passo 5>
   mode: iptables   # o nftables se preferisci
   ```

7. **Abilita e avvia il servizio**:
   ```bash
   sudo systemctl enable crowdsec-firewall-bouncer
   sudo systemctl start crowdsec-firewall-bouncer
   sudo systemctl status crowdsec-firewall-bouncer
   ```

8. **Verifica che il bouncer risulti connesso**:
   ```bash
   docker exec crowdsec cscli bouncers list   # controlla "last_pull" recente
   docker exec crowdsec cscli metrics
   ```

9. **Collega l'istanza alla dashboard remota (CrowdSec Console)**:
   1. Crea un account gratuito su [app.crowdsec.net](https://app.crowdsec.net) e genera una **enrollment key** (aggiungendo un nuovo "security engine").
   2. Esegui l'enroll dal container:
      ```bash
      docker exec crowdsec cscli console enroll -e <enrollment-key> --name "caddy-whale"
      docker restart crowdsec
      ```
   3. Torna su [app.crowdsec.net](https://app.crowdsec.net) e **approva/valida** la nuova istanza comparsa in dashboard.
   4. Da quel momento alert, decisioni e stato della macchina sono visibili e gestibili dalla Console web, oltre che da `cscli`.

10. **Test funzionale** (opzionale ma consigliato):
    ```bash
    ./script.sh crowdsec ban 1.2.3.4 "test"
    ./script.sh crowdsec decisions
    # verifica che l'IP risulti bloccato a livello di rete (iptables -L / nft list ruleset)
    ./script.sh crowdsec unban 1.2.3.4
    ```

Da qui in avanti la protezione è attiva per **tutto** il traffico verso il
server, senza alcuna modifica a Caddy, al Caddyfile o ai docker-compose dei
singoli siti.

---

## Comandi utili

Con [script.sh](../script.sh) dalla root del repository:

```bash
./script.sh crowdsec decisions            # Vedere i ban attivi
./script.sh crowdsec ban 1.2.3.4 "test"   # Bannare manualmente un IP
./script.sh crowdsec unban 1.2.3.4        # Rimuovere un ban
./script.sh crowdsec alerts               # Vedere gli alert rilevati
./script.sh crowdsec bouncers             # Stato dei bouncer registrati
./script.sh crowdsec metrics              # Metriche cscli
./script.sh crowdsec hub-update           # Aggiornare hub (parser/scenari/collezioni)
./script.sh crowdsec logs                 # Log CrowdSec
```

Equivalenti diretti (`cscli` gira dentro il container):

```bash
docker exec crowdsec cscli decisions list
docker exec crowdsec cscli decisions add --ip 1.2.3.4 --reason "test"
docker exec crowdsec cscli decisions delete --ip 1.2.3.4
docker exec crowdsec cscli alerts list
docker exec crowdsec cscli hub update
docker exec crowdsec cscli hub upgrade
docker exec crowdsec cscli bouncers list
docker logs crowdsec -f
```

---

## Estensioni opzionali (non attive per default)

Le due sezioni seguenti descrivono protezioni **per singolo sito**,
alternative/complementari al Firewall Bouncer globale. Non sono necessarie
per la protezione di base e vanno attivate solo se serve un controllo più
granulare su un sito specifico.

### Bouncer HTTP Caddy per sito

Oltre al Firewall Bouncer globale, è possibile far agire CrowdSec anche a
livello Caddy, bloccando la richiesta prima ancora che venga processata dal
sito. Richiede prima di riattivare il blocco `crowdsec {}` nel
[Caddyfile](../caddy/Caddyfile) e la rete/variabile in
[docker-compose.yml](../caddy/docker-compose.yml) (entrambi oggi commentati
con `TODO`).

Sul docker-compose del sito da proteggere:

```yaml
labels:
  # ... label esistenti invariate ...
  caddy.route.0_crowdsec:
```

Questo aggiunge `crowdsec` come primo handler nella route del sito. La
configurazione globale (URL LAPI, API key) resta nel `Caddyfile` base — il
sito si limita a dichiarare di usare il bouncer.

### Rilevamento locale via log HTTP

Per default CrowdSec usa solo le blocklist della community (CAPI). Per
rilevare attacchi localmente (brute force, scan, exploit) dal traffico HTTP
di un sito specifico, CrowdSec deve leggerne i log di accesso — cosa che
Caddy non produce per nessun sito a meno di non richiederlo esplicitamente.

Aggiungi queste label al docker-compose del sito da monitorare:

```yaml
labels:
  # ... label esistenti invariate ...
  caddy.log.output: "file /var/log/caddy/access.log {roll_size 50mb roll_keep 5}"
  caddy.log.format: json
```

I log vengono scritti nel volume `caddy_logs`, che CrowdSec legge in sola
lettura tramite [acquis.yaml](acquis.yaml).

---

## Note importanti

**Ordine di avvio**: CrowdSec deve essere avviato prima di installare/attivare
il Firewall Bouncer sull'host. Caddy invece è del tutto indipendente e può
partire prima, dopo o senza CrowdSec.

**Volume `caddy_logs`**: è `external: true` in entrambi i compose (caddy e
crowdsec). Deve esistere prima di avviare i container
(`docker volume create caddy_logs`).

**API key del Firewall Bouncer**: vive solo sull'host, in
`/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml` — non nel repository.
È sensibile: chiunque la possieda può interrogare e modificare le decisioni
della LAPI.

**Enrollment key della Console**: usala una sola volta per il comando
`cscli console enroll`; non ha bisogno di essere conservata dopo l'uso.

**Porta 8080**: la LAPI è esposta solo su `127.0.0.1:8080` per permettere al
firewall bouncer sull'host di connettersi senza esporla su Internet.

## Struttura file

```
crowdsec/
├── docker-compose.yml   # Servizio CrowdSec (LAPI + agent)
├── acquis.yaml           # Sorgenti log per CrowdSec
└── .env.example          # Template variabili (nessuna richiesta di default)
```
