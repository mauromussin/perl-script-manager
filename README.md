# Perl Script Manager

Applicazione web (Mojolicious + Minion + PostGIS) per l'esecuzione guidata di procedure Perl.
Specifica completa: [docs/ANALISI_APPLICAZIONE.md](docs/ANALISI_APPLICAZIONE.md).

## Cruscotto

La voce **Cruscotto** mostra lo stato delle richieste per database e anno dei
dati. Ogni mese compreso tra `date_from` e `date_to` inclusi riporta l'ultima
richiesta per data di registrazione, anche se riguarda solo parte del mese.
Bianco: nessuna richiesta; verde: completata; rosso: fallita o annullata;
giallo: timeout; grigio: accodata, in corso o annullamento richiesto.
Ogni cella indica la data di conclusione italiana, se disponibile, e collega
al dettaglio dell'esecuzione. La data puo essere successiva all'anno dei dati.
Sugli schermi stretti le celle mostrano il colore: selezionarle per consultare
stato e data nel dettaglio.

Il riepilogo riflette lo storico conservato nell'applicazione, non verifica
direttamente i dati radar o le dipendenze tra procedure: un mese verde non
garantisce che tutte le sue giornate siano complete. Le richieste senza date
o con intervallo non valido sono riepilogate separatamente senza attribuirle
a mesi o anni; un warning compare nella pagina e nei log applicativi. I
database e le procedure non presenti nello storico non hanno risultati.

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
`127.0.0.1:5433`; l'app è pubblicata sulle interfacce IPv4 dell'host,
porta `3080` (porta container `3000`), accessibile anche dalla LAN tramite
`http://<IP-host>:3080`. L'accesso locale su `127.0.0.1:3080` resta disponibile.
La password deve essere compatibile con una URL PostgreSQL oppure percent-encoded.

**Accesso LAN senza login:** consentito solo su rete fidata, come scelta
esplicita di questo deployment. Chi raggiunge la porta puo avviare procedure
e leggere risultati. Non esporre la porta su Internet o reti non fidate;
limitare i client tramite firewall/rete. Per tornare al solo accesso locale,
usare `127.0.0.1:3080:3000` nella pubblicazione del servizio `app`.
Su Windows verificare il profilo firewall attivo: se blocca la porta, consentire
TCP 3080 soltanto alle reti/client autorizzati, non disabilitare il firewall.

### Cartella delle tracce radar

Il mount di default e `E:\FILE_OUT` sull'host Windows, esposto in sola lettura
come `/app/var/input` sia ad app sia al worker (anche nei servizi di sviluppo).
La cartella host deve esistere; Compose non la crea automaticamente.
Per cambiarla impostare `FILE_OUT_ROOT` in `.env`.

### Cartella degli eventi acustici

La procedura 12 cerca ricorsivamente tutti i file `.txt` in `E:\FILE_TXT`,
montata in sola lettura come `/app/var/input-txt` su app e worker, anche in
sviluppo. La cartella deve esistere; `FILE_TXT_ROOT` in `.env` ne cambia il
percorso sull'host. Dopo la ricerca scegliere una stazione per ogni file:
sono disponibili quelle dell'aeroporto e quelle senza aeroporto associato.
Il codice `c_cab` della stazione viene salvato in `id_centralina_cmp`.
La ricerca va ripetuta se l'elenco o il contenuto dei file cambia.

I TXT devono avere intestazione delle dieci colonne previste e data/ora italiana
in ogni riga oppure il formato legacy con data, ora iniziale e secondi trascorsi.
Nel formato legacy i secondi sono sommati alla mezzanotte in fuso Europe/Rome,
come nello script originale, anche nei giorni di cambio dell'ora.
I duplicati per codice stazione, data/ora, durata e Leq sono ignorati. Se manca
l'indice univoco, il controllo usa un lock di scrittura MySQL. Sono necessari
permessi di lettura dell'anagrafica e di scrittura (e, in tale caso, LOCK TABLES)
sul database di destinazione. Le tabelle MyISAM non consentono rollback:
errori, timeout o annullamento possono lasciare un'importazione parziale.

### Correlazione eventi: procedura 14

Selezionare aeroporto, database `<IATA>_<AAAA>_bruma`, periodo e una o piu
stazioni. Per ciascuna stazione sono mostrati contemporaneamente shift,
limiti temporali e distanza massima: i default iniziali sono 1 s, -90 s,
100 s e 5000 m. Dopo una correlazione completata diventano i default
della stessa stazione sullo stesso server MySQL. Le date sono sempre richieste.
Confermare esplicitamente parametri e sostituzione delle correlazioni esistenti,
che riguarda tutti gli shift della stazione nel periodo. La clausola SQL
legacy `cond` non e utilizzabile.

Le stazioni sono individuate in `anagrafica.stazioni` e gli eventi tramite
`c_cab`. La selezione richiede coordinate valide, codici non ambigui e almeno
un evento con SEL valorizzato per ogni stazione. Il comando usa le battute
validate e la distanza tridimensionale, registra i parametri nello storico
PostgreSQL JSONB e scrive anche `anagrafica.correla_log`.
Calcola LVA e LVAn per giorno, distinguendo eventi correlati e totale degli
eventi: quest'ultimo corrisponde al valore chiamato non correlato dal legacy.
Il totale viene salvato anche per giorni senza correlazioni. Dopo il
completamento, **Verifica e attualizza LVA/LVAn** mostra per ogni stazione e
giorno LVAnc, LVAc, differenza, eventi correlati/totali (Ec/E), LVAn
correlato e totale, numero di eventi notturni senza abbinamento e numero
totale di eventi notturni. La notte comprende le ore 23:00-05:59 dello stesso
giorno. Valori e percentuali sono visualizzati con due cifre decimali; i
conteggi restano interi.
Il rapporto 0/0 non e calcolabile. I conteggi giornalieri sono conservati
nel log dell'esecuzione; per esecuzioni precedenti senza snapshot sono
indicati come non disponibili; lo stesso vale per i conteggi notturni non
registrati nelle esecuzioni precedenti. Un'unica accettazione per stazione accoda
l'attualizzazione di LVA e LVAn disponibili. I giorni senza nuovi risultati
conservano i valori attuali precedenti.

