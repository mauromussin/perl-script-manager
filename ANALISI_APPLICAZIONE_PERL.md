# Documento di analisi e specifica tecnica

## Applicazione Perl per l'esecuzione guidata di procedure e script

**Stato del documento:** bozza iniziale per lo sviluppo assistito con GitHub Copilot in Visual Studio Code  
**Versione:** 0.1.0  
**Ambiente previsto:** Docker, Visual Studio Code Dev Containers, Perl, Mojolicious, Minion, PostgreSQL  

---

## 1. Scopo del documento

Questo documento descrive i requisiti, l'architettura e il piano di lavoro per trasformare un insieme di script Perl esistenti in un'applicazione strutturata, utilizzabile tramite interfaccia web e sviluppabile direttamente in Visual Studio Code.

Il repository conterrà:

- il codice della nuova applicazione;
- gli script Perl esistenti da analizzare e revisionare;
- la configurazione Docker e Dev Container;
- i moduli Perl estratti dagli script originali;
- i test automatici;
- la documentazione tecnica e operativa;
- le procedure di migrazione progressiva dal codice legacy.

Questo file deve essere utilizzato come documento di riferimento da GitHub Copilot. Copilot dovrà rispettare i vincoli e le decisioni indicate, senza modificare arbitrariamente struttura, nomi, interfacce o comportamento degli script esistenti.

---

## 2. Obiettivo del progetto

Realizzare un'applicazione web locale o distribuita che permetta all'utente di:

1. scegliere una procedura disponibile;
2. inserire o selezionare i parametri richiesti;
3. validare i parametri prima dell'esecuzione;
4. avviare una procedura composta da uno o più passaggi;
5. visualizzare stato, avanzamento e log;
6. interrompere un'elaborazione, quando tecnicamente possibile;
7. consultare lo storico delle esecuzioni;
8. scaricare gli eventuali file prodotti;
9. identificare chiaramente errori, avvisi e risultati;
10. rieseguire una procedura utilizzando parametri già impiegati.

Gli script Perl attuali rappresentano il comportamento funzionale di partenza. Dovranno essere conservati nel repository, inventariati, analizzati e revisionati progressivamente.

---

## 3. Principi progettuali obbligatori

### 3.1 Conservazione del comportamento esistente

La revisione non deve cambiare il risultato funzionale degli script senza una decisione esplicita e documentata.

Per ogni script legacy devono essere registrati:

- scopo;
- input;
- output;
- parametri;
- dipendenze;
- accessi a file e database;
- variabili d'ambiente;
- programmi esterni richiamati;
- codici di uscita;
- messaggi prodotti;
- effetti collaterali;
- condizioni di errore;
- durata e consumo prevedibile di risorse.

Prima del refactoring devono essere predisposti test di caratterizzazione, ove possibile. Tali test devono descrivere il comportamento attuale, anche quando il codice originario non è ancora ben strutturato.

### 3.2 Separazione delle responsabilità

La logica applicativa non deve essere inserita direttamente nei controller web.

La soluzione deve distinguere almeno:

- interfaccia web;
- validazione degli input;
- orchestrazione delle procedure;
- logica dei singoli comandi;
- esecuzione asincrona;
- persistenza;
- gestione di file e risultati;
- logging;
- configurazione;
- autenticazione e autorizzazione, se richieste.

### 3.3 Riutilizzo della logica

La stessa procedura deve poter essere richiamata, quando opportuno, da:

- interfaccia web;
- worker Minion;
- comando CLI;
- test automatici.

La logica deve quindi risiedere in moduli sotto `lib/`, non nei template, nei controller o in script monolitici.

### 3.4 Sicurezza

Non è consentito costruire comandi shell concatenando stringhe provenienti dall'utente.

Sono obbligatori:

- lista chiusa delle operazioni ammesse;
- validazione dei parametri;
- argomenti passati come lista, senza shell intermedia;
- percorsi controllati;
- timeout;
- cattura separata di standard output e standard error;
- utente container non privilegiato;
- credenziali escluse dal repository;
- nessuna variabile d'ambiente sensibile salvata in chiaro nei file versionati;
- principio del privilegio minimo per database e filesystem.

