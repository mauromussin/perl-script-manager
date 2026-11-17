# Perl Script Manager

Applicazione web (Mojolicious + Minion + PostGIS) per l'esecuzione guidata di procedure Perl.
Specifica completa: [docs/ANALISI_APPLICAZIONE.md](docs/ANALISI_APPLICAZIONE.md).

## Avvio

```bash
cp .env.example .env          # impostare credenziali e segreto locali
docker compose pull app worker
docker compose up --no-build -d  # app su http://127.0.0.1:3080
```

Compose avvia l'immagine applicativa `production`, il worker e `postgis/postgis:16-3.4`.
Il servizio PostGIS usa `pull_policy: never`: l'immagine deve essere già disponibile
localmente e Compose non la scarica. Il database e i dati in `var/` sono conservati in
volumi Docker; il codice non viene montato nell'immagine di produzione.

`APP_POSTGRES_USER`, `APP_POSTGRES_PASSWORD`, `APP_POSTGRES_DB` e `SCRIPT_MANAGER_SECRET`
sono configurazioni locali obbligatorie. La porta database è pubblicata solo su
`127.0.0.1:5433`; l'app è disponibile su `127.0.0.1:3080` (porta container `3000`).
La password deve essere compatibile con una URL PostgreSQL oppure percent-encoded.

### Cartella delle tracce radar

Il mount di default e `E:\FILE_OUT` sull'host Windows, esposto in sola lettura
come `/app/var/input` sia ad app sia al worker (anche nei servizi di sviluppo).
La cartella host deve esistere; Compose non la crea automaticamente.
Per cambiarla impostare `FILE_OUT_ROOT` in `.env`.

Il parametro `folder` accetta `.` oppure una sottocartella relativa, per esempio
`2026/novembre`. Quest'ultima corrisponde a `E:\FILE_OUT\2026\novembre` sull'host
e `/app/var/input/2026/novembre` nel container. La ricerca non e ricorsiva.
L'esecuzione registra entrambi i percorsi completi nei log, anche se non trova
file, e riporta il percorso dei file individuati.

Dopo aver cambiato il mount, ricreare app e worker:

```powershell
docker compose up -d --no-build --pull never app worker
```

Questo comando usa un'immagine gia presente e aggiornata. Il codice production
non e montato: dopo modifiche al codice occorre prima aggiornare l'immagine.

```bash
docker compose logs -f app worker
docker compose down
```

## Immagine costruita da GitHub Actions

GitHub Actions controlla la configurazione Compose, costruisce il target `production` e
verifica la sintassi Perl contenuta nell'immagine. Non avvia database e non esegue `prove`.
Su push a `main` o a un tag `v*`, pubblica l'immagine runtime su
`docker.io/mauromussin/perl-script-manager` con tag `latest` (per `main`), il tag Git
(solo per push di tag `v*`) e `sha-<commit>`. Non pubblica piu su GHCR.

### Configurazione Docker Hub

Non serve collegare gli account GitHub e Docker Hub:

1. Creare su Docker Hub il repository `mauromussin/perl-script-manager`, pubblico per
   consentire il download senza autenticazione.
2. Creare un access token Docker Hub con permessi Read & Write, senza Delete.
3. In GitHub, aprire **Settings > Secrets and variables > Actions > New repository secret**
   e aggiungere `DOCKERHUB_USERNAME` (valore `mauromussin`) e `DOCKERHUB_TOKEN` (il token).
4. Fare push su `main` e verificare che lo step `Publish production image` termini con successo.

I token non devono essere salvati in `.env` o nei file versionati. Le pull request e
le esecuzioni manuali verificano l'immagine senza pubblicarla.

Per usare l'immagine invece di costruirla in locale:

```bash
# Solo se il repository Docker Hub e privato:
# docker login docker.io --username mauromussin
docker compose pull app worker
docker compose up -d --no-build
```

Compose usa `docker.io/mauromussin/perl-script-manager:latest` per app e worker.
`APP_IMAGE` permette di scegliere un altro riferimento completo, per esempio
`docker.io/mauromussin/perl-script-manager:sha-<commit>`, dopo la sua pubblicazione.
Se `.env` contiene ancora un riferimento GHCR in `APP_IMAGE`, rimuoverlo o aggiornarlo.
Per costruire invece un'immagine locale, impostare `APP_IMAGE=perl-script-manager:production`
e usare `docker compose up --build -d`.