Il **Cruscotto correlazioni** seleziona aeroporto e anno dal nome del
database e mostra, per ogni stazione, le date con almeno un LVA attuale
nell'aeroporto. Verde: LVAc e LVAnc presenti; giallo: solo LVAnc;
bianco: nessun dato o LVAnc mancante. Rosso: ultima correlazione terminata
con errore o timeout per un intervallo che comprende quel giorno; la cella
apre i log. L'errore e attribuito all'intervallo richiesto, non al singolo
giorno. Annullamenti e richieste in corso non sono errori. Il cruscotto
usa `st_lva`, non `st_lvan`, e non considera i calcoli non attualizzati.
Le segnalazioni rosse provengono dallo storico dello Script Manager sullo
stesso server e database, non rilevano errori di script esterni.
Per una singola stazione e un giorno, il simbolo **×** mostra un'anteprima e
richiede conferma: rimuove gli abbinamenti evento-battuta per tutti gli shift
e toglie il flag `attuale` ai risultati correlati LVA/LVAn. Eventi, valori
totali e storico rimangono. Se LVAn non e presente nel database, l'anteprima
lo segnala e nessuna tabella viene creata. L'operazione e accodata e si interrompe se i dati
verificati sono cambiati prima dell'esecuzione. Riattualizzare un risultato
storico non ricrea gli abbinamenti eliminati.

Se mancano tabelle, la pagina propone la creazione vuota solo dopo conferma:
usa gli schemi di `bgy_2024_bruma`, e per `st_lvan` quello di
`bgy_2025_bruma`. Occorrono permessi di lettura sui riferimenti e CREATE
sul database scelto. Le colonne richieste delle tabelle presenti sono
verificate rispetto ai riferimenti. La creazione non importa gli eventi e
richiede che la coda del database sia libera.

Correlazione, attualizzazione ed eliminazione condividono la coda per database. Le scritture
sono in AutoCommit: con MyISAM errori, timeout o annullamenti possono lasciare
cancellazioni o aggiornamenti parziali. Verificare log e dati prima di riprovare;
gli script esterni non partecipano alla coda applicativa.

### Selezione delle tracce radar

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

Su Windows, dalla root del repository in PowerShell, e disponibile il batch:

```powershell
.\aggiorna.bat
# Oppure scegliere uno ZIP specifico:
.\aggiorna.bat -ArtifactZip "$env:USERPROFILE\Downloads\perl-script-manager-linux-amd64-<commit>.zip"
```

Il batch usa `aggiorna.ps1`: seleziona per default lo ZIP
`perl-script-manager*.zip` modificato piu di recente in Downloads, mostra il
percorso, estrae in una cartella temporanea, verifica SHA256 e importa in Docker.
Poi ferma app e worker e li riavvia insieme con l'immagine locale
`perl-script-manager:production`, senza build, pull o riavvio del database.
Attende l'avvio dei container (massimo 60 secondi) e ne mostra lo stato.
Eseguirlo solo quando non ci sono procedure in corso: il riavvio puo
interromperle lasciando scritture parziali. Gli errori interrompono il batch
con codice non zero; se avvengono dopo lo stop i servizi possono restare fermi.
Lo ZIP originale e conservato, l'estrazione temporanea viene eliminata e
nessuna impostazione di `.env` viene modificata.

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

## Validazione delle battute: 04-valida_battute

Il comando `valida_battute` e disponibile nel catalogo web e nella CLI:

```bash
perl bin/procedure run valida_battute --database radar_test
```

Richiede solo il database: usa le stesse variabili `MYSQL_HOST`, `MYSQL_PORT`,
`MYSQL_USER`, `MYSQL_PASSWORD` del caricamento. L'aeroporto richiesto dal legacy
non e utilizzato e quindi non viene riproposto.

Eseguire dopo `03-valida_tracce`: senza sovrascrittura seleziona solo tracce con `validation_fl='Y'`
e `validation_bt IS NULL`. Classifica battute taxi (`T`), spezzate (`S`),
non valide (`N`), valide (`Y`) o appartenenti a tracce insufficienti (`D`).
Aggiorna anche gli stati delle tracce (`D` sotto 4 valide, `L` da 4 a 7,
`Y` da 8) e le date mancanti `data_ora_arr`: prima battuta valida per i
decolli, ultima per gli atterraggi. Quest'ultimo passaggio include le tracce
gia validate nei giorni selezionati e non saltati, anche se non ci sono
nuove tracce da analizzare.

Le correzioni dei difetti legacy approvate sono descritte
nell'[inventario](docs/INVENTARIO_SCRIPT.md#04-valida_battute_10pl).
Operazioni diverse da A/D e dati numerici mancanti/non validi (incluse quote
negative, non gestite dal legacy) producono un errore prima del salvataggio.
Gli script originali restano invariati.

Come nel legacy, le scritture sono in AutoCommit: cancellazione o errore non
annullano gli aggiornamenti gia eseguiti. Verificare i log e i dati prima di
rieseguire un'elaborazione interrotta. La coda condivisa dei comandi 02-10
serializza le richieste sullo stesso database; script legacy e processi
esterni non partecipano, da non avviare contemporaneamente.