### 3.5 Riproducibilità

L'ambiente deve poter essere ricreato dal repository mediante Docker Compose.

Devono essere versionati:

- `Dockerfile`;
- `compose.yaml`;
- `cpanfile`;
- `cpanfile.snapshot`;
- configurazione Dev Container;
- migrazioni del database;
- configurazioni di esempio prive di segreti.

---

## 4. Scelte tecnologiche

| Area | Tecnologia prevista | Motivazione |
|---|---|---|
| Linguaggio | Perl 5 | Compatibilità con gli script attuali |
| Framework web | Mojolicious | Framework Perl completo, leggero e adatto anche a WebSocket e API |
| Job asincroni | Minion | Integrazione nativa con Mojolicious e persistenza dei job |
| Database | PostgreSQL | Affidabilità, concorrenza, storico delle esecuzioni e backend Minion |
| Accesso al database | DBI e DBD::Pg | Accesso standard e controllabile a PostgreSQL |
| Dipendenze | Carton e `cpanfile` | Ambiente Perl riproducibile |
| Container | Docker Compose | Isolamento e riproducibilità |
| IDE | Visual Studio Code | Sviluppo nel repository e integrazione Dev Containers |
| Test web | Test::Mojo | Test delle route e dell'interfaccia Mojolicious |
| Test applicativi | Test2::V0 o Test::More | Test unitari e di integrazione |
| Formattazione | Perl::Tidy | Uniformità del codice |
| Analisi statica | Perl::Critic | Controlli di qualità configurabili |
| Validazione | JSON::Validator | Schemi formali per input e API |
| Logging | Log::Any | Astrazione del logging applicativo |

Le versioni definitive dovranno essere fissate nel `cpanfile.snapshot`. Non devono essere introdotte nuove dipendenze senza motivazione e aggiornamento della documentazione.

---

## 5. Architettura logica

```text
Browser
  |
  v
Mojolicious
  |
  +-- Controller web/API
  |     |
  |     +-- validazione input
  |     +-- autorizzazione
  |     +-- creazione job o esecuzione breve
  |
  +-- Service / Procedure Registry
  |     |
  |     +-- elenco operazioni consentite
  |     +-- metadati e schema parametri
  |     +-- orchestrazione dei passaggi
  |
  +-- Minion
        |
        +-- worker
              |
              +-- moduli Command
              +-- accesso database
              +-- filesystem controllato
              +-- programmi esterni autorizzati
```

Le operazioni brevi e prive di effetti rilevanti possono essere eseguite nella richiesta HTTP. Le elaborazioni lunghe, concorrenti, interrompibili o che producono file devono essere eseguite come job Minion.

---

## 6. Struttura prevista del repository

```text
repository/
├── .devcontainer/
│   └── devcontainer.json
├── .github/
│   ├── copilot-instructions.md
│   └── workflows/
│       └── test.yml
├── .vscode/
│   ├── settings.json
│   └── tasks.json
├── bin/
│   ├── app
│   ├── worker
│   └── procedure
├── config/
│   ├── application.example.yml
│   └── procedures.yml
├── docs/
│   ├── ANALISI_APPLICAZIONE.md
│   ├── INVENTARIO_SCRIPT.md
│   ├── MIGRAZIONE_SCRIPT.md
│   └── ADR/
├── legacy/
│   ├── README.md
│   └── scripts/
├── lib/
│   └── ScriptManager/
│       ├── Controller/
│       ├── Command/
│       ├── Service/
│       ├── Repository/
│       ├── Model/
│       ├── Validation/
│       └── Exception/
├── migrations/
├── public/
├── script/
├── t/
│   ├── unit/
│   ├── integration/
│   ├── characterization/
│   └── fixtures/
├── templates/
├── var/
│   ├── input/.gitkeep
│   ├── output/.gitkeep
│   └── logs/.gitkeep
├── .dockerignore
├── .editorconfig
├── .gitignore
├── .perlcriticrc
├── .perltidyrc
├── compose.yaml
├── cpanfile
├── cpanfile.snapshot
├── Dockerfile
├── LICENSE
└── README.md
```

### 6.1 Directory `legacy/`