### Deployment senza accesso ai registry o a CPAN

Ogni esecuzione riuscita del workflow rende disponibile per 7 giorni anche un artifact
`perl-script-manager-linux-amd64-<commit>`. Contiene l'immagine production completa,
esportata con `docker save`, e il relativo checksum SHA256. Non contiene `.env` o
credenziali locali. Non occorre costruire l'immagine sul PC aziendale: tutte le
dipendenze sono gia incluse. Anche un'esecuzione manuale produce l'artifact,
senza richiedere i secret Docker Hub e senza pubblicare sul registry.

In GitHub aprire **Actions > build-image > esecuzione riuscita > Artifacts**,
scaricare l'artifact ed estrarre lo ZIP. Il download richiede accesso a GitHub
e ai suoi endpoint di artifact: non e garantito che il proxy aziendale lo consenta.
Se necessario trasferire lo ZIP tramite un canale autorizzato.

Da PowerShell, nella cartella estratta, verificare il checksum e importare:

```powershell
$expected = ((Get-Content .\perl-script-manager.tar.sha256 -Raw).Trim() -split '\s+')[0]
$actual = (Get-FileHash .\perl-script-manager.tar -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw 'Checksum immagine non valido: non importare.' }
docker load -i .\perl-script-manager.tar
if ($LASTEXITCODE -ne 0) { throw 'Importazione immagine fallita.' }
```

Poi, nella cartella del repository, avviare senza build o download:

```powershell
$env:APP_IMAGE = 'perl-script-manager:production'
docker compose up -d --no-build --pull never app worker
docker compose ps
```

La variabile PowerShell prevale su un eventuale `APP_IMAGE` in `.env`; per renderla
persistente impostare `APP_IMAGE=perl-script-manager:production` in `.env`.
PostGIS deve essere gia presente localmente. L'app rimane su http://localhost:3080.
Il workflow verifica checksum, reimportazione e identita dell'immagine esportata;
non avvia servizi applicativi o database.

## Test locali

```bash
docker compose --profile test run --rm test
```

Il profilo locale `test` usa l'immagine di sviluppo e il servizio PostGIS già configurato.
La suite non fa parte delle verifiche GitHub Actions.

I test MyISAM reali sono opt-in: `TEST_MYSQL=1` crea e rimuove esclusivamente un
database dal nome univoco `sm_test_mysql_<pid>_<numero>` sul server configurato.
Non leggono i file radar reali e non scrivono nel database operativo.
L'account di test deve poter creare/eliminare questi database e usare tutti i
privilegi necessari nelle sole tabelle di test; `local_infile` deve essere attivo.

```powershell
$env:TEST_MYSQL = '1'
docker compose --profile test run --rm test prove -l -Ilib t/integration/carica_myisam.t
Remove-Item Env:\TEST_MYSQL
```

## Caricamenti MyISAM e gestione dei fallimenti

`flay`, `battute` e `battute_doppie` devono esistere ed essere tutte MyISAM oppure tutte InnoDB.
I motori misti non sono supportati. InnoDB mantiene la gestione transazionale;
MyISAM usa staging e compensazione, senza convertire le tabelle legacy.

### Record OUT con la stessa traccia

Come nel caricatore legacy LIN 2026, la chiave della traccia e
`(flay, data, ora)`. La prima occorrenza crea una traccia in `flay` e carica
le battute in `battute`. Le occorrenze successive riusano il suo `row_id` e
destinano tutte le proprie battute a `battute_doppie`, senza cambiare il
nome del volo, sostituire i metadati o unire automaticamente le osservazioni.
La regola vale nello stesso OUT, tra i file selezionati e per tracce gia
presenti nel database che hanno almeno una riga in `battute`.

**Eccezione: traccia esistente senza battute principali.** La prima occorrenza
valida nell'OUT riusa il `row_id` e inserisce le battute in `battute`, anche
se esistono righe in `battute_doppie`. In `flay` vengono completati soltanto
i campi NULL, vuoti o composti da spazi tra `aircraft`, `airport_dep`,
`airport_arr`, `flay_operation`, `data_ora_italy`, e soltanto se l'OUT fornisce
un valore non vuoto. Non vengono sovrascritti valori gia presenti, nemmeno
se diversi dall'OUT. Se non ci sono campi da completare non viene eseguito
alcun UPDATE dei metadati.
Chiave, ID e altri campi restano invariati, inclusi i flag di validazione
anche per tracce gia validate o marcate `M`. L'eventuale unione a mezzanotte
resta una fase separata con le sue regole; completare aeroporto e operazione
puo rendere una traccia non validata idonea al merge.
Le occorrenze successive nello stesso caricamento vanno in `battute_doppie`,
non riempiono nuovamente la tabella principale.

