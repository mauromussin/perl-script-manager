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
il gruppo `02-carica*.pl`, le due varianti `03-valida_tracce*` e
`04-valida_battute_1.0.pl` e gli script piste `05`/`06`; gli altri script
non descritti qui restano da inventariare.

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

## Gruppo 03-valida_tracce*

- Percorsi: `legacy/scripts/03-valida_tracce_01.pl` e
  `legacy/scripts/03-valida_tracce_01_bs.pl`.
- Stato: migrato nel comando `valida_tracce`; analisi del sorgente e test
  unitari con DB simulato, senza certificazione di equivalenza integrale
  ottenuta eseguendo i due legacy su MySQL.
- Scopo: valida tutte le tracce con `flay.validation_fl IS NULL`.
  Una traccia deve avere almeno 4 battute e almeno una battuta che soddisfi
  contemporaneamente distanza euclidea 2D dal centro aeroporto <=10000 m
  e quota `H_m <= QUOTA_aerop + 1000`. Le soglie sono inclusive; non e
  previsto un limite inferiore di quota.
- Avvio/input: interattivo, host (default localhost), database, codice
  aeroporto convertito in maiuscolo, utente e password visibile.
  `/help` stampa l'aiuto e termina con `die`.
- Dipendenze: DBI e MySQL; nessun processo esterno, file di input o
  variabile d'ambiente esplicitamente letta dal legacy.
- Tabelle: `flay`, `battute`, `anagrafica.aeroporti`. Il centro e la quota
  sono letti da `LONG_aerop`, `LAT_aerop`, `QUOTA_aerop`, cercando
  `nome_aerop` uguale al codice richiesto. Le battute usano `X_m`, `Y_M`, `H_m`.
- Varianti osservate:
  - `03-valida_tracce_01.pl`, revisione 2004-06-10 di Matteo Giampaolo:
    applica un offset Y di -376 m solo per LIME (Orio al Serio).
  - `03-valida_tracce_01_bs.pl`, revisione 2020-12-09 di Roberta Pollini
    per Montichiari: aggiunge l'offset Y di -2515 m per LIPO. Mantiene
    il ramo LIME ma non definisce `$offset_BGY`: non equivale quindi
    alla variante base per LIME. Gli altri aeroporti non hanno offset
    espliciti in questi script.
- Effetti: tracce valide -> `validation_fl='Y'`; non valide ->
  `validation_fl='N'` e tutte le rispettive battute -> `validation='A'`,
  sovrascrivendo eventuali stati precedenti. Non modifica `validation_bt`.
  Le classificazioni sono raccolte prima di eseguire gli UPDATE.
- Output: console e report in append
  `report\03-Valida_Tracce_01_<db>_<utente>_<data>_<ora>.log`;
  tracce scartate, tempi e conteggio per validation_fl limitato alle
  tracce con `validation_bt IS NULL`.
- Errori/rischi: SQL interpolato, credenziali interattive in chiaro,
  nessuna transazione esplicita o compensazione delle scritture parziali;
  aeroporto assente o coordinate NULL non controllati; apertura report
  non verificata; numero battute dedotto dal risultato di `execute`.
  La variante base stampa `$offset` invece di `$offset_BGY` nell'avviso
  iniziale. Il calcolo della durata usa solo l'ora e non gestisce mezzanotte.
  Errori DB generalmente terminano con `die`; nessun codice d'uscita
  esplicito, successo implicito se arriva in fondo. Durata tipica e
  consumo non misurati; una lettura delle battute e UPDATE per traccia.
- Modulo di destinazione: `ScriptManager::Command::ValidaTracce`.
  Parametri `database` e `airport`; credenziali server tramite `MYSQL_*`,
  scelte aeroporto da `MRT_CONFIG_FILE`/`config/local/MRT.json`.
  Il controllo attuale di `run` ammette solo LIME e LIPO, anche se lo
  schema espone altri aeroporti presenti in MRT.
- Note di migrazione: originali intatti; il comando riunisce gli offset
  LIME=-376 e LIPO=-2515, usa placeholder SQL, conta le righe lette,
  verifica la presenza dell'aeroporto e ordina le letture per row_id.
  Il riepilogo applicativo conta tutte le tracce con validation_fl non NULL,
  diversamente dal filtro legacy su validation_bt NULL; non rappresenta
  soltanto le tracce elaborate nella singola esecuzione.