Con Sovrascrivi, il reset di 04 azzera insieme A_m, Z_m, hmod e validation
delle battute in lotti di massimo 500 tracce, tramite gli indici esistenti
su battute.flay_id: evita i tre UPDATE con JOIN che possono scandire tutta
la tabella battute anche per intervalli brevi. Non riscrive battute con tutti
questi campi gia NULL. Giorni, esclusioni e risultati restano invariati;
H_m non viene modificato. Il dettaglio del salvataggio mostra il lotto in
corso al 50%, senza simulare una percentuale temporale. Il reset degli
stati/date/pista/SID segue quello delle battute. Restano AutoCommit e
possibili scritture parziali; nessun nuovo indice o modifica allo schema radar.

### Coda per database e controllo preventivo della durata

Le richieste web/API/CLI delle fasi **02-10** entrano in una coda FIFO
identificata da host MySQL, porta e nome database. Anche procedure diverse
sullo stesso database attendono il proprio turno, anziche fallire per
conflitto. La stessa procedura su database diversi puo procedere in parallelo,
se ci sono worker liberi. La coda non suddivide automaticamente le date:
si possono inviare piu 04 su intervalli distinti, nell'ordine desiderato.

Stato `queued`, posizione nella pagina di dettaglio/API (`queue_position`)
e messaggio di attesa rendono visibile la coda. La posizione include
l'eventuale richiesta in corso. L'attesa non consuma il timeout.
L'annullamento di una richiesta accodata libera il turno; errori e timeout
non cancellano le richieste successive. **Non e una catena di dipendenze**:
se 04 fallisce, una 05 gia accodata potra comunque partire sui dati rimasti.
Verificare il risultato prima di inviare fasi dipendenti.

Il lock PostgreSQL resta acquisito fino alla conclusione, senza una scadenza
che possa far sovrapporre processi lunghi. Se un worker scompare e il lock
e rilasciato, la successiva richiesta sulla stessa coda marca l'esecuzione
gestita rimasta attiva come `failed/worker_interrupted`, con avviso di
possibili scritture parziali: non la ripete automaticamente.

Per **04** il timeout predefinito resta quello configurato (3600 secondi nel catalogo).
Quando arriva il suo turno, prima di qualsiasi reset/scrittura radar:

- conta le battute delle tracce effettivamente selezionate, considerando
  date, skip e Sovrascrivi;
- misura l'analisi reale su campioni A/D suddivisi per numerosita di battute,
  includendo estremi e mediana di ogni gruppo;
- stima il salvataggio dai tempi delle ultime dieci esecuzioni 04 con misure
  sullo stesso database negli ultimi 90 giorni; usa anche progressi legacy
  interpretabili e intervalli parziali di almeno dieci operazioni;
- sceglie i tempi piu prudenziali e applica un margine 2x; dopo l'analisi
  completa ricontrolla il budget col numero esatto di operazioni previste.

La stima e deliberatamente prudenziale (campioni piu lenti e margine 2x):
puo quindi superare 3600 secondi anche se un'elaborazione simile e terminata
prima. Non e un tempo reale atteso ne una garanzia.

Se la stima supera il timeout, la richiesta si ferma prima delle scritture
con `timeout_estimate`. Nel dettaglio compare **Conferma e riesegui senza
timeout**, con checkbox di conferma non preselezionata e avviso dei rischi.
La conferma crea una **nuova richiesta** con gli stessi parametri (database,
date e Sovrascrivi), in fondo alla stessa coda. Non mantiene un worker
occupato in attesa dell'utente e non modifica il record rifiutato.

Solo per la richiesta confermata vengono disattivati **sia il blocco della
stima sia il timeout reale**: puo durare piu di 3600 secondi. Il preflight
continua a calcolare/registrare le stime, anche prima del salvataggio,
ma non rifiuta il superamento. Restano lock, coda, controlli degli input e
cancellazione cooperativa; un SQL gia in corso puo ritardare la cancellazione.
Il dettaglio mostra sempre **Timeout disattivato**. La scelta e persistente
(`executions.timeout_bypassed`, migrazione PostgreSQL **6**) e il log registra
chi ha richiesto la nuova esecuzione e il riferimento alla richiesta originale.
L'API di stato espone `timeout_bypassed` e `timeout_bypass_available`.
Un normale **Riesegui** non eredita il bypass; nessuna modifica al timeout
del catalogo o alle altre procedure.

Se manca uno storico misurabile, fallisce con
`timeout_estimate_unavailable`: **anche un nuovo database senza storico
viene bloccato**, come richiesto, senza coefficienti inventati o bypass.
Serve una calibrazione verificata/storico operativo disponibile; non e
previsto un comando di calibrazione. La conferma per durata eccessiva non
aggira l'assenza dello storico.
Uno skip integrale di giorni gia completati non richiede una stima.

Il preflight legge soltanto il database radar; log e misure sono salvati in
PostgreSQL. La stima viene registrata nei log, non e una garanzia: carico,
I/O e complessita delle tracce possono variare. Senza conferma esplicita il
timeout reale resta attivo, includendo il preflight. Ne una stima favorevole
ne il bypass rendono atomiche le scritture MyISAM. Anche 08 usa un preflight
e una conferma analoghi, con la differenza indicata nella sua sezione; gli
altri comandi hanno la coda, non questo estimatore.

La migrazione PostgreSQL **5** aggiunge target e ordine persistenti alle
esecuzioni, senza modifiche allo schema radar. Aggiornare app e worker
insieme a worker fermi, senza mescolare versioni. Le vecchie richieste prive
di target persistente non sono retroattivamente gestite dalla nuova coda:
verificare quelle pendenti/interrotte e ricrearle dopo l'aggiornamento.
Le misure legacy prive di target assumono invariato l'host MySQL configurato:
se e cambiato, non usarle come calibrazione.
La migrazione 6 mantiene il timeout attivo per tutte le richieste esistenti;
la conferma e disponibile anche per vecchie 04 rifiutate con timeout_estimate.