Il primo record dipende dall'ordine di lettura: file ordinati per percorso
e righe nell'ordine originale. I duplicati nello staging producono WARNING
con file completo, riga e chiave; quelli individuati nel database durante
la pubblicazione MyISAM producono un WARNING riepilogativo.
Il risultato contiene `tracks` (nuove tracce), `hits` (battute complessive),
`duplicate_tracks` (record associati a una traccia gia individuata) e
`duplicate_hits` (battute destinate a `battute_doppie`) e `repaired_tracks`
(tracce preesistenti che hanno ricevuto le prime battute principali).
I completamenti sono registrati a livello INFO con ID e campi aggiornati,
oppure con l'indicazione di metadati invariati, e riepilogati nell'esito.

Le righe con intestazione completa di 34 caratteri e terminatore LF/CRLF,
ma senza battute, vengono ignorate prima di inserire la traccia. Ogni scarto
produce un WARNING con percorso completo, riga, volo, data e ora. Il riepilogo
riporta il totale ignorato e il risultato espone `skipped_tracks`.
Se tutti i record sono di questo tipo, il caricamento termina con zero dati
caricati e i WARNING, senza eseguire il merge a mezzanotte. Un file veramente
vuoto resta invece un errore, cosi come intestazioni troncate, battute parziali
o righe prive del terminatore previsto.

`battute_doppie` deve accettare le stesse 13 colonne di caricamento di
`battute`; nello schema operativo verificato non ha il vincolo `u_battuta`.
Il caricatore non crea o modifica questa tabella. Record identici sono
comunque archiviati come occorrenze separate: **ripetere un caricamento gia
completato aggiunge altre battute in `battute_doppie`**, non e un'operazione
idempotente. Rimangono attivi i controlli del nuovo caricatore su input
malformati, battute ripetute nello stesso record e warning SQL; non viene
replicato il filtro legacy delle sole battute consecutive.
Come nel legacy, l'unione a mezzanotte sposta solo `battute`, non
`battute_doppie`, che conserva il riferimento alla traccia individuata.

Per MyISAM:

1. Un lock applicativo MySQL impedisce due caricamenti contemporanei sullo
   stesso database, anche da worker diversi.
2. Tutti i file OUT vengono letti e validati in tabelle di staging vuote,
   mantenendo anche i vincoli univoci delle tabelle originali. Le battute usano
   `LOAD DATA LOCAL INFILE` con una lista esplicita di colonne. Qualunque warning
   rifiuta il caricamento. In questa fase i dati live non vengono modificati.
3. La pubblicazione acquisisce `LOCK TABLES ... WRITE` sulle tre tabelle:
   gli altri client devono attendere. Gli identificatori vengono rimappati e
   gli intervalli e i conteggi delle nuove righe sono registrati prima delle
   scritture live. Sotto gli stessi lock vengono individuate le tracce gia
   presenti e la presenza di battute collegate: solo quelle gia provviste
   di battute vengono deviate nello staging delle doppie. Quelle prive di
   battute mantengono lo staging principale. Entrambe ricevono il `flay_id`
   esistente, senza inserire una nuova traccia.
4. Se richiesta, l'unione a mezzanotte mantiene il comportamento esistente,
   comprese le tracce preesistenti. Prima delle modifiche ne vengono salvati
   i record e le battute interessate, senza copiare tutto lo storico.
   Anche senza merge, i record `flay` da completare vengono salvati prima
   degli UPDATE; in caso di errore vengono ripristinati insieme ai flag.
5. Errori, timeout o annullamenti durante la pubblicazione attivano una
   compensazione sotto gli stessi lock: rimozione delle sole nuove righe per
   `row_id` e ripristino dei record preesistenti salvati. Non viene usato un
   falso rollback MyISAM. I contatori AUTO_INCREMENT non vengono riavvolti.

