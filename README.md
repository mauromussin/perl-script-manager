# Perl Script Manager

Applicazione web (Mojolicious + Minion + PostGIS) per l'esecuzione guidata di procedure Perl.
Specifica completa: [docs/ANALISI_APPLICAZIONE.md](docs/ANALISI_APPLICAZIONE.md).

## Avvio

```bash
cp .env.example .env          # impostare credenziali e segreto locali
docker compose up --build -d  # app su http://127.0.0.1:3000
```

Compose avvia l'immagine applicativa `production`, il worker e `postgis/postgis:16-3.4`.
Il servizio PostGIS usa `pull_policy: never`: l'immagine deve essere già disponibile
localmente e Compose non la scarica. Il database e i dati in `var/` sono conservati in
volumi Docker; il codice non viene montato nell'immagine di produzione.

`APP_POSTGRES_USER`, `APP_POSTGRES_PASSWORD`, `APP_POSTGRES_DB` e `SCRIPT_MANAGER_SECRET`
sono configurazioni locali obbligatorie. La porta database è pubblicata solo su
`127.0.0.1:5433`; l'app è disponibile su `127.0.0.1:3000`.
La password deve essere compatibile con una URL PostgreSQL oppure percent-encoded.

```bash
docker compose logs -f app worker
docker compose down
```

## Immagine costruita da GitHub Actions

GitHub Actions controlla la configurazione Compose, costruisce il target `production` e
verifica la sintassi Perl contenuta nell'immagine. Non avvia database e non esegue `prove`.
Su push a `main` o a un tag `v*`, pubblica l'immagine runtime su
`ghcr.io/<owner>/<repo>` con tag `latest` (per `main`), il tag Git e `sha-<commit>`.

Per usare l'immagine invece di costruirla in locale:

```bash
docker login ghcr.io          # utente GitHub + Personal Access Token con scope read:packages
# in .env: APP_IMAGE=ghcr.io/<owner>/<repo>:latest
docker compose up -d --no-build
```

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
