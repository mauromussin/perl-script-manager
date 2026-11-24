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
`04-valida_battute_1.0.pl`, gli script piste `05`/`06` e il gruppo SID `07`;
gli altri script
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
- Nell'integrazione applicativa, dopo un timeout effettivo si puo confermare
  una nuova 02 senza timeout, con stessi parametri e coda. Prima verificare
  log, recupero e database: un import gia pubblicato non e idempotente.
  Errori di recupero o dati gia pubblicati non abilitano l'override.
  Per InnoDB il timer e disattivato prima del commit anche senza override.

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
  Parametri `database` e `airport`, piu intervallo/sovrascrittura comuni a 03-08;
  credenziali server tramite `MYSQL_*`,
  scelte aeroporto da `MRT_CONFIG_FILE`/`config/local/MRT.json`.
  Il controllo attuale di `run` ammette solo LIME e LIPO, anche se lo
  schema espone altri aeroporti presenti in MRT.
- Note di migrazione: originali intatti; il comando riunisce gli offset
  LIME=-376 e LIPO=-2515, usa placeholder SQL, conta le righe lette,
  verifica la presenza dell'aeroporto e ordina le letture per row_id.
  Il riepilogo applicativo conta le tracce con validation_fl non NULL nei
  giorni selezionati e non saltati,
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
  intervallo/sovrascrittura comuni a 03-08, credenziali server.
  Completamento date e riepilogo sono limitati ai giorni selezionati non
  saltati, diversamente dal riepilogo globale legacy.
  Analisi 0-50%, salvataggio 50-99% (UPDATE delle battute
  in gruppi di massimo 500 ID, tracce, date), riepilogo 99%, concluso 100%
  solo dopo chiusura connessione. AutoCommit mantiene i limiti del legacy:
  nessun rollback delle scritture parziali.
- Ottimizzazione reset 04 con Sovrascrivi: selezione delle sole tracce
  ammesse nei giorni elaborati, poi un unico UPDATE per lotto di massimo
  500 flay_id azzera A_m/Z_m/hmod/validation. Usa gli indici esistenti
  su battute.flay_id anziche tre UPDATE JOIN con possibile scansione completa;
  battute gia tutte NULL non riscritte. H_m, scope e filtri invariati.
  Dettaglio del lotto corrente al 50%, cancellazione verificata fra lotti;
  reset stati/date/pista/SID successivo, sempre senza rollback.
  Test unitario dei lotti e confronto dei risultati MyISAM su 501 tracce
  con esclusioni, date limite e battute fuori giorno in
  t/unit/validation_window.t e t/integration/validation_window.t.
- Controllo preventivo aggiunto a 04: prima di reset/scritture, conteggio
  delle battute nello scope effettivo e campionamento dell'algoritmo reale
  per operazione A/D e numerosita (minimo, mediana, massimo del gruppo).
  Salvataggio stimato dalle ultime dieci esecuzioni con misure dello stesso
  database entro 90 giorni, anche progressi legacy/parziali con delta >=10
  operazioni. Tempi piu prudenziali, margine 2x e secondo controllo prima
  del salvataggio sul numero esatto di UPDATE pianificati.
  Stima >timeout: errore timeout_estimate, senza scritture radar ne
  invalidazioni; il dettaglio propone conferma esplicita per una nuova
  richiesta senza timeout, con stessi parametri in fondo alla coda.
  Checkbox non preselezionata, POST protetto CSRF e verifica server-side
  della 04 rifiutata. Solo la richiesta confermata disattiva sia il blocco
  della stima sia l'allarme di timeout reale; stime e avvisi ancora registrati.
  Lock, cancellazione e controlli dati restano attivi. Scelta persistita in
  executions.timeout_bypassed (migrazione PostgreSQL 6, default false) e
  conferma con origine tracciata nei log. Un normale Riesegui non la eredita.
  Storico insufficiente: errore timeout_estimate_unavailable, senza scritture
  radar ne invalidazioni e senza conferma/bypass; occorre una calibrazione
  verificata separata. Nessun aumento automatico del timeout.
  L'intervallo gia interamente saltato non richiede stima. Quando attivo,
  il timeout include il preflight, non l'attesa in coda; stima euristica, non garanzia.
  I nuovi salvataggi registrano misure strutturate anche in caso di
  interruzione, se sono state completate almeno dieci operazioni.
  Progressione resta 0 durante il preflight, poi segue lo schema esistente.
  Test: t/unit/battute_preflight.t e t/integration/validation_window.t,
  con rifiuti prima di reset e storico invariato su MyISAM temporaneo;
  t/integration/execution_service.t e t/integration/web.t verificano
  conferma/CSRF, parametri immutati, coda, persistenza e superamento reale
  del timeout configurato, senza perdere la cancellazione.

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
  include solo i giorni selezionati non saltati, con conteggi separati
  delle tracce della singola esecuzione.
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
  blocco condiviso 03-08 sullo stesso server/porta/database.

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
  nel riepilogo, ora limitato ai giorni selezionati non saltati.
  Non filtra le tracce per aeroporto.

## Gruppo 07-assegna_sid*

- Varianti trovate: 2.1, 2.2 base, dal_2014, dal_2015, dal_2015_corr,
  corr+lipo, orio_sid044, corr_sperimMXP2024 e corr_MXP_da12giu2025.
  La variante MXP 2025 dichiara revisione 14/07/2025 (CAM/SUD); `corr`
  ha modifica filesystem 20/05/2026 ma mantiene le regole precedenti.
  Per scelta esplicita dell'utente, riferimento della migrazione:
  `legacy/scripts/07-assegna_sid_2.2_dal_2015_corr.pl`.