- Verifiche: `t/unit/valida_tracce.t` copre catalogo, schema, casi di
  validazione e avanzamento su DB simulato; non esegue il codice legacy.
  Analisi 0-50%, salvataggio 50-99%, riepilogo 99%, concluso 100%
  dopo chiusura connessione. Esecuzione asincrona/esclusiva con AutoCommit:
  errori e annullamenti non annullano gli UPDATE gia eseguiti.

## 04-valida_battute_1.0.pl

- Percorso: `legacy/scripts/04-valida_battute_1.0.pl`; unica variante trovata.
- Stato: migrato in un comando del catalogo; test locali su fixture e DB
  simulato, senza validazione su un database MySQL operativo.
- Scopo verificato nel codice: elabora `flay` con `validation_fl='Y'` e
  `validation_bt IS NULL`, classifica le battute e completa `data_ora_arr`.
- Avvio/input: interattivo, host (default localhost), database, aeroporto,
  utente e password in chiaro; `/help` stampa l'aiuto e termina con `die`.
  L'aeroporto viene letto ma non utilizzato nell'algoritmo.
- Dipendenze: DBI e MySQL; nessun processo esterno o file di input.
  Nessuna variabile d'ambiente esplicitamente letta.
- Tabelle: `flay`, `battute`, temporanee `tempD`/`tempA`.
  Non accede ad `anagrafica.aeroporti`, nonostante l'intestazione.
- Regole osservate: taxi `T` se intervallo nullo o velocita 2D <28 m/s
  (anche su battute gia marcate); spezzatura `S` se intervallo >60 s,
  sulle candidate NULL ordinate per tempo crescente (D) o decrescente (A).
  Il resto usa velocita massima 500 m/s e coseno direzione minimo 0.5;
  distanza 3D se la quota corrente e positiva, altrimenti 2D.
  L'inizializzazione richiede una candidata seguita da quattro battute,
  non soltanto quattro battute totali.
- Esiti: nessuna valida -> traccia `D`, validation_bt=0; 1-3 valide ->
  battute `D` e traccia `D`, validation_bt=0; 4-7 -> battute `Y`, traccia `L`,
  validation_bt=1; almeno 8 -> battute `Y`, validation_fl invariato,
  validation_bt=1. Altri scarti geometrici sono `N`.
- Data/ora: completa solo date mancanti di tutte le tracce validation_bt=1,
  usando battute `Y`/`L`: MIN(time_italy) per D, MAX(time_italy) per A.
- Output: console e report Windows `report\04-valida_battute_1.0.pl_*.log`;
  conteggi locali e riepilogo globale per stato. Durata/consumo non misurati;
  cicli annidati per la prima battuta, letture e UPDATE per traccia.
- Rischi/errori: SQL interpolato, AutoCommit e nessun rollback, letture senza
  ORDER BY, `$prima_batt` globale non azzerata per traccia; operazioni non A/D
  riusano la query precedente; ciclo `for ($n=0, $n<=..., $n++)` malformato;
  prepare finale usa `$up_data_ora_arr` invece di `$up_data_ora_arr_str`.
  Errori DB provocano `die`; apertura report non controllata; nessun codice
  d'uscita esplicito, successo implicito se arriva in fondo.
- Decisioni di migrazione approvate: originale intatto; ordine row_id nelle
  letture prive di ordinamento; senza prima battuta valida tutte le candidate
  diventano N e la traccia D; operazioni diverse da A/D bloccate prima di scrivere.
  La prima battuta e locale alla traccia; valori numerici mancanti/non finiti
  e quote negative provocano errore, evitando coercizioni e distanze obsolete.
  Il prepare inutilizzato errato e eliminato; l'aggregazione delle date usa
  UPDATE con JOIN su una tabella derivata di sole battute, senza temporanee.
- Test di caratterizzazione: `t/unit/valida_battute.t` esegue il ciclo reale
  estratto dal sorgente con DB simulato, senza connessioni o dati operativi.
  Non costituisce esecuzione integrale del legacy ne certificazione MySQL reale.