Gli script originali devono essere inizialmente copiati in `legacy/scripts/` senza modificarli. La provenienza e l'eventuale versione devono essere annotate in `legacy/README.md`.

Non inserire in Git:

- password;
- token;
- chiavi private;
- stringhe di connessione contenenti credenziali;
- file con dati personali o riservati;
- dump di database;
- output operativi non anonimizzati;
- variabili d'ambiente salvate in chiaro.

Se uno script contiene credenziali o dati sensibili, questi elementi devono essere rimossi prima del commit e sostituiti con riferimenti a configurazione esterna.

---

## 7. Inventario obbligatorio degli script esistenti

Per ogni file presente in `legacy/scripts/` aggiungere una sezione in `docs/INVENTARIO_SCRIPT.md` con il seguente schema:

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

L'analisi deve essere basata sul codice reale. Non inventare parametri, dipendenze o comportamenti non verificati.

---

## 8. Strategia di revisione degli script Perl

### Fase 1: acquisizione controllata

1. Copiare gli script in `legacy/scripts/`.
2. Rimuovere preventivamente credenziali e dati sensibili.
3. Conservare nome e contenuto funzionale originari.
4. Registrare hash, origine e data di acquisizione, se utili alla tracciabilità.
5. Non eseguire script non ancora analizzati contro ambienti reali.

### Fase 2: analisi statica

Per ciascuno script verificare:

- presenza di `use strict;` e `use warnings;`;
- variabili globali;
- input non validati;
- concatenazione di comandi shell;
- uso di `system`, backtick, `qx`, `eval` e `open` con pipe;
- credenziali incorporate;
- percorsi assoluti;
- file temporanei non sicuri;
- SQL costruito mediante concatenazione;
- transazioni mancanti;
- gestione incompleta degli errori;
- assenza di timeout;
- assenza di controllo dei codici di uscita;
- comportamento dipendente dalla directory corrente;
- assunzioni sul sistema operativo;
- codifica dei file;
- concorrenza e possibili race condition.

### Fase 3: test di caratterizzazione

Prima di cambiare il comportamento:

1. predisporre fixture non sensibili;
2. eseguire lo script in ambiente isolato;
3. acquisire standard output, standard error, file prodotti e codice di uscita;
4. scrivere test che descrivano il comportamento osservato;
5. documentare i casi non riproducibili.

### Fase 4: estrazione della logica

La logica deve essere trasferita in moduli con interfacce esplicite. Esempio:

```perl
package ScriptManager::Command::Example;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;

    return bless {
        logger => $args{logger},
    }, $class;
}

sub run {
    my ($self, %args) = @_;

    my $input = $args{input};
    die 'Parametro input mancante' if !defined $input || $input eq '';

    return {
        success => 1,
        message => 'Operazione completata',
        data    => {},
    };
}

1;
```

Gli script CLI residui devono diventare adattatori sottili che:

1. leggono gli argomenti;
2. caricano la configurazione;
3. invocano il modulo;
4. stampano il risultato;
5. restituiscono un codice di uscita coerente.

### Fase 5: integrazione applicativa

La procedura revisionata viene registrata nel catalogo dell'applicazione con:

- identificatore stabile;
- nome visualizzato;
- descrizione;
- schema dei parametri;
- ruolo richiesto;
- classe Perl associata;
- tipo di esecuzione, sincrono o asincrono;
- timeout;
- directory di output;
- politica di conservazione;
- possibilità di annullamento.

### Fase 6: dismissione del legacy

Uno script può essere dichiarato migrato solo quando:

- i test di caratterizzazione sono superati o le differenze sono approvate;
- la nuova implementazione ha test unitari e di integrazione;
- gli input sono validati;
- errori e log sono gestiti;
- la procedura è documentata;
- non dipende da credenziali incorporate;
- è eseguibile nel container;
- il comportamento è verificato tramite CLI e, se prevista, interfaccia web.

---

## 9. Requisiti funzionali

### RF-01 Catalogo delle procedure

L'applicazione deve mostrare esclusivamente le procedure registrate e abilitate. Non deve consentire di specificare liberamente il percorso di uno script.