- Stato: migrato in `ScriptManager::Command::AssegnaSID`, comando
  asincrono/esclusivo `assegna_sid`, geometria in `ScriptManager::Service::SIDGeometry`.
  LIMC/LIML/LIME implementati; LIPO termina con errore. Non si combinano
  regole delle altre varianti (LIPO e CAM/SUD restano esclusi).
- Input legacy: host, database, aeroporto, date iniziale/finale, utente
  e password in chiaro; accesso DBI/MySQL, nessun processo esterno.
  Seleziona decolli, validation_bt>0, pista non NULL e sid NULL,
  intervallo inclusivo su `data_ora_arr` (campo confermato dall'utente).
  Non filtra le tracce per aeroporto: database relativo al contesto scelto.
- Algoritmo: legge solo battute Y senza ORDER BY e salta la prima.
  Cerca la prima battuta che soddisfa una regione SID, nell'ordine dei
  test originali. Quote assolute e bordi strettamente esclusi.
  LIMC: 070/071/358 per 35R; 280/310/320 per 35L; 294/038 per 17L/17R,
  quota <3000 m; fallback 168 sulle piste sud, NA altrove.
  LIML: SRN5C/NIKMO/TZO5C/DORIN/PIKOT per 36R, PIA5D/SSUD per 18L,
  quota <3500 m. LIME: 267/220/044 per 29 a quota <3500 m; 150 per 11
  senza condizioni geometriche, pur richiedendo una seconda battuta Y.
- Effetti: aggiorna solo `flay.sid`, senza invalidare tracce o battute.
  Il fallback globale NA usa bt=1 e pista non NULL, senza filtro su
  operazione o date: puo modificare righe estranee alla selezione.
  Esiti non trovati con bt>1 rimangono NULL per LIML/LIME.
  Riepilogo globale decolli bt=1; log Windows in append, apertura non
  verificata. AutoCommit senza rollback; errori DB/nessuna traccia con die.
- Difetti: denominatore della retta BC della SID 220 usa `$B220D[0]`
  mai definito (coercizione a zero); altre variabili inesistenti sono
  usate solo nelle stampe. SQL interpolato, ordinamento non deterministico.
  Durata e consumo non misurati; una lettura delle battute per traccia.
- Decisioni approvate: correggere B220D in B220, ordinare per time_italy e
  row_id, limitare tutte le scritture/report ai decolli dei giorni scelti;
  mantenere intervallo su data_ora_arr, skip giornaliero e sovrascrittura.
  Test di caratterizzazione in `t/unit/assegna_sid.t`, DB simulato,
  nessuna scrittura operativa; correzione geometrica confrontata a parte.
- Integrazione verificata: database/aeroporto e controlli comuni date,
  skip e overwrite, con riferimento a `data_ora_arr`. Sovrascrittura
  limitata alla SID dei decolli bt>0 con pista; nessun reset di pista,
  validazioni, date o battute. Analisi completa prima degli UPDATE;
  numerici mancanti/non finiti producono errore prima delle scritture.
  Nessuna traccia e un successo senza modifiche, non un die.
  Analisi 0-50%, salvataggio 50-99%, riepilogo 99%, concluso 100%
  dopo disconnect e registrazione dello storico. AutoCommit senza rollback.
- Confronti eseguiti: tutte le 18 regioni, soglie di quota incluse/escluse,
  prima battuta saltata, precedenza temporale, fallback 168/NA/NULL e
  caso discriminante per la correzione SID 220. Il centro dei vertici
  PIA5D non e interno alle semirette legacy: preservate senza riordinarle.
  Test runtime per scritture solo SID, errori, annullamento e progresso.
- `t/integration/validation_window.t`: database MyISAM temporaneo e
  schemi PostgreSQL dedicati, poi rimossi; date su data_ora_arr differenti
  da data_ora_italy, limiti inclusivi, righe esterne/arrivi/M intatti,
  ordinamento cronologico, SID esistenti, skip, overwrite e dipendenze.
  Nessuna certificazione su tracce operative.

## 08-rettifica_quote_nulle_1.1.pl

- Varianti trovate: una sola, revisione 1.1; intestazione con revisioni
  29/11/2005 e 22/02/2007. Nessuna modifica allo script originale.
- Input legacy: host (default localhost), database, aeroporto convertito
  in maiuscolo ma mai usato, utente/password in chiaro; `/help`.
  Dipendenza DBI/MySQL, nessuna variabile d'ambiente o processo esterno.
- Selezione verificata: flay con `validation_bt=1` e pista non NULL,
  **senza filtro A/D**, nonostante il commento parli di decolli.
  Nessun intervallo temporale e nessun filtro aeroporto.
  Battute della traccia con validation diversa da N/A/S: SQL esclude
  anche NULL, include Y/X/T/L. Nessun ORDER BY. Meno di tre battute:
  next senza avanzamento dello stato.
- Algoritmo verificato: per H_m=0 e hmod diverso da M interpola in base
  alle distanze euclidee XY, usando H_m originali non zero, mai Z_m;
  estrapola prima/ultima battuta da due ancore, tronca le quote negative
  a zero. hmod M non rielaborato. Il codice non copia le quote H_m non zero
  in Z_m, contrariamente all'help che lo dichiara.
- Effetti: UPDATE Z_m/hmod=M per le battute corrette, poi validation_bt=2
  per la traccia anche quando non corregge alcuna quota. Non modifica
  H_m, pista, SID, coordinate o classificazione battute.
  Report Windows in append, apertura non verificata; stampa tracce e
  conteggio quote corrette. AutoCommit senza rollback; errori DB con die.
  Durata e memoria non misurate; tutte le battute di una traccia in memoria.
- Difetti verificati/caratterizzati: ultimo punto escluso dalla ricerca
  dell'ancora successiva interna (`100,0,300` produce erroneamente 0);
  controlli di tutte-zero irraggiungibili nei rami senza ancore, con
  generazione di UPDATE senza quota; variabili globali non azzerate tra
  punti/tracce possono riciclare distanze/quote. SQL interpolato, ordinamento
  implicito, tabella FLAY maiuscola nell'UPDATE (rischio case-sensitive).
- Decisioni esplicite dell'utente: arrivi e decolli, intervallo su
  `data_ora_italy`; ordinamento `time_italy,row_id`; includere l'ultima
  ancora; ancore non zero piu vicine, estrapolazione anche per sequenze
  di zeri iniziali/finali; una sola ancora -> quota costante; nessuna
  ancora -> avviso e nessuna rettifica. Copiare anche H_m non zero in
  Z_m, come l'help. Distanza nulla -> quota dell'ancora con avviso.
- Migrazione: `ScriptManager::Command::RettificaQuote`, codice
  `rettifica_quote`, asincrono/esclusivo, timeout 3600 secondi.
  Database e controlli comuni date/skip/overwrite; nessun aeroporto
  richiesto. Mantiene filtro validation e minimo tre battute.
  Numerici mancanti/non finiti rifiutati prima di scrivere.
  Analisi completa prima dei reset; SQL con placeholder.
  Quote originali copiate con hmod NULL; interpolate con M; tracce
  rettificabili avanzano a bt=2 solo dopo le rispettive scritture.
  Riepilogo persistente al posto del file legacy.
- Preflight: campiona l'analisi e usa misure 08 dello stesso target, con
  margine 2x e ulteriore controllo prima delle scritture. Stima euristica,
  non garanzia; misure legacy possono sovrastimare dopo l'ottimizzazione.
  Stima oltre timeout o storico insufficiente: nessuna scrittura radar,
  conferma esplicita per nuova richiesta in coda senza timeout; nel secondo
  caso durata non stimabile. La 04 mantiene il blocco se manca lo storico.
- Prestazioni: reset overwrite e UPDATE delle quote raggruppati; nessun
  inserimento di righe. AutoCommit invariato: interruzioni possono lasciare
  risultati parziali per lotto. Nessun tempo operativo misurato garantito.
  Disponibile solo dopo deploy coordinato di app e worker.
- Overwrite: include bt=1/2/3 con pista, ricalcola da H_m ignorando
  hmod M; azzera solo Z_m/hmod delle battute ammesse, non N/A/S/NULL.
  Azzera anche A_m delle tracce interessate e invalida lo storico 10.
  Tracce tutte-zero o con meno di tre battute sono
  segnalate senza avanzamento; l'esecuzione puo completarsi con avvisi
  e registra i giorni: dopo correzioni manuali richiedere overwrite.
  Non ricalcola SID/pista o coordinate.
- Dipendenze: condivide blocco target con 03-10; 03-06 invalidano lo
  storico 08 sulle date locali, i loro overwrite eliminano Z_m/hmod
  obsoleti. 05/06 overwrite accettano bt=2/3 e ripristinano bt=1.
  07 usa H_m e modifica solo SID: nessuna invalidazione reciproca con 08.
- Verifiche: `t/unit/rettifica_quote.t` estrae ed esegue il ciclo
  originale con DB simulato, confronta i casi definiti e separa le
  correzioni approvate; testa estremi, zeri consecutivi, ancore mancanti,
  distanze nulle, hmod M, copia quote, errori, annullamento e progresso.
  `t/integration/validation_window.t` usa database temporanei MyISAM e
  PostgreSQL per date, filtri, ordinamento, skip, overwrite, stati,
  dipendenze, errori prima/dopo reset e form web. Nessuna scrittura
  operativa o nuova dipendenza.

## Gruppo 09-carica_dati_meteo*

- Varianti: 1.3, 1.4, 1.5, 1.6. Revisione 1.4 del 01/09/2008;
  1.5 dichiara Ferno 07/09/2020 e LIPO 06/04/2021; 1.6 non riporta la
  seconda data, ma contiene un ramo LIPO separato equivalente a 1.5.
  Nessuna modifica agli script originali.
- Input legacy: host, database, ICAO, utente/password in chiaro, cartella
  e nome file, numero righe di intestazione, separatore; per LIMC
  centralina 1 CGP, 2 Lonate (1.3/1.4) o Ferno (1.5/1.6), 3 Somma.
  DBI/MySQL, nessun processo esterno o variabile d'ambiente.
- Lettura verificata: file senza controllo di open, eliminazione degli
  spazi, split con separatore interpretato come regex (non parser CSV),
  virgole trasformate in punti. Dieci campi destinazione: data_ora,
  precipitazione_mm, temperatura_C, direzione_vento1/2, velocita_vento,
  umidita_relativa, radiazione_netta/globale, pressione_hpa.
  `*` e stringa vuota diventano NULL. convertiData riordina giorno/mese/anno;
  1.3 converte 24.00.00 in 23.59.59, 1.4-1.6 24:00:00 in 23:59:59,
  senza passare al giorno successivo.
- Destinazioni: CGP -> meteo_cgp; 1.3 Lonate/Somma -> meteo_lonate/meteo_somma;
  dalla 1.4 entrambi -> meteo. LIML/LIME -> meteo; LIPO dalla 1.5.
  Solo INSERT con placeholder; nessun controllo duplicati o date, nessun
  aggiornamento flay/battute. Inserimenti falliti stampati ma il ciclo continua;
  conteggio finale comprende intestazioni e incremento di fine ciclo.
  AutoCommit, durata/memoria non misurate. Dalla 1.4 log Windows aperto
  prima dell'input database/utente, senza verifica di apertura.
- Differenze di conversione: 1.3 ha un ordine colonne LIME/Lonate
  diverso da quello standard 1.4-1.6; radiazione netta non valorizzata.
  LIML mantiene il tracciato standard. CGP applica 1.3332 alla pressione,
  fattore compatibile con mmHg->hPa (unita del file originario non verificata).
  Somma lascia la pressione NULL. 1.6 separa LIPO senza modificarne la mappa.
- Caratterizzazione: `t/unit/carica_meteo.t` estrae solo le funzioni
  originali, in package isolati, e verifica mappe, LIPO assente/presente,
  CGP/Somma, valore mancante e ora 24; nessun accesso a file operativi/DB.
- Sostituzione richiesta: `ScriptManager::Command::CaricaMeteo`,
  comando `carica_meteo` / 09-carica_dati_meteo, asincrono/esclusivo,
  timeout 3600 secondi. Client `ScriptManager::Service::OpenMeteo`;
  database/aeroporto e **date obbligatorie**, non piu file/centraline.
  Nessuna nuova dipendenza: HTTP/JSON di Mojolicious, date/TZ di Perl/POSIX.
- Fonte verificata: [Historical Weather API](https://open-meteo.com/en/docs/historical-weather-api),
  endpoint HTTPS archive-api.open-meteo.com/v1/archive, modello best_match.
  Non usa il Forecast API per sostituire dati storici mancanti.
  Si tratta di rianalisi/output modellistici, non misure in situ.
  Invio esclusivo di coordinate geografiche pubbliche, quota e date;
  nessuna credenziale MySQL o traccia radar esce dall'app.
- ARP WGS84 di riferimento, da verificare contro l'AIP applicabile:
  - LIMC: 45 37 48 N, 008 43 23 E;
  - LIML: 45 26 58 N, 009 16 42 E;
    fonte [gestore SEA, dati tecnici](https://milanairports.com/en/group/technical-data).
  - LIME: 45 40 08 N, 009 42 01 E;
    fonte [copia AIP AD 2 LIME 1-1](https://www.nextdigital.it/apps/aip/browse/ad/ADPME1-1).
  - LIPO: 45 25 44 N, 010 19 50 E;
    fonte [copia AIP AD 2 LIPO 1-1](https://www.nextdigital.it/apps/aip/browse/ad/ADPPO1-1).
  Le coordinate LAT_aerop/LONG_aerop del DB sono proiettate, non WGS84:
  non vengono inviate all'API o convertite assumendo un EPSG non verificato.
  Quota da anagrafica.aeroporti.QUOTA_aerop, senza default se mancante.
  L'API sceglie una cella di griglia vicina: il report distingue ARP
  richiesto e coordinate effettivamente restituite, non promette una
  misura puntuale sul sedime.
- Mappa nuova, unita API validate: precipitation -> precipitazione_mm (mm
  nell'ora precedente), temperature_2m -> temperatura_C (C),
  wind_direction_10m -> direzione_vento1 (gradi), wind_speed_10m ->
  velocita_vento (m/s), relative_humidity_2m -> umidita_relativa (%),
  shortwave_radiation -> radiazione_globale (W/m2 medi ora precedente),
  surface_pressure -> pressione_hpa (**alla quota ARP**, non MSL).
  Valori su campi interi arrotondati all'intero piu vicino.
  direzione_vento2 e radiazione_netta NULL, senza inventare equivalenze.
- Decisioni esplicite: destinazione tabella legacy meteo, anche mescolando
  fonti; giorni gia presenti saltati se hanno almeno una riga, anche
  parziale. Sovrascrivi sostituisce interamente i soli giorni richiesti,
  **anche cancellando misure di centraline**; meteo_cgp intatta.
  Nessuna tabella aggiunta/migrazione radar, nessuna modifica flay/battute.
  Non usa validation_days: la presenza in meteo determina lo skip.
- Ora locale: API UTC/unixtime, precedente giorno UTC incluso nella
  richiesta e filtro finale ai soli giorni italiani scelti. Conversione
  Europe/Rome con DST per timestamp, non offset fisso dell'API.
  Marzo: 23 ore. Ottobre: 25 ore fisiche ridotte a 24 righe, **seconda
  02:00/ora solare** conservata, come scelto dall'utente.
  Avviso persistente e report scaricabile meteo-open-meteo.json con
  entrambe le ore UTC, dati originali, ARP/quota, URL, unita e attribuzione.
- Affidabilita: richieste in blocchi di massimo 13 giorni locali consecutivi,
  piu un giorno di margine UTC: massimo 14 giorni API e sette variabili,
  per mantenere il costo unitario di ogni richiesta;
  timeout HTTP 60 secondi, connessione 10, nessun redirect.
  Tutte le risposte analizzate e report scritto prima dei DELETE/INSERT.
  Unita errate, ore mancanti/duplicate/disordinate UTC, numerici mancanti,
  non finiti o non memorizzabili bloccano senza sostituzione con zero.
  HTTP/rate limit/date indisponibili sono errori espliciti, nessun fallback.
  Report salvato anche per ricostruire operazioni parziali.
- Salvataggio AutoCommit, un giorno alla volta: errore puo lasciare
  una giornata parziale, ma non cancella anticipatamente i giorni seguenti.
  Richiede Sovrascrivi per recuperare un giorno parziale; il retry normale
  lo salterebbe. Blocco difensivo interno 03-10; la coda applicativa include
  anche 02, non script legacy esterni.
  03-08 non invalidano meteo e 09 non ricalcola piste/SID/quote/validazioni.
  10 integrato usa quota ARP, non le quote delle centraline legacy.
  09 invalida lo storico 10 per ciascun giorno modificato, ma non azzera
  A_m/stato 3 gia prodotti: rieseguire 10 con Sovrascrivi.
- Provenienza: migrazione PostgreSQL 4, tabella weather_days con target,
  giorno, esecuzione 09, ARP/quota e SHA256 delle righe ordinate
  data_ora/temperatura_C/pressione_hpa realmente salvate. Efficace soltanto
  con esecuzione 09 completata; assente dopo cancellazione dell'esecuzione.
  10 rifiuta meteo privo di provenienza, anche vecchie importazioni Open-Meteo:
  reimportare con 09/Sovrascrivi. Nessuna nuova tabella nel database radar.
- Budget API persistente: weather_api_calls (migrazione 4), prenotazione
  atomica globale prima di ogni tentativo, stati reserved/succeeded/failed.
  Include timeout, errori e worker interrotti; nessun rimborso, nessun
  consumo per giorni saltati. Conserva il conteggio anche eliminando le
  esecuzioni. Blocco PostgreSQL breve dedicato alle prenotazioni, distinto
  dal blocco target della pipeline.
  [Limiti gratuiti pubblicati](https://open-meteo.com/en/pricing):
  600/minuto, 5000/ora, 10000/giorno, 300000/mese. Intervalli oltre due
  settimane o oltre dieci variabili possono valere piu chiamate; i blocchi
  limitati qui evitano tale maggiorazione. Un anno continuo: 29 richieste.
  Preflight sul totale pianificato e ricontrollo per ogni prenotazione.
  Contatori/residui in log, riepilogo e JSON, finestre mobili prudenziali
  1 minuto/1 ora/24 ore/31 giorni. Stima della sola installazione, non quota
  ufficiale IP: esclusi altri client, altre installazioni e consumi precedenti.
  HTTP 429 comunque propagato, nessun retry/fallback nascosto.
- Progressione: analisi 0-50%, salvataggio DELETE/INSERT 50-99%, riepilogo
  99%, concluso 100% dopo disconnect, come le altre fasi.
- Test: unitari su conversioni/HTTP/errori/DST; integrazione su MyISAM e
  PostgreSQL temporanei per date, giorni parziali, overwrite, protezione
  dei dati prima del salvataggio, blocco fra fasi, report scaricabile,
  errori dopo INSERT, recupero, anno bisestile, chunk/form.
  TEST_OPEN_METEO=1 abilita anche una vera chiamata API con salvataggio
  esclusivamente nel DB temporaneo, poi rimosso; normalmente le risposte
  sono sintetiche. Nessuna scrittura operativa e nessun deploy.
- Licenza: [Open-Meteo, CC BY 4.0](https://open-meteo.com/en/licence),
  attribuzione in log/report. Accesso pubblico gratuito soggetto ai limiti
  e all'uso non commerciale del servizio; endpoint/piano cliente per uso
  commerciale non implementati.

## Gruppo 10-correggi_quote*

- Varianti: 1.0 e 1.0+lipo; differenza funzionale trovata nell'aggiunta
  dei metadati della centralina LIPO (quota 120 m). Nessuna modifica legacy.
- Input legacy: host, database, aeroporto, utente/password; scelta della
  centralina per LIMC. DBI/MySQL, nessun processo esterno. Log Windows
  in append; durata/memoria non misurate.
- Selezione verificata: flay validation_bt=2, senza filtro A/D o pista;
  meteo in intervallo futuro da data_ora_arr a +60 minuti (+30 per CGP),
  prima riga senza ORDER BY. Battute con validation diversa da N/A,
  escluso SQL NULL, Z_m non NULL e A_m NULL. Include S.
- Formula caratterizzata dal codice originale:
  `P_aereo = 1013.25 * (1 - Z_m * 0.0065 / 288.15)^5.2525`;
  `A_m = quota_sorgente + ((temperatura_C+273.15)/0.0065) *
  (1 - (P_aereo/pressione_hpa)^(1/5.2525))`.
  Quote centralina legacy: CGP 216.5, Lonate 205, Ferno 215, Juvara 122,
  Trezzo 187, LIPO 120 m. Risultati negativi non troncati.
  Scrive A_m e poi validation_bt=3; AutoCommit senza rollback.
- Adattamenti richiesti/approvati: pressione surface_pressure e temperatura
  da 09 alla quota ARP, non alle quote centralina. Stesso esponente 5.2525.
  Ora contenente data_ora_arr (14:37 -> 14:00), non lookup futuro.
  Meteo assente, ambiguo o non verificabile: warning e skip traccia,
  senza avanzamento a bt=3. Nessun recupero automatico via API.
- Migrazione: `ScriptManager::Command::CorreggiQuote`, codice
  correggi_quote, asincrono/esclusivo, timeout 3600 secondi.
  Database e aeroporto LIMC/LIML/LIME/LIPO; intervallo facoltativo su
  data_ora_arr, skip giornaliero e overwrite comuni. Nessun filtro
  aeroporto sulle tracce: database coerente con il contesto scelto.
  Stima preventiva del salvataggio dalle misure strutturate di esecuzioni
  10 concluse; se manca lo storico o la stima supera il timeout, nessuna
  scrittura inizia finche l'utente non conferma la riesecuzione senza timeout.
  La conferma e disponibile anche dopo un timeout reale della 10.
  Provenienza 09 completata obbligatoria; verifica aeroporto, coordinate,
  quota ARP e impronta pressione/temperatura. Modifiche successive o righe
  duplicate rendono il giorno non verificabile. Nessun uso cieco di meteo
  di centralina come pressione ARP; reimportare con 09/Sovrascrivi.
- Salvataggio: analisi completa prima degli UPDATE; tutti gli A_m delle
  battute eleggibili vengono ricalcolati da Z_m, anche valori parziali
  preesistenti su bt=2, per recuperare retry senza dati obsoleti.
  Analisi delle battute per gruppi di 100 tracce; aggiornamenti CASE in
  lotti da massimo 500 righe, stato 3 aggiornato solo dopo tutte le quote
  della traccia. Check cancellazione per gruppo/lotto, non per singola riga.
  La ricerca meteo giornaliera usa intervalli DATETIME per sfruttare
  l'indice data_ora. La durata del salvataggio e le operazioni SQL vengono
  registrate per stimare le esecuzioni successive.
  Overwrite include bt=2/3 e azzera A_m solo delle tracce utilizzabili,
  mai di quelle saltate. bt=3 solo dopo le scritture della traccia.
  Nessuna modifica H_m/Z_m/hmod, pista, SID o validation delle battute.
  Numerici non finiti, pressione <=0, temperatura <=-273.15 o quota fuori
  dominio ISA producono errori espliciti prima del salvataggio.
- Completamento con avvisi: giorni con almeno una traccia saltata non
  registrati nello storico, per consentire retry delle sole bt=2 rimaste.
  Progresso analisi 0-50%, salvataggio 50-99%, riepilogo 99%, concluso
  100% dopo disconnect. Blocco target condiviso 03-10.
- Dipendenze: 03-06 e 08 invalidano storico 10 sulle date data_ora_arr
  interessate; 03/04 includono anche le date delle battute per cambi giorno.
  I loro overwrite cancellano A_m obsolete. 05/06 accettano bt=3 e
  ripristinano 1; 08 accetta bt=3 e ricalcola fino a 2. 07 indipendente.
  09 invalida solo storico/provenienza; per bt=3 esistenti usare
  esplicitamente 10/Sovrascrivi dopo il nuovo meteo.
- Verifiche: t/unit/correggi_quote.t estrae la formula originale e confronta
  risultati, esponente, quote sorgente, negativi e dominio.
  t/unit/correggi_quote_preflight.t verifica stime, assenza storico e override;
  t/integration/carica_meteo.t verifica su database temporanei ora contenente,
  ARP, filtri A/D e battute, date, skip/overwrite/retry, mancata provenienza,
  meteo modificato, metadati incoerenti, aggiornamenti oltre il lotto,
  numero di query, errori, annullamento, blocco e form.
  Verifica inoltre quote API alle soglie esatte 600/5000/10000/300000.
  t/integration/validation_window.t verifica reset upstream anche da bt=3.
  Nessuna scrittura operativa, nuova dipendenza o deploy.

## 12-carica_eventi_cmp.pl

- Percorso: `legacy/scripts/12-carica_eventi_cmp.pl`.
- Scopo: caricare eventi acustici nella tabella MySQL `st_eventi_cmp`.
- Stato: in migrazione; lo script legacy non e stato modificato.
- Modalita di avvio: CLI interattiva o con opzioni; password richiesta da terminale.
- Parametri: host, porta, database, utente, file, ID centralina, tabelle opzionali,
  `--dry-run`, `--help`.
- Input: TXT UTF-8 separato da `;`, con titolo, data, ora iniziale,
  intestazione e righe con secondi trascorsi, durata e misure numeriche.
- Output: riepilogo, avvisi per righe scartate, inserimenti MySQL.
- File letti/scritti: il file indicato; nessun file scritto.
- Database e tabelle dello script legacy: MySQL, `st_eventi_cmp` e
  `anagrafica.centraline_cmp` per il controllo dell'ID.
- Riferimento delle stazioni nella procedura integrata: `anagrafica.stazioni`,
  collegata ad `anagrafica.aeroporti` tramite `stazioni.aeroporti_id`.
  La selezione identifica la riga con `stazioni.row_id`, mentre il valore salvato
  in `st_eventi_cmp.id_centralina_cmp` e `stazioni.c_cab`, non `row_id`.
  Sono mostrate le stazioni dell'aeroporto scelto e quelle senza aeroporto
  associato; codici `c_cab` mancanti, modificati o ambigui bloccano l'importazione.
- Variabili d'ambiente: fuso orario locale del processo; nessuna letta esplicitamente.
- Moduli: DBI, DBD::mysql, Getopt::Long, Time::Local, POSIX, File::Spec;
  Term::ReadKey facoltativo. Programmi esterni: nessuno.
- Durata: non misurata. Codici: 0 riuscita, 1 errore fatale, 2 errori SQL gestiti.
- Effetti: AutoCommit e `INSERT IGNORE`; gli errori possono lasciare dati parziali.
- Rischi: `INSERT IGNORE` puo nascondere conversioni e non elimina i duplicati
  senza indice univoco; righe invalide sono scartate; la password puo essere visibile.
- Test: caratterizzazione in `t/characterization/carica_eventi_cmp.t`; test della
  nuova implementazione in `t/unit/eventi_cmp.t` e `t/integration/eventi_cmp.t`.
- Destinazione: `ScriptManager::Command::CaricaEventiCMP` e
  `ScriptManager::Service::EventiCMP`.
- Differenze approvate: importazione di tutti i TXT, associazione esplicita a
  stazioni dell'aeroporto o senza aeroporto, e orari gia italiani. L'uso di
  `stazioni.c_cab` e coerente con le query di correlazione legacy. Accettato
  anche il formato osservato con titolo, intestazione e data/ora su ogni riga.
  Sono verificate tutte le intestazioni e le righe prima delle scritture, senza
  scarti silenziosi. I duplicati sono identificati da codice stazione, data/ora,
  durata e Leq; senza indice univoco si usa un lock MySQL. Un file modificato
  dopo l'associazione blocca l'esecuzione. Non sono state eseguite importazioni
  sui dati operativi; la durata reale e da misurare.

## 14-correla_eventi_cmp

- Riferimento: `legacy/scripts/14-correla_eventi_cmp_0.64_LVA_Lvan.pl`;
  analisi statica, sintassi Perl verificata, legacy invariato.
- Input legacy: file tabulato con host, database, aeroporto, stazione `c_cab`,
  date, shift, limiti temporali, distanza e condizione SQL opzionale.
  La versione di riferimento legge la password anche dagli argomenti CLI.
- Tabelle: `st_eventi_cmp`, `battute`, `flay`, `battute_eventi_cmp`, `st_lva`,
  `st_lvan`, `anagrafica.stazioni`, `aeroporti`, `stazioni_sid` e `correla_log`.
  Il legacy svuota e ricarica `battute_tmp`, ma la ricerca usa `battute`.
- La procedura integrata non usa `battute_tmp` ne SQL libero; richiede
  conferma della sostituzione delle correlazioni, per tutti gli shift,
  e parametri per stazione. L'ultimo set di una richiesta completata diventa
  default per la stessa stazione e server; date richieste ogni volta.
- La formula legacy del valore detto non correlato comprende tutti gli eventi.
  LVA e LVAn sono salvati per data, anche per giorni con solo totale:
  differenza approvata rispetto all'accoppiamento posizionale legacy.
  L'attualizzazione avviene solo dopo consultazione e conferma separata.
- Parametri persistiti nello storico e nel log JSONB; `correla_log` MySQL
  mantenuto usando l'ID inserito, senza `MAX(IdLog)`. Nessuna credenziale
  nel file di parametri applicativo o nei log.
- Tabelle mancanti create vuote soltanto dopo conferma, da `bgy_2024_bruma`
  e, per `st_lvan`, `bgy_2025_bruma`; colonne richieste confrontate con i
  riferimenti. Le scritture MyISAM sono AutoCommit e non garantiscono rollback.
- Test: `t/integration/correla_eventi_cmp.t` e
  `t/integration/correlazione_web.t` su database isolati. Nessuna modifica
  o correlazione operativa durante i test.
- Il cruscotto correlazioni legge `st_lva` attuale per aeroporto e anno:
  date presenti nell'aeroporto, righe per stazione e colori per presenza
  LVAc/LVAnc. Il rosso segnala l'ultima richiesta terminata con errore o
  timeout nello storico applicativo per stazione e intervallo; non attesta
  quale singolo giorno abbia causato l'errore e non include script esterni.

## Controlli temporali comuni dei comandi migrati 03-08 e 10

- `date_from` e `date_to` facoltativi ma entrambi richiesti se uno e presente,
  giorni inclusi; senza intervallo si considera l'intero database.
  03-06 e 08 usano `flay.data_ora_italy` DATETIME, non la data UTC.
  07 e 10 usano `data_ora_arr`, come il legacy, per scelta esplicita dell'utente.
  Tracce senza il rispettivo campo data escluse con conteggio nei log;
  `M` preservate. Si elaborano sempre
  tutte le battute delle tracce selezionate, anche oltre mezzanotte.
- Storico persistente PostgreSQL `validation_days`, separato per target
  MySQL e comando. Skip soltanto per giorni di esecuzioni completate con
  successo; nessuna deduzione dai soli flag esistenti o da vecchie esecuzioni
  senza storico giornaliero. Blocco difensivo interno 03-10 sullo stesso
  target, piu coda applicativa 02-10; processi esterni non coordinati.
- `overwrite` disabilitato per default: ricalcola il comando e azzera i
  risultati dipendenti, invalidando prima il relativo storico giornaliero.
  03 azzera battute/stati/date/pista/SID; 04 ricalcola da esiti 03 validi
  (`Y/L/D/P`) e azzera pista/SID; 05 ripristina X->Y e ricalcola pista/SID
  arrivi; 06 azzera pista/SID decolli e ricalcola pista. Non ripristina
  coordinate/quote eventualmente alterate da script successivi.
  07 ricalcola solo SID dei decolli con pista e bt>0.
  08 ricalcola Z_m/hmod da H_m con pista e bt=1/2/3, conservando pista/SID.
  Gli overwrite 03-06 azzerano Z_m/hmod/A_m nei propri scope; 05/06 includono
  anche bt=2/3 e lo ripristinano a 1. 08 azzera anche A_m; H_m non alterato.
  10 ricalcola A_m con bt=2/3, senza modificare Z_m/H_m.
- Dipendenza 07: 03/04/06 invalidano lo storico SID sulle date data_ora_arr
  dei decolli interessati, non riutilizzando le diverse date locali.
  Per 03/04 vengono inclusi anche i giorni delle battute, per invalidare
  preventivamente l'eventuale nuovo giorno calcolato da 04. 05 resta
  indipendente da 07. Invalida solo lo storico, non i dati di altri giorni.
  03-06 invalidano anche lo storico 08 nei giorni locali selezionati.
- Per gli scarti pista P/bt0/N*, lo stato di 04 viene ricostruito dalle
  battute Y (+X per 05): 4-7 -> L, almeno 8 -> Y. Stati incoerenti con meno
  di quattro battute bloccano prima di scrivere. Analisi su dati proiettati
  in memoria prima del reset, che avviene nella fase Salvataggio.
- Test: `t/unit/validation_window.t` e `t/integration/validation_window.t`;
  quest'ultimo richiede TEST_ONLINE e TEST_MYSQL=1, usa un database MyISAM
  `sm_test_validation_*` e schemi PostgreSQL dedicati, poi li rimuove.
  Verifica selezioni locali e confini giornalieri, report/date limitati,
  skip, ricalcolo, invalidazione dipendenti, errore dopo UPDATE, blocchi
  concorrenti e form web. Anagrafica sintetica; nessuna scrittura operativa.

## Coda gestita dei comandi MySQL 02-10

- Catalogo: queue_by_database=true per 02-10, solo asincroni con parametro
  database. Target persistente host configurato (minuscolo), porta e nome DB.
  La migrazione PostgreSQL 5 aggiunge executions.queue_target/queue_order
  e indice dei job non conclusi; nessuna modifica al database radar.
- FIFO tra procedure diverse sul medesimo target. Inserimenti ordinati da
  sequenza sotto lock breve; avvio solo della prima queued, sotto advisory
  lock PostgreSQL mantenuto fino al salvataggio dello stato finale.
  Nessuna scadenza del lock basata sul timeout. Database differenti
  indipendenti, anche per la medesima procedura, entro i worker disponibili.
  L'esclusivita globale per codice resta per procedure non gestite dalla coda.
- Minion rinvia i job in attesa ogni cinque secondi; restano queued,
  started_at NULL e senza consumo del timeout. Posizione nella pagina
  esecuzione e nell'API, comprensiva del job attivo. Un messaggio persistente
  segnala l'attesa senza aggiungere un evento a ogni retry.
- Cancellare una queued permette al successivo di avanzare. Un fallimento,
  compreso il rifiuto della stima, non elimina i job successivi: FIFO non
  significa dipendenza fra fasi. Nessuna suddivisione automatica delle date.
- Alla ripresa, una running/cancel_requested gestita che non possiede piu il
  lock diventa failed/worker_interrupted. Nessun replay automatico di
  scritture MyISAM parziali. Un cambio host/porta dopo l'invio fa fallire
  la richiesta con queue_target_changed, senza spostarla su un altro server.
- Controllo generale degli orfani: riconcilia running/cancel_requested con
  Minion anche senza queue_target, nel ciclo worker (wait/busy), da storico,
  dettaglio web/API e CLI; controllo limitato a uno ogni 30 secondi per
  processo, forzabile con `perl bin/procedure reconcile`.
  La riparazione standard Minion rileva worker senza heartbeat dopo il suo
  missing_after (default 30 minuti). Nuove esecuzioni protette da un lock
  PostgreSQL per ID fino al termine; job Minion attivi sempre preservati.
  Nessuna deduzione dall'eta dell'ultimo progresso. Solo senza lock e con
  job non attivo/mancante: failed/worker_interrupted con evento ERROR atomico,
  progresso mantenuto e avviso di scritture parziali, senza replay.
  Nessuna migrazione; test di riconciliazione, lock, idempotenza e hook in
  t/integration/execution_service.t. Non classifica richieste senza job
  Minion; non dichiara morti processi ancora vivi ma bloccati.
- Upgrade coordinato app/worker a worker fermi. Le richieste precedenti senza
  queue_target non sono migrate retroattivamente nella coda; verificarle e
  ricrearle. Processi esterni/legacy/SQL manuale non partecipano.
- Stima preventiva inizialmente solo per 04, descritta nella sua sezione.
  Le misure legacy senza target persistente assumono lo stesso host MySQL
  della configurazione attuale; in caso di cambio host non sono calibrazione
  verificata. Nessuna modifica degli algoritmi legacy.
- Test: t/integration/execution_service.t per FIFO, lock, isolamento DB,
  annullamento, riprogrammazione Minion, worker interrotto e target cambiato;
  t/integration/validation_window.t per rifiuti preventivi senza scritture.
