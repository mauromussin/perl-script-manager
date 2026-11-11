# Perl Script Manager

Applicazione web (Mojolicious + Minion + PostgreSQL) per l'esecuzione guidata di procedure Perl.
Specifica completa: [docs/ANALISI_APPLICAZIONE.md](docs/ANALISI_APPLICAZIONE.md).

## Avvio

```bash
cp .env.example .env          # sostituire password e segreto
docker compose run --rm app carton install   # genera cpanfile.snapshot (da versionare)
docker compose up --build     # app su http://127.0.0.1:3000, worker e database
```

Le credenziali del database nell'URL devono essere codificate (percent-encoding) se contengono caratteri speciali.

## Immagine costruita da GitHub Actions

Il workflow `build-image` (push su `main`) costruisce l'immagine, esegue i test, e la pubblica su GitHub Container Registry
(`ghcr.io/<owner>/<repo>-dev`; l'immagine `production` solo se `cpanfile.snapshot` è versionato).
Il `cpanfile.snapshot` generato è scaricabile dagli artifact del workflow: va copiato nella radice e committato.

Per usare l'immagine invece di costruirla in locale:

```bash
docker login ghcr.io          # utente GitHub + Personal Access Token con scope read:packages
# in .env: APP_IMAGE=ghcr.io/<owner>/<repo>-dev:latest
docker compose pull
docker compose up --no-build
```

## Test

```bash
docker compose --profile test run --rm test
```

I test di integrazione richiedono `TEST_ONLINE` (impostata dal servizio `test`); senza di essa vengono saltati.

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