Le tabelle di lavoro persistenti hanno il prefisso riservato
`_sm_import_<UUID_senza_trattini>_` e i suffissi `flay`, `battute`,
`battute_doppie`, `track_map`, `undo_flay`, `undo_battute`, `state`.
La mappa collega gli ID di staging alle tracce preesistenti. Il journal `state`
contiene fase, intervalli di ID e conteggi (anche zero, se non ci sono nuove
righe per una tabella). Normalmente le tabelle di lavoro vengono
rimosse al termine. Se fallisce soltanto la pulizia dopo una pubblicazione
riuscita, l'esecuzione resta completata con un WARNING; la pulizia viene ripresa
al caricamento successivo, dopo verifica della presenza delle nuove righe.
Restano leggibili anche i journal della precedente versione a due tabelle.
Non tornare a quella versione lasciando journal della nuova versione pendenti:
non riconoscerebbe tutte le tabelle e gli intervalli di recupero.

L'account applicativo necessita di `SELECT, INSERT, UPDATE, DELETE, CREATE,
DROP, ALTER, LOCK TABLES, TRIGGER` sul database scelto. Non servono privilegi globali
amministrativi. Non sono consentiti trigger su `flay`, `battute` o `battute_doppie`: gli eventuali
effetti su altre tabelle non sarebbero compensabili. Il privilegio diretto
`TRIGGER` serve a renderli visibili nei metadati; senza di esso il controllo
potrebbe scambiare trigger nascosti per trigger assenti. Non e richiesto SUPER
e il caricatore non crea trigger. Schema e motori vengono
ricontrollati dopo l'acquisizione dei lock. La riconnessione automatica DBI e
disabilitata per non proseguire dopo la perdita dei lock.

### Arresti improvvisi e recupero

La compensazione non equivale a una transazione: arresti del worker, perdita
della connessione, errori durante la compensazione o crash del server possono
lasciare dati parziali. MyISAM non offre garanzie di crash recovery o durabilita
equivalenti a InnoDB, anche dopo una pubblicazione riconosciuta dal server.

Un journal `publishing` o `recovery_required`, un journal senza fase leggibile
o una pubblicazione dichiarata completa con righe mancanti blocca nuovi
caricamenti con `mysql_recovery_required` e livello CRITICAL. Journal e backup
vengono conservati. Uno staging `preparing` abbandonato e eliminabile senza
toccare i dati live, mentre un journal `recovered` indica un recupero confermato
dall'operatore.

Procedura operativa per il DBA:

1. Fermare i caricamenti e gli altri scrittori sul database, fare un backup e,
   in caso di crash MySQL, verificare prima l'integrita delle tabelle MyISAM.
2. Leggere il journal indicato nei log e confrontare staging, intervalli di ID,
   tabelle `undo_*` e dati live.
3. Ripristinare i dati sotto esclusione delle scritture. **Non cancellare
   alla cieca gli intervalli del journal**: dopo un arresto i lock sono persi
   e altri client potrebbero avere scritto negli stessi intervalli.
4. Solo dopo verifica del recupero, aggiornare a `recovered` la fase del
   journal specifico (`id = 1`).
5. Riprendere i caricamenti: l'applicazione elimina le sole tabelle di lavoro
   di quel journal e consente una nuova esecuzione.

Non eliminare manualmente journal/backup prima del recupero e non impostare
`published` per aggirare il blocco. L'applicazione non effettua recuperi
automatici ambigui dopo la perdita dei lock.

## Diagnosi delle esecuzioni fallite

La pagina dell'esecuzione e l'API riportano un codice errore e un messaggio.
Per il caricamento OUT, `out_files_missing` indica che non ci sono file `.OUT`
nella cartella selezionata (la ricerca non e ricorsiva). Verificare che
`FILE_OUT_ROOT` punti alla cartella host contenente i file, montata in
`/app/var/input` su app e worker, e che il parametro `folder` selezioni la
sottocartella corretta; `.` indica la radice. `out_folder_unavailable` indica una
cartella non disponibile, `invalid_out_folder` un percorso non consentito,
`invalid_out_file` un file fuori dalla radice e `invalid_out_filename` un nome
senza un unico codice ICAO configurato.

Gli errori imprevisti restano `internal_error`: i dettagli tecnici non sono
esposti nella pagina o nell'API. Consultare `docker compose logs app worker`
cercando l'identificatore dell'esecuzione; anche il log tecnico lo riporta.
Le esecuzioni gia concluse conservano il messaggio originale: i nuovi messaggi
si applicano alle esecuzioni successive all'aggiornamento di app e worker.

Gli errori di connessione MySQL riportano il codice diagnostico del server:
`mysql_authentication` indica credenziali rifiutate o un account non autorizzato
dal computer client, `mysql_database_access` permessi insufficienti sul database,
`mysql_database_missing` un database inesistente e `mysql_connect` altri problemi
di connessione. Un errore `Access denied` non dipende dal mount dei file OUT:
verificare `MYSQL_USER` e `MYSQL_PASSWORD` in `.env` e l'autorizzazione
dell'account sul server MySQL per l'host client. Preferire un account dedicato
con i soli permessi necessari invece di abilitare accessi remoti generici a root.
Dopo cambiamenti a `.env`, ricreare app e worker.

Per MyISAM, i record con chiave traccia ripetuta vengono gestiti in
`battute_doppie`, non sono di per se un errore `mysql_duplicate`. Quest'ultimo
indica un conflitto univoco non risolvibile con tale regola (per esempio un
ulteriore vincolo SQL sulle battute); `mysql_load_failed` indica un altro errore
di caricamento gestito senza mantenere le nuove righe. La causa tecnica e nei
log app/worker. `mysql_recovery_required` conserva journal/backup e blocca
nuovi caricamenti. `mysql_already_published` avverte che l'errore e avvenuto
dopo la pubblicazione: non rieseguire senza verifica.

### Livelli e dettaglio operativo

I log dell'esecuzione e quelli Docker distinguono `INFO`, `WARNING`, `ERROR`
e `CRITICAL` (l'API e il database conservano i codici in minuscolo).
`INFO` registra le operazioni principali: configurazione, ricerca/apertura e
chiusura file, connessione/verifiche MySQL, transazione, caricamento, unione a
mezzanotte, staging/pubblicazione o transazione, avanzamento e chiusura connessione. `WARNING` segnala anomalie,
`ERROR` un'operazione fallita e `CRITICAL` un errore imprevisto o un rollback
fallito o un recupero MyISAM necessario, che richiede verifica prima di riprovare. Credenziali MySQL omesse.

Per registrare anche ciascuna traccia e battuta, impostare
`SCRIPT_MANAGER_DEBUG_OPERATIONS=1` in `.env` e ricreare app e worker.
Il default e `0`; il dettaglio produce eventi `INFO` con metadata `detail: 1`
e puo generare molti messaggi e rallentare l'importazione.
In alternativa, senza override d'ambiente, usare `debug_operations: true` nella
configurazione applicativa. Il livello storico `debug` resta supportato.

## CLI

```bash
docker compose exec app perl bin/procedure list
docker compose exec app perl bin/procedure run example_echo --message ciao --repeat 3 --wait
docker compose exec app perl bin/procedure status <id-esecuzione>
```

## Struttura

| Percorso | Contenuto |
|---|---|
| `config/procedures.yml` | Catalogo delle procedure ammesse e schema dei parametri |
| `lib/ScriptManager/Command/` | Logica delle procedure: `run($self, $ctx, $params)` |
| `lib/ScriptManager/Service/` | Registro, esecuzione, contesto, `ProcessRunner` |
| `lib/ScriptManager/Repository/` | Accesso a PostgreSQL (solo placeholder SQL) |
| `lib/ScriptManager/Controller/` | Controller web e API JSON, senza logica applicativa |
| `migrations/` | Schema del database |
| `legacy/scripts/` | Script originali, da inventariare prima di ogni modifica |

## Aggiungere una procedura

1. Creare `lib/ScriptManager/Command/<Nome>.pm` con `run($self, $ctx, $params)` che restituisce `{success, message, data}`.
   Usare `$ctx->log`, `$ctx->progress`, `$ctx->check_cancel`, `$ctx->write_artifact`.
2. Registrarla in `config/procedures.yml` con schema dei parametri (JSON Schema), modalità `sync`/`async` e timeout.
3. Aggiungere i test in `t/`.

Parametri con `x-sensitive: true` non vengono salvati e richiedono `execution_mode: sync`.

## API

- `GET /api/procedures`
- `POST /api/procedures/<codice>/executions` (corpo JSON con i parametri)
- `GET /api/executions/<id>`

## Non ancora definito

Autenticazione e ruoli, caricamento file come parametro e selezione di risorse autorizzate
dipendono dalle decisioni aperte della sezione 20 del documento di analisi; fino ad allora l'utente è `anonymous`
e l'applicazione va esposta solo su `127.0.0.1`.