### RF-02 Maschera dinamica dei parametri

Ogni procedura deve dichiarare i parametri necessari mediante uno schema. L'interfaccia deve generare o configurare i controlli coerentemente con lo schema.

I tipi minimi previsti sono:

- testo;
- numero intero o decimale;
- booleano;
- data e ora;
- scelta singola;
- scelta multipla;
- caricamento file;
- selezione di una risorsa autorizzata.

### RF-03 Validazione

La validazione deve avvenire sia nel browser, per usabilità, sia sul server, per sicurezza. La validazione lato browser non è sufficiente.

### RF-04 Avvio di un'esecuzione

Ogni avvio deve generare un identificatore univoco e registrare almeno:

- procedura;
- utente, se disponibile;
- data e ora;
- parametri non sensibili;
- stato;
- progressione;
- inizio e fine;
- esito;
- riferimenti ai log;
- file prodotti.

### RF-05 Stato e avanzamento

Gli stati minimi sono:

```text
queued
running
completed
failed
cancel_requested
cancelled
timed_out
```

L'avanzamento percentuale deve essere mostrato solo quando il processo può calcolarlo in modo attendibile. In caso contrario utilizzare passaggi nominali o uno stato indeterminato.

### RF-06 Logging

I log devono distinguere:

- informazione;
- avviso;
- errore;
- diagnostica tecnica.

I log mostrati all'utente non devono esporre password, token, stringhe di connessione o dettagli riservati.

### RF-07 File prodotti

I file devono essere associati all'esecuzione che li ha generati. Il download deve verificare autorizzazione, esistenza, percorso e nome del file.

### RF-08 Storico

Lo storico deve essere filtrabile almeno per:

- procedura;
- stato;
- intervallo temporale;
- utente, se previsto;
- identificatore dell'esecuzione.

### RF-09 Riesecuzione

La riesecuzione deve creare un nuovo record. Non deve sovrascrivere il record precedente. I parametri sensibili non devono essere riproposti automaticamente.

### RF-10 CLI

Deve esistere un comando CLI per elencare e avviare le procedure utilizzando gli stessi moduli applicativi dell'interfaccia web.

Esempio atteso:

```bash
carton exec perl bin/procedure list
carton exec perl bin/procedure run procedure_id --input file.csv
carton exec perl bin/procedure status execution_id
```

---

## 10. Requisiti non funzionali

### RNF-01 Portabilità

Il progetto deve funzionare nel container Linux senza dipendere dall'installazione locale di Perl su Windows.

### RNF-02 Riproducibilità

Una nuova postazione deve poter avviare l'ambiente usando il repository, Docker e Visual Studio Code con Dev Containers.

### RNF-03 Osservabilità

Ogni esecuzione deve essere tracciata con un identificatore correlabile nei log.

### RNF-04 Robustezza

Un errore in una procedura non deve terminare il server web o compromettere altri job.

### RNF-05 Concorrenza

Il numero di worker deve essere configurabile. Le procedure non sicure in concorrenza devono dichiarare un vincolo o un lock esplicito.

### RNF-06 Manutenibilità

Ogni modulo deve avere una responsabilità chiara. Evitare file monolitici, duplicazioni e dipendenze circolari.

### RNF-07 Testabilità

Accesso al database, filesystem, orologio e processi esterni devono essere isolabili o sostituibili nei test.

---

## 11. Modello dati iniziale

Il modello definitivo dovrà essere formalizzato tramite migrazioni. Le entità minime previste sono:

### `procedures`

- `id`;
- `code`, univoco e stabile;
- `name`;
- `description`;
- `enabled`;
- `handler_class`;
- `execution_mode`;
- `timeout_seconds`;
- `parameter_schema`;
- `created_at`;
- `updated_at`.

### `executions`

- `id` UUID;
- `procedure_id`;
- `minion_job_id`;
- `requested_by`;
- `status`;
- `parameters` opportunamente filtrati;
- `progress`;
- `current_step`;
- `requested_at`;
- `started_at`;
- `finished_at`;
- `exit_code`;
- `summary`;
- `error_code`;
- `error_message`.

### `execution_events`

