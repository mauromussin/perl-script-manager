# Istruzioni per GitHub Copilot

Riferimento completo: `docs/ANALISI_APPLICAZIONE.md` (in particolare la sezione 17). Regole essenziali:

- Leggere il documento di analisi prima di proporre modifiche architetturali.
- Analizzare i file reali prima di generare codice; non inventare il comportamento degli script legacy.
- Non modificare gli script in `legacy/scripts/` senza completare prima inventario e test di caratterizzazione.
- La logica sta in `lib/ScriptManager/`, mai in controller o template. Ogni comando implementa `run($ctx, $params)`.
- Nessuna shell con input controllabile dall'utente: usare `ScriptManager::Service::ProcessRunner` con argomenti in lista.
- Nessun segreto nei file versionati. SQL solo con placeholder.
- Nuove dipendenze solo se aggiunte a `cpanfile` e documentate.
- Ogni modifica include test (`t/`) quando applicabile. La suite completa si esegue localmente con `docker compose --profile test run --rm test`; GitHub Actions verifica solo configurazione Compose, build dell'immagine production e sintassi Perl.
- Distinguere comportamento verificato, dedotto e proposto; segnalare le assunzioni.
- Modifiche piccole, verificabili e reversibili.