### Esecuzioni rimaste running dopo la morte del worker

Il controllo automatico riconcilia `running` e `cancel_requested` con il job
Minion associato, anche per vecchie richieste senza `queue_target`.
Viene eseguito nel ciclo del worker (anche quando occupato) e consultando
storico/dettaglio web o API, al massimo ogni 30 secondi per processo.
Anche `procedure status` e l'attesa CLI verificano gli stati. Per forzarlo:

```bash
perl bin/procedure reconcile
```

Il controllo esegue la riparazione standard di Minion: un worker senza
heartbeat viene considerato assente dopo `missing_after` (default Minion:
30 minuti). Un job gia fallito viene invece riconciliato al controllo
successivo. Senza worker attivi o richieste web/CLI non gira alcun controllo.

Ogni nuova esecuzione mantiene inoltre un advisory lock PostgreSQL fino
alla registrazione dello stato finale: finche il lock e presente non viene
segnalata come orfana, nemmeno se Minion perde il worker. Senza lock, un job
Minion ancora attivo viene comunque conservato, per proteggere anche le
esecuzioni precedenti all'aggiornamento. **Non si usa l'eta dell'ultimo log
o del progresso**: una query SQL lunga non equivale a un processo morto.
Un processo vivo ma bloccato resta soggetto al timeout/cancellazione, non
a questo controllo di morte del worker.

Se il lock non esiste piu e il job risulta fallito, concluso, tornato in
attesa o eliminato, l'esecuzione diventa `failed/worker_interrupted`.
Stato finale ed evento ERROR sono salvati insieme, senza sovrascrivere
esecuzioni gia concluse ne creare eventi duplicati. Nessun riavvio
automatico delle scritture e nessun rollback: verificare gli eventuali
dati radar parziali prima di rieseguire. Le vecchie esecuzioni senza job
Minion associato non vengono classificate automaticamente.
Nessuna nuova migrazione o dipendenza; attivare il controllo aggiornando
app e worker insieme, dopo la conclusione delle procedure in corso.

## Assegnazione piste: 05 atterraggi e 06 decolli

Dopo `04-valida_battute`, sono disponibili nel catalogo web e nella CLI:

```bash
perl bin/procedure run trova_pista_atterraggi --database radar_test --airport LIMC --revision 1.2
perl bin/procedure run trova_pista_decolli --database radar_test --airport LIMC
```

Entrambi richiedono database e aeroporto (`LIMC`, `LIML`, `LIME`, `LIPO`),
con le stesse variabili `MYSQL_*` del caricamento. Gli atterraggi consentono
le revisioni legacy `1.0`, `1.1`, `1.2` (predefinita): la 1.0 non supporta
LIPO; la 1.2 rimuove l'offset di -376 m di LIME presente nelle precedenti.
I decolli riproducono l'unica revisione trovata, la 1.1, mantenendo i propri
offset distinti da quelli degli atterraggi.

Senza sovrascrittura elaborano solo tracce della rispettiva operazione A/D con `validation_bt=1`
e `pista IS NULL`, usando le battute `Y`. Come nel legacy, **non filtrano
le tracce per aeroporto**: il database scelto deve contenere il solo
contesto aeroportuale indicato. Gli estremi sono associati tramite
`anagrafica.piste.nome_pista`, senza dipendere dall'ordine delle righe:
Malpensa EST = 35R/17L, OVEST = 35L/17R; Linate usa solo 36R/18L.

05 aggiorna pista e SID; normalmente 06 aggiorna solo pista, lasciando la SID invariata.
Un'assegnazione fallita salva il codice diagnostico e imposta
`validation_fl='P'`, `validation_bt=0`. Il recupero previsto per gli
atterraggi di Malpensa puo marcare l'ultima battuta `X`.
Le coppie di battute mancanti producono un esito non assegnato, senza
riutilizzare coordinate o piste della traccia precedente.
Restano le particolarita deterministiche di campionamento del legacy,
descritte nell'[inventario](docs/INVENTARIO_SCRIPT.md#gruppo-05-trova_pista_atterraggi).

L'analisi precede tutte le scritture; errori nei dati numerici o negli
estremi richiesti interrompono il comando prima del salvataggio.
Nessuna traccia da elaborare e un esito positivo senza scritture.
AutoCommit non consente rollback dopo errori o annullamenti durante
il salvataggio. Non avviare contemporaneamente altri passaggi sullo stesso
database: 02-10 condividono la coda per database; script/processi esterni
non partecipano. Resta anche il blocco difensivo interno 03-10.
Gli script legacy restano invariati.

## Assegnazione SID: 07

Il comando `assegna_sid` usa la variante **2.2 dal_2015_corr**, scelta
esplicitamente come riferimento (file modificato nel 2026), non la variante
Malpensa 2025 con CAM/SUD. Eseguire dopo 06:

```bash
perl bin/procedure run assegna_sid --database radar_test --airport LIMC --date-from 2026-11-01 --date-to 2026-11-02
```

Supporta `LIMC`, `LIML`, `LIME`; LIPO non e implementato nella variante
scelta. Richiede decolli con `validation_bt > 0`, pista non NULL e,
normalmente, SID NULL. Non filtra le tracce per aeroporto: il database
deve corrispondere al contesto scelto. Usa solo battute `Y`, ordinate per
`time_italy, row_id`, salta la prima e assegna la prima SID incontrata.
Mantiene regioni, precedenze e soglie del riferimento; corregge il refuso
`B220D` in `B220` della retta BC di SID 220 a Orio, come approvato.