- `id`;
- `execution_id`;
- `level`;
- `event_type`;
- `message`;
- `metadata`;
- `created_at`.

### `execution_artifacts`

- `id`;
- `execution_id`;
- `original_name`;
- `stored_name`;
- `media_type`;
- `size_bytes`;
- `sha256`;
- `relative_path`;
- `created_at`;
- `expires_at`.

I nomi e i tipi definitivi devono essere approvati prima della generazione delle migrazioni.

---

## 12. Gestione dei processi esterni

Quando non è possibile incorporare la logica in un modulo Perl, utilizzare un servizio dedicato all'esecuzione controllata.

Requisiti minimi:

- eseguibile selezionato da una mappa interna;
- percorso assoluto;
- argomenti passati come lista;
- nessuna interpretazione mediante shell;
- directory di lavoro esplicita;
- ambiente ridotto alle sole variabili necessarie;
- timeout;
- limite alla dimensione dell'output;
- cattura di `stdout` e `stderr`;
- controllo del codice di uscita;
- terminazione del processo e degli eventuali figli in caso di timeout;
- registrazione dell'esito senza dati sensibili.

Esempio concettuale sicuro:

```perl
my @command = (
    '/usr/local/bin/approved-command',
    '--input',
    $validated_input,
);
```

Esempio vietato:

```perl
system("approved-command --input $user_input");
```

---

## 13. Configurazione e segreti

La configurazione deve essere suddivisa in:

1. valori pubblici e versionabili;
2. valori specifici dell'ambiente;
3. segreti.

Nel repository deve essere presente solo un file di esempio, per esempio:

```text
config/application.example.yml
```

Sono vietati file reali contenenti credenziali. Il file `.gitignore` deve escludere almeno:

```text
.env
.env.*
!.env.example
config/application.yml
var/input/*
var/output/*
var/logs/*
!var/input/.gitkeep
!var/output/.gitkeep
!var/logs/.gitkeep
```

In sviluppo locale i segreti possono essere forniti esternamente al repository. In produzione adottare Docker secrets, un secret manager o variabili protette del sistema di distribuzione.

---

## 14. Container e ambiente di sviluppo

### 14.1 Servizi Docker Compose

Sono previsti almeno:

- `app`: server Mojolicious in modalità sviluppo o produzione;
- `worker`: worker Minion;
- `database`: PostgreSQL;
- eventuale servizio di test separato.

Il codice sorgente può essere montato come volume in sviluppo. In produzione deve essere incluso in un'immagine immutabile.

### 14.2 Dev Container

Il Dev Container deve aprire il workspace nel servizio `app` e fornire:

- Perl;
- Carton;
- moduli del progetto;
- `perltidy`;
- `perlcritic`;
- client PostgreSQL;
- strumenti Git essenziali;
- terminale Bash;
- estensione Perl per Visual Studio Code.

### 14.3 Utente non privilegiato

L'immagine finale deve eseguire applicazione e worker con un utente non root. Le directory di input, output e log devono avere permessi espliciti e minimi.

---

## 15. Strategia di test

### 15.1 Test di caratterizzazione

Descrivono il comportamento degli script originari e proteggono da modifiche involontarie.

### 15.2 Test unitari

Devono coprire almeno:

- validazione;
- trasformazione dei parametri;
- logica dei comandi;
- gestione degli errori;
- generazione dei risultati;
- normalizzazione dei percorsi.

### 15.3 Test di integrazione

Devono verificare:

- accesso al database;
- migrazioni;
- creazione e completamento dei job;
- filesystem di input e output;
- processi esterni simulati o controllati.

### 15.4 Test web

Con `Test::Mojo` verificare almeno:

- pagina del catalogo;
- dettaglio procedura;
- validazione dei form;
- avvio dell'esecuzione;
- pagina di stato;
- gestione degli errori;
- download controllato degli artefatti.

### 15.5 Test di sicurezza

Prevedere casi relativi a:

- path traversal;
- command injection;
- SQL injection;
- caricamento di file non ammessi;
- nomi file anomali;
- input troppo grandi;
- accesso a esecuzioni di altri utenti;
- esposizione di segreti nei log.

---

## 16. Qualità del codice

