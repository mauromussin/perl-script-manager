# Inventario degli script legacy

Per ogni file in `legacy/scripts/` aggiungere una sezione con lo schema seguente, basandosi
esclusivamente sul codice reale (vedi `docs/ANALISI_APPLICAZIONE.md`, sezione 7).

```markdown
## Nome dello script

- Percorso:
- Scopo:
- Stato: da analizzare | analizzato | in migrazione | migrato | dismesso
- Modalità di avvio:
- Parametri CLI:
- Input:
- Output:
- File letti:
- File scritti:
- Database utilizzati:
- Tabelle utilizzate:
- Variabili d'ambiente:
- Moduli Perl richiesti:
- Programmi esterni:
- Durata tipica:
- Codici di uscita:
- Effetti collaterali:
- Gestione degli errori:
- Rischi individuati:
- Test di caratterizzazione:
- Modulo di destinazione:
- Note di migrazione:
```

L'inventario iniziale di acquisizione è in `legacy/README.md`. L'analisi seguente copre
soltanto il gruppo `02-carica*.pl`; gli altri script restano da analizzare.

## Gruppo 02-carica*

- Stato: analisi statica completata; test di caratterizzazione non eseguiti.
- Scopo comune: legge record radar ENAV da file `.out`, inserisce le tracce in `flay`
	e le battute in `battute`; le varianti con doppie separate usano anche
	`battute_doppie`.
- Modalità di avvio comune: interattiva; richiede database, directory, utente,
	password e codice aeroporto. Connessione DBI MySQL a `localhost`.
- Parsing comune osservato: intestazione di 34 caratteri; battute da 24 caratteri
	a partire dall'offset 34; coordinate trasformate con divisore 64 e fattore
	1852.2; altitudine convertita da centinaia di piedi in metri.
- Flusso comune osservato: unione delle tracce spezzate a cavallo della mezzanotte.
- Versione base scelta: `lin_2026`, la variante LIN più recente con il flusso completo
	a tre tabelle. È un riferimento per i parametri condivisi, non una prova di
	equivalenza funzionale delle altre varianti.
- Configurazione dei profili: `config/02-carica-variants.yml`.

| Profilo | File | Origine radar indicata | Origine coordinate X / Y (m) | Gestione tracce duplicate |
|---|---|---|---:|---|
| `lin_2017` | `02-carica_DB_2.0 (LIN dal 25102017).pl` | LIN | 1521961.05 / 5034234.14 | Tabella `battute_doppie` |
| `lin_2024` | `02-carica_DB_2.0 (LIN dal 2024).pl` | LIN | 1522032.947 / 5034120.016 | Tabella `battute_doppie`; intestazione descrive gli offset come test |
| `lin_2025` | `02-carica_DB_2.0 (LIN dal 2025).PL` | LIN | 1521935.012 / 5034308.734 | Tabella `battute_doppie` |
| `lin_2026` | `02-carica_DB_2.0 (LIN dal 2026).PL` | LIN | 1521934.03 / 5034214.34 | Tabella `battute_doppie`; revisione intestazione 2026-02-02 |
| `orio_radar_lin` | `02-carica_DB_2.0 (ORIO_da_RADAR_LIN).pl` | Radar LIN | 1520711.5 / 5034234.15 | Nessuna tabella separata; riusa la traccia esistente e continua a scrivere in `battute` |
| `orio_dbltrk` | `02-carica_DB_2.0_ORIO_dbltrk.pl` | ORIO | 1555262.5 / 5057915.15 | Tabella `battute_doppie` |
| `orio_dbltrk_new_radar` | `02-carica_DB_2.0_ORIO_dbltrk_new_radar.pl` | ORIO, nuovo radar | 1555460 / 5057920 | Tabella `battute_doppie`; caricamento scritto in una catena `||`, perciò il secondo `LOAD DATA` è condizionato all'errore del primo |
| `mxp_dbltrk_2015` | `02-carica_DB_2.0MXP_dbltrk_da_06032015.pl` | MXP | 1521977.2 / 5034034.23 | Tabella `battute_doppie` |
| `vbs_dbltrk` | `02-carica_DB_2.0_VBS_dbltrk.pl` | VBS | 1688581.27 / 5025286.91 | Tabella `battute_doppie` |
| `vbs_radar_lin_dbltrk` | `02-carica_DB_2.0_VBS_da_RADAR_LIN_dbltrk.pl` | Radar LIN | 1521961.5 / 5034514.15 | Tabella `battute_doppie` |

Le coordinate sono i termini additivi effettivi nelle formule di `fBattuta`; non
certificano il sistema geodetico o la validità temporale. Le altre differenze
visibili sono intestazioni, nomi dei report e formattazione. Non è stato eseguito
alcuno script né verificato alcun effetto su database: i profili non sono ancora
procedure eseguibili dell'applicazione.