A Malpensa conserva il fallback 168 sulle piste 17L/17R, NA sulle altre.
A Linate/Orio, in assenza di corrispondenze, imposta NA solo con
`validation_bt=1`; con valori superiori lascia NULL, come il legacy.
Non modifica pista, stati delle tracce o classificazioni delle battute.
Sovrascrivi ricalcola solo le SID dei decolli selezionati, anche quelle
gia presenti. Scritture e riepilogo, compresi gli esiti NA, non escono
dai giorni selezionati non saltati. Analisi, salvataggio, riepilogo e
conclusione seguono lo stesso schema degli altri comandi.

## Rettifica quote nulle: 08

Il comando `rettifica_quote` migra l'unica variante
`08-rettifica_quote_nulle_1.1.pl`, dopo l'assegnazione delle piste e,
per i decolli, preferibilmente dopo 07:

```bash
perl bin/procedure run rettifica_quote --database radar_test --date-from 2026-11-01 --date-to 2026-11-02
```

Elabora **arrivi e decolli**, come la SELECT legacy, con `validation_bt=1`
e pista non NULL. Non richiede aeroporto: il parametro legacy era inutilizzato.
Le date si riferiscono a `data_ora_italy`. Legge le battute in ordine
`time_italy, row_id`, escludendo `N`, `A`, `S` e validation NULL; include
quindi anche `X`, `T` e `L`, non soltanto `Y`.

Scrive `Z_m`, `hmod` e `flay.validation_bt`; **non modifica H_m**,
coordinate, pista o SID. Copia H_m non zero in Z_m con hmod NULL e interpola
gli zeri usando le distanze euclidee XY dalle quote originali non zero:
due ancore interne per l'interpolazione, le prime/ultime due per
l'estrapolazione agli estremi. Include anche l'ultima battuta come ancora.
Le quote calcolate negative diventano zero. Con una sola ancora usa una
quota costante; a distanza nulla usa la quota dell'ancora, segnalando entrambi
i casi nei log. Queste correzioni e la copia delle quote originali sono
state approvate esplicitamente, non riproducono i difetti del legacy.

Con meno di tre battute ammesse o tutte le H_m zero, segnala la traccia
come non rettificabile e non la porta a `validation_bt=2`. Gli altri
completamenti avanzano da 1 a 2 solo dopo il salvataggio delle quote.
Le battute gia `hmod=M` sono preservate senza Sovrascrivi.
Il riepilogo distingue tracce rettificate, non rettificabili, quote
interpolate e copiate. Una conclusione con avvisi registra comunque
i giorni nello storico: per ritentare le tracce non rettificabili dopo
aver corretto i dati usare Sovrascrivi.

Sovrascrivi include anche le tracce con `validation_bt=2/3`, azzera Z_m/hmod
delle sole battute ammesse e ricalcola da H_m. Elimina inoltre A_m delle
tracce interessate e invalida lo storico 10: rieseguire la normalizzazione.
Analisi completa prima delle scritture; errori nei numerici interrompono
prima dei reset. Nessuna nuova tabella nel database radar: sono richiesti
i campi legacy `battute.Z_m` e `battute.hmod`.

Prima delle scritture la 08 campiona l'analisi e stima il salvataggio usando
le misure delle ultime dieci esecuzioni sullo stesso target negli ultimi
90 giorni, con margine 2x; dopo l'analisi verifica di nuovo il budget. La
stima e euristica, non garantisce la durata. Le vecchie misure precedenti
all'ottimizzazione possono renderla molto prudenziale. Se la stima supera
il timeout, il dettaglio offre la stessa conferma della 04 per una nuova
richiesta in coda senza timeout. Se manca uno storico misurabile, la 08
si ferma prima delle scritture e offre la conferma segnalando che la durata
non e stimabile; diversamente, la 04 resta bloccata senza storico.
Le vecchie 08 gia terminate per timeout vanno rilanciate normalmente per
ottenere il preflight; possono aver lasciato scritture parziali.

Il reset in Sovrascrivi e gli aggiornamenti delle quote sono raggruppati
per ridurre le query; la 08 aggiorna righe esistenti, non ne inserisce.
Resta AutoCommit: un'interruzione puo lasciare risultati parziali, ora
alla granularita dei lotti. Nessuna riduzione della durata e garantita.
Queste modifiche richiedono il deploy coordinato di app e worker, a worker
fermi, prima di essere disponibili.

## Dati meteo orari Open-Meteo: 09

`carica_meteo` sostituisce l'importazione di file di centraline delle
varianti legacy 1.3-1.6 con l'[Historical Weather API di Open-Meteo](https://open-meteo.com/en/docs/historical-weather-api).
Richiede **database, aeroporto, data iniziale e data finale**:

```bash
perl bin/procedure run carica_meteo --database radar_test --airport LIMC --date-from 2025-09-01 --date-to 2025-10-31
```

Le date sono giorni italiani inclusivi e sempre obbligatorie, diversamente
da 03-08. Supporta LIMC/LIML/LIME/LIPO, richiedendo dati alle coordinate ARP
WGS84 pubblicate e alla quota `anagrafica.aeroporti.QUOTA_aerop`.
Non invia i campi LAT/LONG del database: sono coordinate proiettate.
I riferimenti ARP sono riportati nell'inventario e nel report; verificarli
rispetto all'AIP applicabile prima di un impiego operativo.

Sono **dati modellistici storici, non osservazioni di centralina/METAR**.
Il modello `best_match` e la griglia sono scelti da Open-Meteo: la cella
restituita puo differire dall'ARP richiesto. Il report conserva coordinate
richieste e restituite, quota, URL pubblico e risposta originale.