Tutto il codice Perl nuovo o modificato deve:

- usare `strict` e `warnings`;
- essere formattabile con `perltidy`;
- superare i controlli `perlcritic` concordati;
- evitare variabili globali non necessarie;
- gestire esplicitamente errori e codici di uscita;
- usare placeholder SQL;
- includere test;
- avere nomi coerenti con il dominio;
- non contenere credenziali;
- non dipendere implicitamente dalla directory corrente;
- non affidarsi a moduli installati manualmente fuori da `cpanfile`.

Non effettuare refactoring puramente stilistici insieme a modifiche funzionali importanti. Le modifiche devono essere suddivise in commit verificabili.

---

## 17. Istruzioni operative per GitHub Copilot

GitHub Copilot deve operare secondo le seguenti regole:

1. Leggere questo documento prima di proporre modifiche architetturali.
2. Analizzare i file reali presenti nel repository prima di generare codice.
3. Non inventare il comportamento degli script legacy.
4. Non rinominare file, moduli, parametri, tabelle o variabili senza motivazione esplicita.
5. Conservare le parti funzionanti e modificare soltanto ciò che è necessario.
6. Quando modifica un file, restituire o applicare il contenuto completo e sintatticamente valido.
7. Non inserire placeholder vaghi quali `TODO: implementare` quando è possibile implementare il comportamento richiesto.
8. Non introdurre segreti o valori sensibili nei file.
9. Aggiungere o aggiornare i test insieme al codice.
10. Segnalare chiaramente ogni assunzione.
11. Distinguere tra comportamento verificato, comportamento dedotto e proposta progettuale.
12. Non richiamare una shell con input controllabile dall'utente.
13. Non aggiungere dipendenze CPAN senza aggiornare `cpanfile` e documentarne la ragione.
14. Non modificare simultaneamente più script legacy senza completare inventario e test di quello in lavorazione.
15. Preferire modifiche piccole, verificabili e reversibili.
16. Eseguire, quando disponibili, i comandi di test, lint e controllo sintattico.
17. Riportare gli errori dei comandi senza nasconderli o sostituirli con risultati ipotetici.
18. Non considerare completata una migrazione finché non sono soddisfatti i criteri di accettazione.

### Prompt operativo suggerito per Copilot Chat

```text
Leggi docs/ANALISI_APPLICAZIONE.md e rispetta integralmente i vincoli descritti.
Analizza il repository senza modificare i file. Inizia dagli script presenti in
legacy/scripts e prepara docs/INVENTARIO_SCRIPT.md basandoti esclusivamente sul
codice reale. Evidenzia dipendenze, input, output, effetti collaterali, accessi a
file o database, chiamate a processi esterni, rischi e punti non determinabili.
Non effettuare ancora il refactoring. Proponi poi un ordine di migrazione motivato.
```

### Prompt per la migrazione di un singolo script

```text
Analizza esclusivamente legacy/scripts/NOME_SCRIPT.pl insieme ai file da cui
dipende. Aggiorna la relativa sezione in docs/INVENTARIO_SCRIPT.md. Predisponi
test di caratterizzazione con fixture non sensibili. Solo dopo i test, proponi
l'estrazione della logica in un modulo sotto lib/ScriptManager/Command/.
Mantieni invariato il comportamento verificato e segnala ogni differenza.
Non inserire credenziali, non costruire comandi shell tramite concatenazione e
non modificare altri script legacy.
```

---

## 18. Piano di implementazione

### Milestone 1: inizializzazione

- creare la struttura del repository;
- aggiungere `.gitignore`, `.dockerignore` ed `.editorconfig`;
- creare `Dockerfile`, `compose.yaml` e Dev Container;
- predisporre `cpanfile`;
- verificare l'avvio di una pagina Mojolicious minima;
- verificare connessione a PostgreSQL;
- predisporre pipeline di test.

### Milestone 2: acquisizione legacy

- importare gli script dopo la rimozione dei dati sensibili;
- compilare l'inventario;
- identificare dipendenze e ordine di migrazione;
- individuare script non eseguibili in Linux o dipendenti da Windows.

### Milestone 3: nucleo applicativo