- Modulo di destinazione: `ScriptManager::Command::ValidaBattute`.
- Integrazione: `valida_battute`, asincrono/esclusivo, parametro `database`,
  credenziali server. Analisi 0-50%, salvataggio 50-99% (UPDATE delle battute
  in gruppi di massimo 500 ID, tracce, date), riepilogo 99%, concluso 100%
  solo dopo chiusura connessione. AutoCommit mantiene i limiti del legacy:
  nessun rollback delle scritture parziali.

## Gruppo 05-trova_pista_atterraggi*

- Percorsi: `legacy/scripts/05-trova_pista_atterraggi_1.0.pl`, `_1.1.pl`, `_1.2.pl`.
- Stato: migrato nel comando asincrono `trova_pista_atterraggi`, con
  caratterizzazione dei rami originali e confronto su fixture isolate.
- Scopo/input: assegna piste agli atterraggi con `validation_bt=1` e
  `pista IS NULL`; usa solo battute `validation='Y'` ordinate per time_italy.
  Avvio interattivo: host (localhost se vuoto), database, aeroporto,
  utente/password in chiaro; `/help` stampa aiuto e termina con `die`.
- Varianti: 1.0 supporta LIMC/LIML/LIME e termina con errore per LIPO;
  1.1 aggiunge LIPO con offset Y=-2515 m; 1.2 rimuove l'offset LIME=-376 m
  presente in 1.0/1.1. L'algoritmo LIMC/LIML resta uguale.
- Regole: LIMC valuta le ultime due battute nel trapezio hardcoded e a
  quota <quota aeroporto+600 m, confrontando le distanze dalle rette EST
  e OVEST. Risultati 35R/17L (EST), 35L/17R (OVEST). Un solo tentativo
  aggiuntivo sulle due battute precedenti puo recuperare una traccia e
  marcare l'ultima battuta X. Errori N1/N2/NA, N9 con meno di due battute.
  LIML cerca all'indietro fino a 8 battute, distanza 120 m e quota +300 m,
  poi usa la variazione Y per 36R/18L. LIME/LIPO usano distanza 500 m,
  quota +2000 m e variazione X per 11/29 o 14/32.
- Particolarita verificate: la ricerca decrementa l'indice prima di
  valutare la direzione; dopo otto iterazioni non ricontrolla la distanza.
  Alcuni rami con indice -1 non assegnano `$pista`, lasciando dati precedenti.
- Tabelle: `flay`, `battute`, `anagrafica.aeroporti`, `anagrafica.piste`.
  Letture LONG_pista/LAT_pista e QUOTA_aerop. Nel legacy LIMC assume prime
  due righe EST e seconde due OVEST senza ORDER BY; LIML usa le prime due.
- Effetti: pista valida -> `flay.pista` e `sid` uguali alla pista; fallita ->
  pista diagnostica, `validation_fl='P'`, `validation_bt=0`; eventuale X su
  una battuta LIMC. Non modifica `data_ora_arr`.
- Output: console e report Windows in append `report\05pistaatterraggi-*.log`;
  riepilogo globale piste di tutti gli atterraggi con pista non NULL.
- Dipendenze/errori: DBI/MySQL, nessun file letto o processo esterno,
  nessuna variabile ambiente esplicita. SQL interpolato, report non
  controllato, AutoCommit senza rollback, errori DB/nessuna traccia tramite
  `die`, nessun exit code esplicito. Durata e risorse non misurate.
- Test: `t/unit/piste.t` esegue i rami originali con DB simulato, inclusi
  offset delle tre revisioni, direzioni EST/OVEST e recupero X; confronta
  gli esiti con la nuova geometria anche riordinando le righe anagrafiche.
  Verifica catalogo, placeholder, scritture, errori, annullamento e progresso.
  Nessuna scrittura operativa; equivalenza su dati reali non certificata.
- Integrazione: parametri `database`, `airport` e `revision` (`1.2` di
  default; selezionabili anche `1.0` e `1.1`). LIPO con 1.0 viene rifiutato
  prima della connessione. Credenziali da variabili server `MYSQL_*`.
  Log e risultato strutturato sostituiscono il report Windows; il riepilogo
  resta globale, con conteggi separati delle tracce della singola esecuzione.