| Campo `meteo` | Variabile Open-Meteo / unita |
|---|---|
| `precipitazione_mm` | `precipitation`, mm nell'ora precedente |
| `temperatura_C` | `temperature_2m`, gradi Celsius |
| `direzione_vento1` | `wind_direction_10m`, gradi |
| `velocita_vento` | `wind_speed_10m`, m/s |
| `umidita_relativa` | `relative_humidity_2m`, percentuale |
| `radiazione_globale` | `shortwave_radiation`, W/m2 medi nell'ora precedente, arrotondati all'intero del campo legacy |
| `pressione_hpa` | `surface_pressure` alla quota ARP, hPa, non pressione ridotta al livello del mare |
| `direzione_vento2`, `radiazione_netta` | NULL: nessun equivalente assunto |

Scrive nella tabella legacy **`meteo`**, senza modificarne lo schema e senza
toccare `meteo_cgp`, tracce o battute. Un giorno con almeno una riga esistente
viene saltato, anche se incompleto o proveniente da una centralina; per
questa fase non si usa lo storico `validation_days`. **Sovrascrivi cancella
tutte le righe meteo dei soli giorni richiesti e le sostituisce**, comprese
le misure di centraline. Richiederlo consapevolmente.

Le richieste usano timestamp UTC e un margine per coprire la mezzanotte;
la conversione a Europe/Rome applica l'ora legale a ciascun timestamp.
A marzo si salvano 23 ore, senza inventare le 02:00. A ottobre, per scelta
esplicita, si conserva soltanto la seconda 02:00 (ora solare): 24 righe
legacy da 25 ore fisiche. Un avviso e il report JSON scaricabile
`meteo-open-meteo.json` conservano anche l'occorrenza scartata e tutti
i dati UTC originali.

Analisi/API 0-50%, salvataggio 50-99%, riepilogo 99%, concluso 100%
dopo disconnect. Scarica blocchi di massimo 13 giorni locali consecutivi,
valida unita, continuita oraria e valori prima di cancellare qualsiasi
dato; salva anche il report prima dei DELETE/INSERT. Errori HTTP,
limiti API, date non disponibili o valori NULL/non validi fanno fallire
il comando: nessun fallback a previsioni, zeri o altre sorgenti.
Le scritture sono AutoCommit: un'interruzione puo lasciare un giorno
parziale; ripristinarlo con Sovrascrivi. Il blocco target e condiviso con
03-10; la coda applicativa coordina anche 02, non script legacy o SQL esterno.

Ogni giorno importato registra in PostgreSQL ARP, quota e impronta delle
temperature/pressioni effettivamente salvate. La fase 10 usa solo questa
provenienza e solo dopo la conclusione positiva di 09. Una sostituzione
invalida lo storico 10, **non azzera A_m o lo stato 3 gia presenti**:
per aggiornare quote precedenti eseguire **10 con Sovrascrivi**.
Le vecchie importazioni senza provenienza richiedono 09 con Sovrascrivi.

### Budget delle chiamate