- creare registro delle procedure;
- definire schema dei parametri;
- implementare modello delle esecuzioni;
- integrare Minion;
- creare catalogo, form di avvio e pagina di stato;
- implementare logging correlato.

### Milestone 4: prima migrazione completa

- scegliere uno script a basso rischio;
- creare test di caratterizzazione;
- estrarre la logica in un modulo;
- creare adattatore CLI;
- integrare la procedura nell'applicazione;
- validare equivalenza e gestione degli errori.

### Milestone 5: artefatti e storico

- gestire file di input e output;
- implementare checksum e download controllato;
- completare filtri dello storico;
- definire politiche di conservazione.

### Milestone 6: consolidamento

- migrare gli altri script uno alla volta;
- aumentare copertura dei test;
- revisionare sicurezza e permessi;
- definire configurazione di produzione;
- completare documentazione operativa.

---

## 19. Criteri di accettazione della prima versione

La prima versione è accettabile quando:

- l'ambiente si apre tramite VS Code Dev Containers;
- `docker compose up` avvia applicazione, worker e database;
- l'applicazione mostra il catalogo delle procedure;
- almeno uno script è stato migrato senza perdita di comportamento approvato;
- i parametri sono validati lato server;
- l'esecuzione lunga avviene tramite Minion;
- stato, log ed esito sono consultabili;
- gli eventuali file prodotti sono scaricabili in modo controllato;
- esistono test unitari, di integrazione e web;
- non sono presenti credenziali o dati sensibili nel repository;
- il container non esegue l'applicazione come root;
- il codice supera controllo sintattico, test e regole di qualità concordate;
- la procedura può essere eseguita anche tramite CLI;
- la documentazione permette a un nuovo sviluppatore di avviare l'ambiente.

---

## 20. Decisioni ancora necessarie

Prima della configurazione di produzione devono essere definite:

- numero e tipologia degli utenti;
- necessità di autenticazione;
- ruoli e autorizzazioni;
- ambiente di distribuzione;
- accesso dalla sola macchina locale o dalla rete;
- database e sistemi esterni coinvolti;
- dimensione massima dei file;
- durata massima dei job;
- numero massimo di esecuzioni concorrenti;
- politiche di backup;
- periodo di conservazione di log e artefatti;
- natura dei dati trattati;
- eventuali vincoli Windows degli script esistenti;
- necessità di PostGIS oltre a PostgreSQL;
- modalità di gestione e rotazione dei segreti.

Questi punti non bloccano l'inventario e la prima migrazione, ma impediscono di considerare definitiva l'architettura di produzione.

---

## 21. Primo flusso di lavoro nel repository

Dopo aver creato e aperto il nuovo repository in Visual Studio Code:

1. copiare questo file in `docs/ANALISI_APPLICAZIONE.md`;
2. creare `.github/copilot-instructions.md` con un richiamo sintetico alle regole della sezione 17;
3. creare `legacy/scripts/`;
4. rimuovere dagli script qualsiasi credenziale o dato sensibile;
5. copiare gli script originali in `legacy/scripts/`;
6. chiedere a GitHub Copilot di analizzarli senza modificarli;
7. revisionare manualmente `docs/INVENTARIO_SCRIPT.md`;
8. stabilire l'ordine di migrazione;
9. iniziare da uno script semplice, riproducibile e con pochi effetti collaterali;
10. realizzare i test di caratterizzazione prima del refactoring.

---

## 22. Risultato atteso

Il risultato finale non sarà un semplice lanciatore di file `.pl`, ma una piattaforma controllata nella quale ogni procedura:

- è registrata esplicitamente;
- dichiara i propri parametri;
- valida gli input;
- produce log strutturati;
- viene eseguita in modo isolato e tracciabile;
- conserva risultato e artefatti;
- può essere testata senza l'interfaccia web;
- rimane richiamabile da CLI;
- non espone all'utente una shell o un percorso arbitrario;
- può evolvere senza duplicare la logica applicativa.

La migrazione deve essere progressiva. Gli script esistenti restano disponibili come riferimento fino alla verifica completa della nuova implementazione, ma non devono essere esposti direttamente all'utente finale senza validazione, controllo e tracciamento.
