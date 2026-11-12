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
