use Mojo::Base -strict, -signatures;
use utf8;
use Test::More;
use DBI;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper;
use Mojo::JSON qw(true false);
use ScriptManager::Service::CorrelazioneSetup;
use ScriptManager::Service::CorrelazioneReview;

plan skip_all => 'Richiede PostgreSQL e MySQL isolato dedicato al test'
    unless TestHelper::online() && ($ENV{TEST_EVENTI_ISOLATED_MYSQL} // '') eq '1';

my $dsn = 'DBI:MariaDB:host=' . ($ENV{MYSQL_HOST} // '') . ';port=' . ($ENV{MYSQL_PORT} // 3306);
my $db = DBI->connect($dsn, $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD}, {RaiseError => 1, PrintError => 0});
my @schemas = qw(anagrafica bgy_2024_bruma bgy_2025_bruma bgy_2026_bruma lin_2026_bruma);
my @created;
END {
    if ($db) {
        $db->do('DROP DATABASE ' . $db->quote_identifier($_)) for reverse @created;
        $db->disconnect;
    }
}
for my $schema (@schemas) {
    die "Il test richiede un server isolato senza $schema\n"
        if $db->selectrow_array('SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = ?', undef, $schema);
}
for my $schema (@schemas) {
    $db->do('CREATE DATABASE ' . $db->quote_identifier($schema));
    push @created, $schema;
}
$db->do('CREATE TABLE anagrafica.aeroporti (row_id INT PRIMARY KEY, nome_aerop VARCHAR(4))');
$db->do('CREATE TABLE anagrafica.stazioni (row_id INT PRIMARY KEY, aeroporti_id INT, c_cab INT, '
    . 'name VARCHAR(25), X_m DOUBLE, Y_m DOUBLE, H_m DOUBLE)');
$db->do('CREATE TABLE anagrafica.stazioni_sid (stazioni_id INT, sid VARCHAR(5))');
$db->do('CREATE TABLE anagrafica.correla_log (IdLog BIGINT AUTO_INCREMENT PRIMARY KEY, DataCorr DATETIME, '
    . 'DatabaseCorr VARCHAR(100), IdStazione INT, DataInizio DATE, DataFine DATE, CorrNumber INT, '
    . 'MaxTimeIn INT, MaxTimeAdv INT, MaxDistance DOUBLE) ENGINE=MyISAM');
$db->do("INSERT INTO anagrafica.aeroporti VALUES (1,'LIME'),(2,'LIML')");
$db->do("INSERT INTO anagrafica.stazioni VALUES (1,1,204,'Bergamo',0,0,0),(2,2,205,'Linate',0,0,0)");
$db->do("INSERT INTO anagrafica.stazioni_sid VALUES (204,'A')");
$db->do('CREATE TABLE bgy_2024_bruma.st_eventi_cmp (row_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY, '
    . 'id_centralina_cmp INT NOT NULL, Data_ora DATETIME NOT NULL, Durata INT NOT NULL, '
    . 'Leq DOUBLE NOT NULL, Sel DOUBLE) ENGINE=MyISAM');
$db->do('CREATE TABLE bgy_2024_bruma.battute_eventi_cmp (row_id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY, '
    . 'flay_id INT UNSIGNED, battuta_id INT UNSIGNED, evento_cmp_id INT UNSIGNED, distance DOUBLE, shift SMALLINT)');
for my $type (['bgy_2024_bruma', 'st_lva', 'data_lva'], ['bgy_2025_bruma', 'st_lvan', 'data_lvan']) {
    my ($schema, $table, $date) = @$type;
    $db->do("CREATE TABLE $schema.$table (row_id BIGINT AUTO_INCREMENT PRIMARY KEY, data_calc DATE NOT NULL, "
        . "id_stazione INT NOT NULL, $date DATE NOT NULL, correlato TINYINT NOT NULL, "
        . "valore DOUBLE NOT NULL, id_log BIGINT NOT NULL, "
        . "attuale TINYINT UNSIGNED NOT NULL DEFAULT 0, validita CHAR(11) NOT NULL DEFAULT '0') ENGINE=MyISAM");
}
$db->do('CREATE TABLE bgy_2026_bruma.flay (row_id INT PRIMARY KEY, sid VARCHAR(5), validation_bt INT) ENGINE=MyISAM');
$db->do('CREATE TABLE bgy_2026_bruma.battute (row_id INT PRIMARY KEY, flay_id INT, X_m DOUBLE, Y_m DOUBLE, '
    . 'A_m DOUBLE, validation CHAR(1), time_italy DATETIME) ENGINE=MyISAM');
$db->do("INSERT INTO bgy_2026_bruma.flay VALUES (10,'A',3)");
$db->do("INSERT INTO bgy_2026_bruma.battute VALUES (100,10,3,4,0,'Y','2024-05-20 23:00:10')");

my $t = TestHelper::mojo();
my $app = $t->app;
my $setup = ScriptManager::Service::CorrelazioneSetup->new(repo => $app->repo);
is_deeply $setup->databases('LIME'), [qw(bgy_2024_bruma bgy_2025_bruma bgy_2026_bruma)],
    'database filtrati per aeroporto e convenzione';
eval { $setup->preview('LIME', 'lin_2026_bruma') };
ok(ScriptManager::Exception->caught($@, 'invalid_database'), 'database di un altro aeroporto rifiutato');

my $page = '/procedures/correla_eventi_cmp?airport=LIME&database=bgy_2026_bruma';
$t->get_ok($page)->status_is(200)->content_like(qr/Tabelle mancanti/)
    ->element_exists('input[name=confirm_schema][required]');
my $token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
my @missing = qw(battute_eventi_cmp st_eventi_cmp st_lva st_lvan);
$t->post_ok('/procedures/correla_eventi_cmp/prepare' => form => {
    airport => 'LIME', database => 'bgy_2026_bruma', missing_table => \@missing, confirm_schema => 1,
})->status_is(403, 'richiede CSRF');
$t->post_ok('/procedures/correla_eventi_cmp/prepare' => form => {
    csrf_token => $token, airport => 'LIME', database => 'bgy_2026_bruma', missing_table => \@missing,
})->status_is(422, 'richiede conferma creazione');
$t->post_ok('/procedures/correla_eventi_cmp/prepare' => form => {
    csrf_token => $token, airport => 'LIME', database => 'bgy_2026_bruma', missing_table => ['st_lva'],
    confirm_schema => 1,
})->status_is(422, 'elenco modificato rifiutato');
is $db->selectrow_array('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? '
    . 'AND TABLE_NAME IN (?,?,?,?)', undef, 'bgy_2026_bruma', @missing), 0, 'nessuna creazione parziale';
{
    my $queue_db = $app->pg->db;
    my $queue_tx = $queue_db->begin;
    $queue_db->query('select pg_advisory_xact_lock(hashtextextended(?, 0))',
        'database-queue:' . lc($ENV{MYSQL_HOST}) . ':' . ($ENV{MYSQL_PORT} // 3306) . ':bgy_2026_bruma');
    $t->post_ok('/procedures/correla_eventi_cmp/prepare' => form => {
        csrf_token => $token, airport => 'LIME', database => 'bgy_2026_bruma', missing_table => \@missing,
        confirm_schema => 1,
    })->status_is(422, 'creazione rifiutata con database occupato')->content_like(qr/Database occupato/);
    is $db->selectrow_array('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? '
        . 'AND TABLE_NAME IN (?,?,?,?)', undef, 'bgy_2026_bruma', @missing), 0, 'nessuna tabella creata';
    $queue_tx->commit;
}
$t->post_ok('/procedures/correla_eventi_cmp/prepare' => form => {
    csrf_token => $token, airport => 'LIME', database => 'bgy_2026_bruma', missing_table => \@missing,
    confirm_schema => 1,
})->status_is(302);
is $db->selectrow_array('SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? '
    . 'AND TABLE_NAME IN (?,?,?,?)', undef, 'bgy_2026_bruma', @missing),
    4, 'create solo le tabelle confermate';
$db->do("INSERT INTO bgy_2026_bruma.st_eventi_cmp "
    . "(id_centralina_cmp,Data_ora,Durata,Leq,Sel) VALUES (204,'2024-05-20 23:00:00',20,60,70)");
$t->get_ok($page)->status_is(200)->content_like(qr/5000/)->content_like(qr/-90/)
    ->element_exists('input[name=confirm_parameters][required]')
    ->element_exists('input[name=confirm_replacement][required]');
$token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
my %form = (csrf_token => $token, airport => 'LIME', database => 'bgy_2026_bruma',
    date_from => '2024-05-20', date_to => '2024-05-26', selected_station => '1:204',
    shift_1 => 2, mti_1 => -80, mta_1 => 110, mdi_1 => 4900);
$t->post_ok('/procedures/correla_eventi_cmp/run' => form => \%form)->status_is(422, 'conferme obbligatorie');
@form{qw(confirm_parameters confirm_replacement)} = (1, 1);
$t->post_ok('/procedures/correla_eventi_cmp/run' => form => \%form)->status_is(302);
my ($id) = $t->tx->res->headers->location =~ m{/executions/([0-9a-f-]+)};
my $execution = $app->repo->get_execution($id);
is_deeply $execution->{parameters}{stations}, ['1:204:2:-80:110:4900'], 'parametri stazione persistiti';
is $setup->preview('LIME', 'bgy_2026_bruma')->{stations}[0]{defaults}{shift}, 1,
    'richiesta non completata non cambia il default';
eval { $setup->prepare('LIME', 'bgy_2026_bruma', \@missing) };
ok(ScriptManager::Exception->caught($@, 'database_busy'), 'creazione rifiutata anche con esecuzione in coda');
is $app->execution_service->execute($id), 'completed', 'correlazione effettiva completata';
is $setup->preview('LIME', 'bgy_2026_bruma')->{stations}[0]{defaults}{shift}, 2,
    'la richiesta completata aggiorna il default della stazione';

my ($event) = grep { ($_->{metadata}{operation} // '') eq 'correlation_station_complete' }
    @{$app->repo->list_events($id)};
my $log_id = $event->{metadata}{log_id};
ok $log_id, 'riferimento ai risultati persistito nel log JSONB';
my ($parameter_event) = grep { ($_->{metadata}{operation} // '') eq 'correlation_station_start' }
    @{$app->repo->list_events($id)};
is_deeply [@{$parameter_event->{metadata}}{qw(station_code shift mti mta mdi)}], [204, 2, -80, 110, 4900],
    'parametri effettivi registrati nei metadati JSONB';
$db->do(q{INSERT INTO bgy_2026_bruma.st_lva
    (data_calc,id_stazione,data_lva,correlato,valore,id_log,attuale,validita)
    VALUES ('2024-05-20',204,'2024-05-20',0,50,12,1,'0'),
           ('2024-05-21',204,'2024-05-21',0,50,14,1,'0')});
$t->get_ok("/executions/$id/correlation-results")->status_is(200)
    ->content_like(qr/2024-05-20/)->content_like(qr/1\/1 \(100\.00%\)/)
    ->content_like(qr/0\/0 \(non calcolabile\)/)
    ->element_exists("input[name=activations][value=\"$log_id:204\"]")
    ->element_count_is('input[name=activations]', 1);
is $t->tx->res->dom->at('tr[data-day="2024-05-20"]')->find('td')->[3]->all_text,
    '0.00', 'differenza tra LVAnc e LVAc mostrata per il giorno';
is_deeply [map { $_->all_text } $t->tx->res->dom->at('tr[data-day="2024-05-20"]')->find('td')->each],
    ['2024-05-20', '30.63', '30.63', '0.00', '1/1 (100.00%)', '35.99', '35.99', '0', '1'],
    'LVA, LVAn, differenza e percentuale a due decimali, conteggi notturni interi nella stessa riga';
is_deeply [map { $_->all_text } $t->tx->res->dom->at('tr[data-day="2024-05-21"]')->find('td')->each],
    ['2024-05-21', '—', '—', '—', '0/0 (non calcolabile)', '—', '—', '0', '0'],
    'giorno senza eventi: conteggi notturni zero e valori mancanti';
my $old = $app->repo->create_execution(procedure_code => 'correla_eventi_cmp',
    requested_by => 'test', queue_target => $execution->{queue_target}, parameters => $execution->{parameters});
$app->pg->db->query("update executions set status='completed' where id=?", $old);
$app->repo->add_event($old, info => 'completata', metadata => $event->{metadata});
$t->get_ok("/executions/$old/correlation-results")->status_is(200)->content_like(qr/Non disponibile/);
my $old_daily = $app->repo->create_execution(procedure_code => 'correla_eventi_cmp',
    requested_by => 'test', queue_target => $execution->{queue_target}, parameters => $execution->{parameters});
$app->pg->db->query("update executions set status='completed' where id=?", $old_daily);
$app->repo->add_event($old_daily, info => 'completata', metadata => $event->{metadata});
$app->repo->add_event($old_daily, info => 'conteggi precedenti', metadata => {
    operation => 'correlation_daily_counts', station_code => 204, log_id => $log_id,
    days => [{giorno => '2024-05-20', eventi => 1, correlati => 1}],
});
$t->get_ok("/executions/$old_daily/correlation-results")->status_is(200);
my @old_cells = map { $_->all_text } $t->tx->res->dom->at('tr[data-day="2024-05-20"]')->find('td')->each;
is_deeply [@old_cells[7,8]],
    ['Non disponibile', 'Non disponibile'], 'vecchi conteggi senza snapshot notturno non ricostruiti dai dati correnti';
{
    local $ENV{MYSQL_HOST} = 'another-server';
    my $review = ScriptManager::Service::CorrelazioneReview->new(repo => $app->repo);
    my ($source, $references) = $review->source($id);
    eval { $review->results($source, $references) };
    ok(ScriptManager::Exception->caught($@, 'correlation_source'),
        'consultazione rifiutata se cambia il server MySQL');
}
$token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
$t->post_ok("/executions/$id/correlation-activate" => form =>
    {activations => "$log_id:204:lva", confirm_activation => 1})->status_is(403, 'CSRF obbligatorio');
$t->post_ok("/executions/$id/correlation-activate" => form =>
    {csrf_token => $token, activations => "$log_id:204:lva"})->status_is(422, 'conferma obbligatoria');
my $forged = $app->execution_service->submit(attualizza_correlazione_cmp => {
    database => 'bgy_2026_bruma', airport => 'LIME', source_execution_id => $id,
    activations => ['999:204:lva'], confirm_activation => true,
})->{id};
is $app->execution_service->execute($forged), 'failed', 'riferimento non emesso dalla correlazione rifiutato';
is $app->repo->get_execution($forged)->{error_code}, 'invalid_activation';
is $db->selectrow_array('SELECT attuale FROM bgy_2026_bruma.st_lva WHERE id_log = ?', undef, 12), 1,
    'nessuna modifica per risultati non autorizzati';
$t->post_ok("/executions/$id/correlation-activate" => form =>
    {csrf_token => $token, activations => "$log_id:204", confirm_activation => 1})->status_is(302);
my ($activation) = $t->tx->res->headers->location =~ m{/executions/([0-9a-f-]+)};
is $app->execution_service->execute($activation), 'completed', 'attualizzazione accodata ed eseguita';
is $db->selectrow_array('SELECT attuale FROM bgy_2026_bruma.st_lva WHERE id_log = ?', undef, 12), 0;
is $db->selectrow_array('SELECT attuale FROM bgy_2026_bruma.st_lva WHERE id_log = ?', undef, 14), 1,
    'risultati attuali conservati nei giorni senza nuovi valori';
is $db->selectrow_array('SELECT COUNT(*) FROM bgy_2026_bruma.st_lva WHERE id_log = ? AND attuale = 1',
    undef, $log_id), 2, 'correlato e totale attualizzati';
is $db->selectrow_array('SELECT COUNT(*) FROM bgy_2026_bruma.st_lvan WHERE id_log = ? AND attuale = 1',
    undef, $log_id), 2, 'la stessa accettazione attualizza LVAn';
my $legacy = $app->execution_service->submit(attualizza_correlazione_cmp => {
    database => 'bgy_2026_bruma', airport => 'LIME', source_execution_id => $id,
    activations => ["$log_id:204:lva"], confirm_activation => true,
})->{id};
is $app->execution_service->execute($legacy), 'completed', 'compatibilita con richieste precedenti gia in coda';
my $duplicate = $app->execution_service->submit(attualizza_correlazione_cmp => {
    database => 'bgy_2026_bruma', airport => 'LIME', source_execution_id => $id,
    activations => ["$log_id:204", "$log_id:204:lva"], confirm_activation => true,
})->{id};
is $app->execution_service->execute($duplicate), 'failed', 'rifiutata selezione sovrapposta della stessa stazione';
is $app->repo->get_execution($duplicate)->{error_code}, 'invalid_activation';
$db->do(q{INSERT INTO bgy_2026_bruma.st_lva
    (data_calc,id_stazione,data_lva,correlato,valore,id_log,attuale)
    VALUES ('2024-05-21',204,'2024-05-21',0,55,123,0)});
my $lva_only = $app->repo->create_execution(procedure_code => 'correla_eventi_cmp',
    requested_by => 'test', queue_target => $execution->{queue_target}, parameters => $execution->{parameters});
$app->pg->db->query("update executions set status='completed' where id=?", $lva_only);
$app->repo->add_event($lva_only, info => 'completata',
    metadata => {operation => 'correlation_station_complete', station_code => 204, log_id => 123});
my $single = $app->execution_service->submit(attualizza_correlazione_cmp => {
    database => 'bgy_2026_bruma', airport => 'LIME', source_execution_id => $lva_only,
    activations => ['123:204'], confirm_activation => true,
})->{id};
is $app->execution_service->execute($single), 'completed', 'accettazione consentita quando LVAn non e disponibile';
is $db->selectrow_array('SELECT attuale FROM bgy_2026_bruma.st_lva WHERE id_log=123'), 1;
is $db->selectrow_array('SELECT COUNT(*) FROM bgy_2026_bruma.st_lvan WHERE id_log=? AND attuale=1', undef, $log_id),
    2, 'LVAn precedente conservato se non ci sono nuovi risultati';

subtest 'cruscotto correlazioni per aeroporto, anno e giorni con LVA attuale' => sub {
    $db->do("INSERT INTO anagrafica.stazioni VALUES (3,1,206,'Seconda',0,0,0)");
    $db->do(q{INSERT INTO bgy_2026_bruma.st_lva
        (data_calc,id_stazione,data_lva,correlato,valore,id_log,attuale)
        VALUES ('2026-01-01',204,'2026-01-01',0,50,21,1),
               ('2026-01-01',204,'2026-01-01',1,40,21,1),
               ('2026-01-02',204,'2026-01-02',0,50,22,1),
               ('2026-01-03',204,'2026-01-03',1,40,23,1),
               ('2026-01-04',206,'2026-01-04',0,50,24,1),
               ('2026-02-28',206,'2026-02-28',0,50,27,1),
               ('2026-01-05',205,'2026-01-05',0,50,25,1),
               ('2026-01-06',204,'2026-01-06',0,50,26,0)});
    my $target = lc($ENV{MYSQL_HOST}) . ':' . ($ENV{MYSQL_PORT} // 3306) . ':bgy_2026_bruma';
    my $failed_id = $app->repo->create_execution(procedure_code => 'correla_eventi_cmp',
        requested_by => 'test', queue_target => $target,
        parameters => {airport => 'LIME', database => 'bgy_2026_bruma',
            date_from => '2026-01-02', date_to => '2026-01-03', stations => ['1:204:1:-90:100:5000']});
    $app->pg->db->query("update executions set status='failed' where id=?", $failed_id);
    my $newer = $app->repo->create_execution(procedure_code => 'correla_eventi_cmp',
        requested_by => 'test', queue_target => $target,
        parameters => {airport => 'LIME', database => 'bgy_2026_bruma',
            date_from => '2026-01-03', date_to => '2026-01-03', stations => ['1:204:1:-90:100:5000']});
    $app->pg->db->query("update executions set status='completed' where id=?", $newer);
    my $different_server = $app->repo->create_execution(procedure_code => 'correla_eventi_cmp',
        requested_by => 'test', queue_target => 'other-server:3306:bgy_2026_bruma',
        parameters => {airport => 'LIME', database => 'bgy_2026_bruma',
            date_from => '2026-01-01', date_to => '2026-01-01', stations => ['1:204:1:-90:100:5000']});
    $app->pg->db->query("update executions set status='failed' where id=?", $different_server);
    my $timed_out = $app->repo->create_execution(procedure_code => 'correla_eventi_cmp',
        requested_by => 'test', queue_target => $target,
        parameters => {airport => 'LIME', database => 'bgy_2026_bruma',
            date_from => '2026-02-28', date_to => '2026-02-28', stations => ['3:206:1:-90:100:5000']});
    $app->pg->db->query("update executions set status='timed_out' where id=?", $timed_out);

    $t->get_ok('/')->element_exists('nav a[href="/cruscotto-correlazioni"]');
    $t->get_ok('/cruscotto-correlazioni')->status_is(200)->element_exists('select[name=airport]');
    $t->get_ok('/cruscotto-correlazioni?airport=LIME')->status_is(200)
        ->element_exists('select[name=year] option[value=2026]');
    $t->get_ok('/cruscotto-correlazioni?airport=LIME&year=2026')->status_is(200)
        ->element_exists('tr[data-station="1"] td[data-day="2026-01-01"] .heat-success')
        ->element_exists('tr[data-station="1"] td[data-day="2026-01-01"] a[href^="/cruscotto-correlazioni/elimina"]')
        ->element_exists("tr[data-station=\"1\"] td[data-day=\"2026-01-02\"] a.heat-failure[href=\"/executions/$failed_id\"]")
        ->element_exists('tr[data-station="1"] td[data-day="2026-01-03"] .heat-empty')
        ->element_exists('tr[data-station="1"] td[data-day="2026-01-04"] .heat-empty')
        ->element_exists('tr[data-station="3"] td[data-day="2026-01-04"] .heat-timeout')
        ->element_exists("tr[data-station=\"3\"] td[data-day=\"2026-02-28\"] a.heat-failure[href=\"/executions/$timed_out\"]")
        ->element_exists_not('td[data-day="2026-01-05"]')
        ->element_exists_not('td[data-day="2026-01-06"]')
        ->element_exists_not('tr[data-station="2"]');
    $t->get_ok('/cruscotto-correlazioni?airport=LIME&year=2025')->status_is(503);
    $t->get_ok('/cruscotto-correlazioni?airport=LIME&year=2027')->status_is(422);
    $t->get_ok('/cruscotto-correlazioni?airport=LIME&year=2026%27')->status_is(422);
    $t->get_ok('/cruscotto-correlazioni?airport=INVALID&year=2026')->status_is(422);

    $db->do(q{INSERT INTO bgy_2026_bruma.st_eventi_cmp
        (id_centralina_cmp,Data_ora,Durata,Leq,Sel) VALUES
        (204,'2026-01-01 10:00:00',20,60,70),(204,'2026-01-02 10:00:00',20,60,70),
        (206,'2026-01-01 10:00:00',20,60,70)});
    $db->do(q{INSERT INTO bgy_2026_bruma.battute_eventi_cmp (flay_id,battuta_id,evento_cmp_id,distance,shift)
        SELECT 10,100,row_id,10,1 FROM bgy_2026_bruma.st_eventi_cmp WHERE Data_ora >= '2026-01-01'});
    $db->do(q{INSERT INTO bgy_2026_bruma.battute_eventi_cmp (flay_id,battuta_id,evento_cmp_id,distance,shift)
        SELECT 10,100,row_id,10,9 FROM bgy_2026_bruma.st_eventi_cmp
        WHERE id_centralina_cmp=204 AND DATE(Data_ora)='2026-01-01'});
    $db->do(q{INSERT INTO bgy_2026_bruma.st_lvan
        (data_calc,id_stazione,data_lvan,correlato,valore,id_log,attuale)
        VALUES ('2026-01-01',204,'2026-01-01',0,50,21,1),
               ('2026-01-01',204,'2026-01-01',1,40,21,1),
               ('2026-01-01',204,'2026-01-01',1,35,20,0)});
    my $preview = '/cruscotto-correlazioni/elimina?airport=LIME&database=bgy_2026_bruma'
        . '&day=2026-01-01&station_id=1&station_code=204';
    $t->get_ok($preview)->status_is(200)->content_like(qr/2 abbinamenti/);
    my $csrf = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
    my $snapshot = $t->tx->res->dom->at('input[name=snapshot]')->attr('value');
    my %delete = (airport => 'LIME', database => 'bgy_2026_bruma', day => '2026-01-01',
        station_id => 1, station_code => 204, snapshot => $snapshot, confirm_deletion => 1);
    $t->post_ok('/cruscotto-correlazioni/elimina' => form => \%delete)->status_is(403);
    $delete{csrf_token} = $csrf;
    delete $delete{confirm_deletion};
    $t->post_ok('/cruscotto-correlazioni/elimina' => form => \%delete)->status_is(422);
    $delete{confirm_deletion} = 1;
    $t->post_ok('/cruscotto-correlazioni/elimina' => form => \%delete)->status_is(302);
    my ($stale) = $t->tx->res->headers->location =~ m{/executions/([0-9a-f-]+)};
    $db->do("UPDATE bgy_2026_bruma.st_lvan SET valore=41 WHERE id_log=21 AND correlato=1");
    is $app->execution_service->execute($stale), 'failed', 'cancellazione rifiutata se i dati cambiano in coda';
    is $app->repo->get_execution($stale)->{error_code}, 'correlation_changed';
    is $db->selectrow_array('SELECT COUNT(*) FROM bgy_2026_bruma.battute_eventi_cmp'), 5,
        'nessuna cancellazione con anteprima scaduta';
    $t->get_ok($preview)->status_is(200);
    $delete{snapshot} = $t->tx->res->dom->at('input[name=snapshot]')->attr('value');
    $t->post_ok('/cruscotto-correlazioni/elimina' => form => \%delete)->status_is(302);
    my ($deletion) = $t->tx->res->headers->location =~ m{/executions/([0-9a-f-]+)};
    is $app->execution_service->execute($deletion), 'completed', 'cancellazione accodata completata';
    is $db->selectrow_array('SELECT COUNT(*) FROM bgy_2026_bruma.battute_eventi_cmp'), 3,
        'rimossi tutti gli shift della sola coppia selezionata';
    is $db->selectrow_array("SELECT COUNT(*) FROM bgy_2026_bruma.st_lva WHERE id_log=21 AND correlato=1 AND attuale=1"),
        0, 'flag attuale LVA correlato rimosso';
    is $db->selectrow_array("SELECT COUNT(*) FROM bgy_2026_bruma.st_lvan WHERE id_log=21 AND correlato=1 AND attuale=1"),
        0, 'flag attuale LVAn correlato rimosso';
    is $db->selectrow_array("SELECT COUNT(*) FROM bgy_2026_bruma.st_lvan WHERE id_log=21 AND correlato=0 AND attuale=1"),
        1, 'totale attuale preservato';
    is $db->selectrow_array("SELECT COUNT(*) FROM bgy_2026_bruma.st_lvan WHERE id_stazione=204 AND correlato=1 AND data_lvan='2026-01-01'"),
        2, 'storico correlato conservato';
    $t->get_ok($preview . '&station_code=206')->status_is(422);
    $t->get_ok('/cruscotto-correlazioni/elimina?airport=LIME&database=bgy_2026_bruma&day=2025-01-01&station_id=1&station_code=204')
        ->status_is(422);
};

$db->do(q{DELETE FROM bgy_2026_bruma.battute_eventi_cmp WHERE evento_cmp_id IN
    (SELECT row_id FROM bgy_2026_bruma.st_eventi_cmp WHERE DATE(Data_ora)='2024-05-20')});
$t->get_ok("/executions/$id/correlation-results")->status_is(200)->content_like(qr/1\/1 \(100\.00%\)/,
    'il report mantiene i conteggi della correlazione originaria dopo modifiche successive');
my @after_cells = map { $_->all_text } $t->tx->res->dom->at('tr[data-day="2024-05-20"]')->find('td')->each;
is_deeply [@after_cells[7,8]],
    ['0', '1'], 'conteggi notturni originali conservati dopo rimozione dell abbinamento';

$db->do(q{INSERT INTO bgy_2024_bruma.st_eventi_cmp
    (id_centralina_cmp,Data_ora,Durata,Leq,Sel) VALUES (204,'2024-01-01 10:00:00',20,60,70)});
$db->do(q{INSERT INTO bgy_2024_bruma.battute_eventi_cmp (flay_id,battuta_id,evento_cmp_id,distance,shift)
    SELECT 10,100,row_id,10,1 FROM bgy_2024_bruma.st_eventi_cmp});
$db->do(q{INSERT INTO bgy_2024_bruma.st_lva (data_calc,id_stazione,data_lva,correlato,valore,id_log,attuale)
    VALUES ('2024-01-01',204,'2024-01-01',0,50,21,1),('2024-01-01',204,'2024-01-01',1,40,21,1)});
my $without_lvan = '/cruscotto-correlazioni/elimina?airport=LIME&database=bgy_2024_bruma'
    . '&day=2024-01-01&station_id=1&station_code=204';
$t->get_ok($without_lvan)->status_is(200)->content_like(qr/tabella LVAn non e presente/);
my $delete_token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
my $delete_snapshot = $t->tx->res->dom->at('input[name=snapshot]')->attr('value');
$t->post_ok('/cruscotto-correlazioni/elimina' => form => {
    csrf_token => $delete_token, airport => 'LIME', database => 'bgy_2024_bruma', day => '2024-01-01',
    station_id => 1, station_code => 204, snapshot => $delete_snapshot, confirm_deletion => 1,
})->status_is(302);
my ($delete_no_lvan) = $t->tx->res->headers->location =~ m{/executions/([0-9a-f-]+)};
is $app->execution_service->execute($delete_no_lvan), 'completed', 'cancellazione possibile senza tabella LVAn';
is $db->selectrow_array('SELECT COUNT(*) FROM bgy_2024_bruma.battute_eventi_cmp'), 0;
is $db->selectrow_array('SELECT attuale FROM bgy_2024_bruma.st_lva WHERE correlato=1'), 0;

done_testing;