I [limiti pubblici gratuiti](https://open-meteo.com/en/pricing) sono
600/minuto, 5.000/ora, 10.000/giorno e 300.000/mese. Oltre due settimane o
dieci variabili, una richiesta puo costare piu di una chiamata: i blocchi
di 13 giorni locali piu un giorno di margine UTC, con sette variabili,
restano entro una chiamata per richiesta. Un anno intero senza skip
richiede normalmente 29 richieste, non una per ora o traccia.

09 verifica il budget prima di scaricare e prenota atomicamente ogni
tentativo; se insufficiente interrompe prima della richiesta. Conta anche
errori, timeout e tentativi interrotti, senza rimborso automatico.
Log, riepilogo e report JSON mostrano consumo e disponibilita stimata.
Il contatore PostgreSQL e condiviso fra esecuzioni/database della stessa
installazione e sopravvive alla cancellazione dello storico esecuzioni.
Usa finestre mobili prudenziali di 1 minuto, 1 ora, 24 ore e 31 giorni.
**Non e la quota ufficiale dell'IP**: non conosce richieste precedenti
all'attivazione, altre installazioni o altri client sullo stesso IP.
Un eventuale HTTP 429 resta un errore esplicito.

La migrazione applicativa 4 crea `weather_api_calls` e `weather_days`
all'avvio aggiornato, senza modifiche allo schema radar. La provenienza
e legata all'esecuzione 09: se questa viene eliminata, va ricreata con
09/Sovrascrivi prima di ricalcolare 10.

Attribuzione: [Open-Meteo.com, CC BY 4.0](https://open-meteo.com/en/licence).
Il comando usa l'API pubblica gratuita, soggetta ai limiti e all'uso non
commerciale del servizio: per uso commerciale occorre un piano e una
successiva configurazione dell'endpoint cliente, qui non implementata.
Non sono richieste nuove dipendenze o credenziali API.

Test deterministici: `t/unit/carica_meteo.t`, `t/integration/carica_meteo.t`.
Quest'ultimo richiede `TEST_ONLINE` e `TEST_MYSQL=1` e crea solo database
temporanei. Per abilitare anche la prova con l'API reale:

```bash
TEST_MYSQL=1 docker compose --profile test run --rm -e TEST_OPEN_METEO=1 test prove -l t/unit/carica_meteo.t t/integration/carica_meteo.t
```

## Normalizzazione quote con meteo ARP: 10

`correggi_quote` integra le varianti legacy 1.0 e 1.0+lipo, adattando
esplicitamente la sorgente meteo all'ARP:

```bash
perl bin/procedure run correggi_quote --database radar_test --airport LIMC --date-from 2025-09-01 --date-to 2025-10-31
```

Richiede 08 e un'importazione 09 completata con provenienza verificabile;
supporta LIMC/LIML/LIME/LIPO, arrivi e decolli. Le date facoltative,
inclusive, si riferiscono a `data_ora_arr`; senza date considera tutto il
database. Salta i giorni gia completati salvo Sovrascrivi.

Usa pressione e temperatura dell'**ora contenente** `data_ora_arr`
(14:37 -> 14:00), come scelto dall'utente, non l'ora futura del legacy.
Mantiene la formula e l'esponente legacy 5.2525, usando pero la quota ARP
anziche quella della centralina. Non tronca le quote risultanti negative.
Non esegue chiamate Open-Meteo: riusa soltanto i dati di 09, verificandone
aeroporto, coordinate, quota e impronta. Meteo assente, ambiguo o non
verificabile produce avvisi e skip delle tracce, senza avanzarle a stato 3.

Seleziona normalmente `validation_bt=2`; Sovrascrivi include 2 e 3 e
ricalcola da Z_m. Aggiorna A_m per battute con Z_m non NULL e validation
diversa da N/A/NULL (include S, come il legacy), poi porta la traccia a 3.
Preserva H_m/Z_m/hmod, pista, SID e classificazioni. In Sovrascrivi
azzera A_m solo delle tracce analizzate e utilizzabili, non di quelle saltate.
I giorni con tracce saltate non sono segnati completi, consentendo il retry.

Analisi 0-50%, salvataggio 50-99%, riepilogo 99%, concluso 100% dopo
disconnect. AutoCommit: un errore puo lasciare scritture parziali.
Gli overwrite 03-06 e 08 eliminano anche A_m obsolete e invalidano lo
storico 10; 05/06 ripristinano bt=1 anche da bt=3, 08 ricalcola fino a bt=2.
07 resta indipendente. Nessuna modifica agli script legacy.

Verifiche: `t/unit/correggi_quote.t`, `t/integration/carica_meteo.t` e
`t/integration/validation_window.t`, con dati sintetici e database temporanei.

## Intervallo temporale e sovrascrittura: 03-08

I sei form espongono **Dal giorno**, **Al giorno** (estremi inclusi)
e **Sovrascrivi e azzera i risultati dipendenti**, disattivato per default.
07 e 08 hanno un'etichetta specifica per il proprio ricalcolo.
Le date sono facoltative ma vanno indicate entrambe: senza date si
considerano tutti i giorni del database. Sono disponibili anche da CLI/API
come `date_from`, `date_to`, `overwrite`:

```bash
perl bin/procedure run valida_tracce --database radar_test --airport LIME --date-from 2026-11-01 --date-to 2026-11-02
perl bin/procedure run valida_battute --database radar_test --date-from 2026-11-01 --date-to 2026-11-02 --overwrite
```

Per 03-06 e 08 il giorno e quello di `flay.data_ora_italy`, non `data` UTC.
**07 usa invece `flay.data_ora_arr`, come il relativo legacy**, per scelta
esplicita dell'utente; questo campo e calcolato da 04.
Una traccia selezionata e elaborata con
tutte le sue battute, anche se attraversa mezzanotte. Tracce senza data
nel campo di riferimento sono escluse con conteggio nei log; le tracce unite (`M`) non
vengono toccate. Selezioni, aggiornamento date, reset e riepiloghi
rispettano i soli giorni selezionati e non saltati.

Lo storico giornaliero e persistente in PostgreSQL (`validation_days`),
separato per server/porta MySQL, database e comando. Un giorno viene
saltato solo se una precedente esecuzione di quel comando risulta
**completata con successo**. Esecuzioni fallite, annullate o ancora in
corso non determinano skip. I risultati precedenti all'introduzione dello
storico non sono considerati automaticamente completamenti giornalieri;
restano comunque i normali filtri sui dati gia validati.
Per rielaborare nuovi dati importati in un giorno gia completato o cambiare
aeroporto/revisione, selezionare Sovrascrivi.

La sovrascrittura ricalcola il passaggio richiesto e azzera i dati dipendenti:

| Comando | Reset nei soli giorni elaborati |
|---|---|
| 03 | Classificazioni battute, validazione battute, date calcolate, pista e SID; ricalcola la validazione tracce |
| 04 | Conserva l'esito di 03, ricalcola battute e date; azzera pista e SID |
| 05 | Ripristina le battute `X` a `Y`, conserva l'esito di 04; ricalcola pista/SID degli arrivi |
| 06 | Conserva l'esito di 04; azzera pista/SID dei decolli e ricalcola la pista |
| 07 | Ricalcola solo la SID dei decolli, senza modificare pista, validazioni o battute |
| 08 | Ricalcola Z_m/hmod da H_m per arrivi e decolli con pista e validation_bt 1 o 2 |

Gli overwrite 03-06 azzerano anche Z_m/hmod dipendenti nei giorni e nelle
tracce interessate. Gli overwrite 05/06 accettano anche `validation_bt=2`,
riportandolo a 1 prima di riassegnare la pista. H_m resta invariato.

Per 04 sono ricalcolabili gli esiti `Y/L/D/P`, non gli scarti `N` di 03.
Per 05/06 sono ricalcolabili le tracce validate da 04 e quelle invalidate
dall'assegnazione pista (`P`, validation_bt=0, pista diagnostica `N*`).
Per queste ultime, l'esito precedente di 04 viene ricostruito dal numero
di battute `Y` (anche `X` per 05): 4-7 -> `L`, almeno 8 -> `Y`.
Meno di quattro battute bloccano il comando prima di modificare i dati.
Il reset riguarda questi stati, date, pista e SID: non annulla modifiche
alle coordinate/quote eventualmente eseguite da altri script legacy.

Ricalcolare 03 invalida anche lo storico di 04/05/06; ricalcolare 04 quello
di 05/06. 05 e 06 sono indipendenti; 07 dipende da 06 e dalle validazioni.
03-06 invalidano anche lo storico di 08 sui giorni locali; 07 e 08
non si invalidano reciprocamente, perche 07 usa H_m, non Z_m.
Per 03/04/06 si invalida anche lo storico di 07 nei giorni `data_ora_arr`
dei decolli interessati, che possono differire dai giorni locali scelti.
Per 03/04 si considerano anche i giorni delle rispettive battute: 04 puo
spostare la data calcolata dopo la riclassificazione. 05 non invalida 07.
L'invalidazione precede gli UPDATE:
un errore non lascia uno storico che faccia saltare risultati ormai
parziali. Le scritture MySQL restano in AutoCommit: dopo un'interruzione
verificare i log e rilanciare con Sovrascrivi. Le registrazioni giornaliere
sono valide solo se termina con successo l'intera esecuzione richiesta.

La migrazione PostgreSQL viene applicata automaticamente all'avvio
aggiornato di app/worker; non vengono aggiunte tabelle ai database radar.

## Avanzamento dei comandi 03-08

La barra include tutte le fasi: 0-50% analisi delle tracce, 50-99% salvataggio
nel database, 99% riepilogo finale e 100% al termine del comando.
Il salvataggio di 04 comprende gli stati di battute/tracce e le date
di decollo/atterraggio, mostrate come passaggi distinti.
Per 05/06 comprende piste, stati delle tracce ed eventuali battute `X`;
il 100% viene emesso solo dopo la chiusura della connessione.
Per 08 il salvataggio conta ogni aggiornamento delle quote e dello stato
della traccia; il 100% segue anche la registrazione dello storico.
Le scritture possono quindi richiedere tempo dopo l'analisi. Le percentuali indicano il lavoro
completato nelle fasi, non il tempo residuo stimato. Lo stato resta `running`
finche il comando non termina.

## Test locali

```bash
docker compose --profile test run --rm test
```

Il profilo locale `test` usa l'immagine di sviluppo e il servizio PostGIS già configurato.
La suite non fa parte delle verifiche GitHub Actions.

I test MyISAM reali sono opt-in: `TEST_MYSQL=1` crea e rimuove esclusivamente un
database dal nome univoco `sm_test_mysql_<pid>_<numero>` oppure
`sm_test_validation_<pid>_<numero>` sul server configurato.
Non leggono i file radar reali e non scrivono nel database operativo.
L'account di test deve poter creare/eliminare questi database e usare tutti i
privilegi necessari nelle sole tabelle di test; `local_infile` deve essere attivo.

```powershell
$env:TEST_MYSQL = '1'
docker compose --profile test run --rm test prove -l -Ilib t/integration/carica_myisam.t
docker compose --profile test run --rm test prove -l t/integration/validation_window.t
Remove-Item Env:\TEST_MYSQL
```

## Caricamenti MyISAM e gestione dei fallimenti

`flay`, `battute` e `battute_doppie` devono esistere ed essere tutte MyISAM oppure tutte InnoDB.
I motori misti non sono supportati. InnoDB mantiene la gestione transazionale;
MyISAM usa staging e compensazione, senza convertire le tabelle legacy.

La 02 ha un timeout ordinario di 3600 secondi dall'avvio. Nel modulo web
si puo confermare prima dell'avvio l'esecuzione senza timeout, solo per
quella richiesta. La checkbox e inizialmente deselezionata, la scelta e
registrata nel log e un normale Riesegui richiede una nuova conferma.
Restano attivi coda, cancellazione e controlli di recupero MyISAM; errori
o interruzioni possono comunque richiedere recupero dei dati.
Dopo un timeout effettivo, nel dettaglio e possibile confermare una nuova richiesta senza
timeout, con gli stessi parametri e nella stessa coda. La scelta e registrata
nel log e non si applica al normale Riesegui; la cancellazione rimane attiva.
Non e disponibile per errori di recupero o dati gia pubblicati.
Per gli storici con timeout e log di commit, pubblicazione o rollback fallito,
la conferma non e disponibile: verificare manualmente lo stato dei dati.
Prima di confermare verificare log, recupero e dati nel database: ripetere
un import gia pubblicato puo aggiungere battute doppie e i file OUT potrebbero
essere cambiati. Un cambio di host o porta MySQL impedisce la conferma.
Per InnoDB il timer viene disattivato immediatamente prima del commit, che
puo quindi superare il limite anche nella richiesta ordinaria; un rollback
fallito dopo timeout richiede una verifica e non offre il bypass.

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
idempotente. Dentro ogni record OUT, invece, le ripetizioni identiche dello
stesso campione di 24 caratteri vengono ignorate, anche se non consecutive,
mantenendo la prima occorrenza. Ogni scarto produce un WARNING con file,
riga, volo, data, ora della battuta e posizioni della ripetizione e della
prima occorrenza. Il riepilogo e `skipped_hits` riportano gli scarti; `hits`
e `duplicate_hits` contano solo le battute effettivamente caricate.
Questa deduplica vale sia per `battute` sia per `battute_doppie`, ma non
confronta record OUT diversi. Campioni non identici che producono la stessa
chiave convertita, input malformati e warning SQL restano bloccanti.
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

La pagina di dettaglio dell'esecuzione mostra solo gli ultimi 25 eventi,
ordinati per data/ora decrescente (a parita, ID decrescente). Lo storico
completo resta conservato nel database e disponibile nell'API.

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
dipendono dalle decisioni aperte della sezione 20 del documento di analisi;
l'utente e `anonymous`. Il deployment corrente consente esplicitamente
l'accesso da LAN fidata senza login: non e adatto a Internet o reti non fidate.
Per questi contesti occorre prima introdurre un accesso autenticato.