- Decisioni approvate: estremi identificati tramite `nome_pista`;
  Malpensa EST=35R/17L e OVEST=35L/17R, Linate solo 36R/18L.
  Nessun riuso di variabili fra tracce: coppie mancanti restituiscono NA
  (resta N9 per LIMC), invalidando esplicitamente la traccia.
  Parita temporali risolte tramite row_id; nessuna traccia e un successo
  senza scritture, anziche un errore. Restano indice e limite di ricerca legacy.
- Limiti operativi: come nel legacy, nessun filtro aeroporto sulle tracce:
  il database deve corrispondere al contesto scelto. Analisi completa prima
  degli UPDATE; dati numerici non validi o geometria mancante/degenere
  interrompono prima delle scritture. Analisi 0-50%, salvataggio 50-99%,
  riepilogo 99%, concluso 100% dopo disconnect. AutoCommit senza rollback;
  esclusiva per singolo comando, non fra fasi diverse della pipeline.

## 06-trova_pista_decolli_1.1.pl

- Percorso: `legacy/scripts/06-trova_pista_decolli_1.1.pl`; unica variante.
- Stato: migrato nel comando asincrono `trova_pista_decolli`, con
  caratterizzazione dei rami originali e confronto su fixture isolate.
- Scopo/input: assegna piste ai decolli con `validation_bt=1` e pista NULL;
  usa battute Y ordinate per time_italy. Avvio/credenziali/help come 05.
- LIMC: prime due battute e distanza dalle rette EST/OVEST; prima battuta
  a distanza dal centro <12000 m e quota <quota aeroporto+2000 m.
  Include rettifiche hardcoded per partenze verso sud, codice N1 per
  battute perpendicolari nella regione definita e N2 quando tutte le
  battute residue sono nel poligono taxi (prevale sugli altri risultati).
- LIML: ricerca dalla prima battuta con distanza 120 m/quota +300 m;
  assegnazione con quota +2000 m e variazione Y, override 36R se entrambe
  le Y sono >5034500. LIME/LIPO: distanza 500 m, ricerca quota +450 m,
  assegnazione quota +800 m e variazione X. Offset LIME=-376 m, LIPO=0:
  non sono gli stessi della versione 1.2 di 05.
- Particolarita: il fetch avviene prima del controllo della distanza
  precedente, quindi la coppia usata puo essere successiva alla battuta
  vicina. Il confronto `@row2 eq ''` non rileva l'array vuoto: una battuta
  mancante puo essere trattata come coordinata zero. Variabili globali
  possono trattenere i valori della traccia precedente.
- Tabelle/dipendenze/rischi: come 05; inoltre legge LONG_aerop/LAT_aerop
  per la distanza dal centro LIMC. SQL interpolato e AutoCommit senza
  rollback; nessun processo esterno o input da file. Risorse non misurate.
- Effetti/output: pista valida -> aggiorna solo `pista`, NON `sid`; altrimenti
  pista diagnostica, `validation_fl='P'`, `validation_bt=0`. Console e
  `report\06pistadecolli-*.log`; riepilogo globale decolli con pista non NULL
  e sid NULL. Nessun exit code esplicito; errori tramite `die`.
- Test: `t/unit/piste.t`, rami originali su dati sintetici per i quattro
  aeroporti, inclusi direzioni EST/OVEST, rettifiche Malpensa,
  taxi/perpendicolare e il difetto della seconda battuta. Confronti della
  geometria migrata e test del comando su DB simulato; nessuna scrittura
  operativa o certificazione su un database reale.
- Integrazione: `database` e `airport`, revisione fissa 1.1; medesime
  associazioni per nome, ordinamento deterministico, controlli numerici,
  gestione input vuoto, progressione e limiti AutoCommit descritti per 05.
  Coppie insufficienti producono NA e invalidazione, mai coordinate zero
  o risultati ereditati. Mantiene gli offset specifici di 06 e il fetch
  anticipato legacy. Non aggiorna SID; conserva il filtro sid NULL solo
  nel riepilogo globale. Non filtra le tracce per aeroporto.
