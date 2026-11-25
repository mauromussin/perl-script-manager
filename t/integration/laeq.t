use Mojo::Base -strict, -signatures;
use Test::More;
use DBI;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper;
use Mojo::JSON qw(decode_json true);
use ScriptManager::Command::CalcolaLAeq;
use ScriptManager::Service::LAeqSetup;

plan skip_all => 'Richiede PostgreSQL e MariaDB isolato dedicato al test'
    unless TestHelper::online() && ($ENV{TEST_LAEQ_ISOLATED_MYSQL} // '') eq '1';

my $db = DBI->connect('DBI:MariaDB:host=' . $ENV{MYSQL_HOST} . ';port=' . ($ENV{MYSQL_PORT} // 3306),
    $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD}, {RaiseError => 1, PrintError => 0});
my @schemas = qw(anagrafica mxp_2024_bruma mxp_2025_bruma mxp_2026_bruma);
my @created;
END {
    if ($db) {
        $db->do('DROP DATABASE ' . $db->quote_identifier($_)) for reverse @created;
        $db->disconnect;
    }
}
for my $name (@schemas) {
    die "Il test richiede un server isolato senza $name\n"
        if $db->selectrow_array('SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=?', undef, $name);
}
for my $name (@schemas[0..2]) {
    $db->do('CREATE DATABASE ' . $db->quote_identifier($name));
    push @created, $name;
}
$db->do('CREATE TABLE anagrafica.aeroporti (row_id INT PRIMARY KEY, nome_aerop VARCHAR(4))');
$db->do('CREATE TABLE anagrafica.stazioni (row_id INT PRIMARY KEY, aeroporti_id INT, c_cab INT, name VARCHAR(25))');
$db->do("INSERT INTO anagrafica.aeroporti VALUES (1,'LIMC'),(2,'LIML')");
$db->do("INSERT INTO anagrafica.stazioni VALUES (1,1,227,'Prima'),(2,1,228,'Seconda'),(3,2,229,'Altra')");
$db->do("CREATE TABLE mxp_2024_bruma.st_laeq (row_id BIGINT AUTO_INCREMENT PRIMARY KEY, "
    . "id_stazione INT, data_LAeq DATE, TR ENUM('D','N'), valore_LAeq DOUBLE) ENGINE=MyISAM");
sub create_sources ($db, $schema) {
    $db->do("CREATE TABLE $schema.st_eventi_cmp (row_id INT PRIMARY KEY, id_centralina_cmp INT, "
        . 'data_ora DATETIME(6), Sel DOUBLE) ENGINE=MyISAM');
    $db->do("CREATE TABLE $schema.battute_eventi_cmp (evento_cmp_id INT) ENGINE=MyISAM");
}
create_sources($db, 'mxp_2025_bruma');
my $t = TestHelper::mojo();
my $app = $t->app;
my $page = '/procedures/calcola_laeq?airport=LIMC&database=mxp_2025_bruma';
$t->get_ok($page)->status_is(200)->content_like(qr/tabella st_laeq manca/)
    ->element_exists('input[name=confirm_schema][required]');
my $token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
my %prepare = (airport => 'LIMC', database => 'mxp_2025_bruma');
$t->post_ok('/procedures/calcola_laeq/prepare' => form => {%prepare, confirm_schema => 1})
    ->status_is(403, 'creazione richiede CSRF');
$t->post_ok('/procedures/calcola_laeq/prepare' => form => {%prepare, csrf_token => $token})
    ->status_is(422, 'creazione richiede conferma');
{
    my $lock_db = $app->pg->db;
    my $tx = $lock_db->begin;
    $lock_db->query('select pg_advisory_xact_lock(hashtextextended(?, 0))',
        'database-queue:' . lc($ENV{MYSQL_HOST}) . ':' . ($ENV{MYSQL_PORT} // 3306) . ':mxp_2025_bruma');
    $t->post_ok('/procedures/calcola_laeq/prepare' => form => {
        %prepare, csrf_token => $token, confirm_schema => 1,
    })->status_is(422)->content_like(qr/Database occupato/);
    $tx->commit;
}
$t->post_ok('/procedures/calcola_laeq/prepare' => form => {
    %prepare, csrf_token => $token, confirm_schema => 1,
})->status_is(302);
$t->get_ok($page)->status_is(200)->element_exists('input[name=stations][value="1:227"]')
    ->element_exists('input[name=stations][value="2:228"]')
    ->element_exists_not('input[name=stations][value="3:229"]');
$token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
$t->post_ok('/procedures/calcola_laeq/run' => form => {
    csrf_token => $token, %prepare, date_from => '2025-12-30', date_to => '2025-12-31',
})->status_is(422, 'richiesta senza stazioni rifiutata');
my %params = (%prepare, date_from => '2025-12-30', date_to => '2025-12-31',
    stations => ['1:227', '2:228']);
sub execute ($app, $params) {
    my $request = $app->execution_service->submit('calcola_laeq', $params, requested_by => 'test');
    $request = $app->execution_service->submit('calcola_laeq', $params, requested_by => 'test',
        confirm_completed_execution => $request->{duplicate}{id}) if $request->{duplicate};
    die 'Parametri non validi: ' . join(', ', map { $_->{message} } @{$request->{errors}})
        if $request->{errors};
    my $status = $app->execution_service->execute($request->{id});
    return ($status, $app->repo->get_execution($request->{id}));
}
my ($status, $execution) = execute($app, \%params);
is $status, 'failed', 'manca il database successivo: esecuzione bloccata';
is $execution->{error_code}, 'mysql_connect', 'errore esplicito di connessione';
like $execution->{error_message}, qr/mxp_2026_bruma/, 'il messaggio identifica il database mancante';
is $db->selectrow_array('SELECT COUNT(*) FROM mxp_2025_bruma.st_laeq'), 0, 'nessuna scrittura';

$db->do('CREATE DATABASE mxp_2026_bruma');
push @created, 'mxp_2026_bruma';
create_sources($db, 'mxp_2026_bruma');
$db->do("INSERT INTO mxp_2025_bruma.st_eventi_cmp VALUES "
    . "(1,227,'2025-12-30 05:59:59',60),(2,227,'2025-12-30 06:00:00',60),"
    . "(3,227,'2025-12-30 21:59:59',70),(4,227,'2025-12-30 22:00:00',80),"
    . "(5,227,'2025-12-31 00:00:00',90),(6,227,'2025-12-31 05:59:59',100),"
    . "(7,227,'2025-12-31 06:00:00',110),(8,227,'2025-12-31 22:00:00',80),"
    . "(9,228,'2025-12-31 22:00:00',60),(10,227,'2025-12-30 12:00:00',120),"
    . "(11,227,'2026-01-01 01:00:00',120)");
$db->do('INSERT INTO mxp_2025_bruma.battute_eventi_cmp VALUES (1),(2),(2),(3),(4),(5),(6),(7),(8),(9),(11)');
$db->do("INSERT INTO mxp_2026_bruma.st_eventi_cmp VALUES "
    . "(1,227,'2026-01-01 00:00:00',90),(2,227,'2026-01-01 05:59:59',100),"
    . "(3,227,'2026-01-01 06:00:00',120)");
$db->do('INSERT INTO mxp_2026_bruma.battute_eventi_cmp VALUES (1),(2),(2),(3)');
$db->do('RENAME TABLE mxp_2026_bruma.battute_eventi_cmp TO mxp_2026_bruma.battute_eventi_cmp_test_hidden');
($status, $execution) = execute($app, \%params);
is $status, 'failed', 'tabella del database successivo mancante blocca il calcolo';
like $execution->{error_message}, qr/mxp_2026_bruma\.battute_eventi_cmp/, 'tabella mancante identificata';
is $db->selectrow_array('SELECT COUNT(*) FROM mxp_2025_bruma.st_laeq'), 0, 'nessuna scrittura';
$db->do('RENAME TABLE mxp_2026_bruma.battute_eventi_cmp_test_hidden TO mxp_2026_bruma.battute_eventi_cmp');
{
    my $lock_db = $app->pg->db;
    my $tx = $lock_db->begin;
    $lock_db->query('select pg_advisory_xact_lock(hashtextextended(?, 0))',
        'database-queue:' . lc($ENV{MYSQL_HOST}) . ':' . ($ENV{MYSQL_PORT} // 3306) . ':mxp_2026_bruma');
    ($status, $execution) = execute($app, \%params);
    is $status, 'failed', 'database successivo occupato blocca il calcolo';
    is $execution->{error_code}, 'database_busy', 'errore database occupato esplicito';
    is $db->selectrow_array('SELECT COUNT(*) FROM mxp_2025_bruma.st_laeq'), 0, 'nessuna scrittura';
    $tx->commit;
}
$t->post_ok('/procedures/calcola_laeq/run' => form => {
    csrf_token => $token, %params,
})->status_is(302);
my ($id) = $t->tx->res->headers->location =~ m{/executions/([0-9a-f-]+)};
is $app->execution_service->execute($id), 'completed', 'calcolo tramite modulo web completato';
my $rows = $db->selectall_arrayref(
    'SELECT id_stazione,data_LAeq,TR,valore_LAeq FROM mxp_2025_bruma.st_laeq ORDER BY id_stazione,data_LAeq,TR');
is_deeply [map { [@$_[0..2]] } @$rows],
    [[227,'2025-12-30','D'],[227,'2025-12-30','N'],[227,'2025-12-31','D'],
     [227,'2025-12-31','N'],[228,'2025-12-31','N']],
    'giorni e periodi indipendenti, senza valori inventati';
my @expected = (
    10 * log((10**6 + 10**7) / 57600) / log(10),
    10 * log((10**8 + 10**9 + 10**10) / 28800) / log(10),
    10 * log(10**11 / 57600) / log(10),
    10 * log((10**8 + 10**9 + 10**10) / 28800) / log(10),
    10 * log(10**6 / 28800) / log(10),
);
for my $i (0..$#expected) {
    ok abs($rows->[$i][3] - $expected[$i]) < 0.000001, "formula e confini risultato $i";
}
my $artifacts = $app->repo->list_artifacts($id);
is scalar(@$artifacts), 1, 'report registrato';
my $report = decode_json($app->output_root->child(split '/', $artifacts->[0]{relative_path})->slurp);
is_deeply [map { $_->{events} } @{$report->{results}}], [2,3,1,3,1], 'eventi distinti nel report';
is $report->{next_database}, 'mxp_2026_bruma', 'report indica database successivo';
$t->get_ok("/executions/$id/artifacts/$artifacts->[0]{id}")->status_is(200);

$db->do("UPDATE mxp_2025_bruma.st_laeq SET valore_LAeq=7 WHERE id_stazione=227 AND data_LAeq='2025-12-30' AND TR='D'");
$db->do("INSERT INTO mxp_2025_bruma.st_laeq (id_stazione,data_LAeq,TR,valore_LAeq) "
    . "VALUES (227,'2025-12-30','D',8),(228,'2025-12-30','D',9)");
($status) = execute($app, \%params);
is $status, 'completed', 'riesecuzione senza sovrascrittura';
is_deeply $db->selectcol_arrayref("SELECT valore_LAeq FROM mxp_2025_bruma.st_laeq "
    . "WHERE id_stazione=227 AND data_LAeq='2025-12-30' AND TR='D' ORDER BY row_id"),
    [7,8], 'duplicati preesistenti non modificati per default';
($status) = execute($app, {%params, overwrite => true});
is $status, 'completed', 'sovrascrittura confermata completata';
my $replaced = $db->selectcol_arrayref("SELECT valore_LAeq FROM mxp_2025_bruma.st_laeq "
    . "WHERE id_stazione=227 AND data_LAeq='2025-12-30' AND TR='D'");
is scalar(@$replaced), 1, 'duplicati eliminati solo con sovrascrittura';
ok abs($replaced->[0] - $expected[0]) < 0.000001, 'valore aggiornato';
is $db->selectrow_array("SELECT valore_LAeq FROM mxp_2025_bruma.st_laeq "
    . "WHERE id_stazione=228 AND data_LAeq='2025-12-30' AND TR='D'"), 9,
    'risultato precedente conservato se mancano eventi';

for my $bad (
    {%params, stations => ['1:227', '3:229'], overwrite => true},
    {%params, stations => ['1:228'], overwrite => true},
    {%params, stations => ['1:227', '1:0227'], overwrite => true},
    {%params, date_from => '2024-12-31', overwrite => true},
) {
    ($status) = execute($app, $bad);
    is $status, 'failed', 'parametri incompatibili rifiutati prima delle scritture';
    is $db->selectrow_array('SELECT COUNT(*) FROM mxp_2025_bruma.st_laeq'), 6, 'dati invariati';
}
$db->do("INSERT INTO mxp_2026_bruma.st_eventi_cmp VALUES (4,227,'2026-01-01 03:00:00',NULL)");
$db->do('INSERT INTO mxp_2026_bruma.battute_eventi_cmp VALUES (4)');
($status, $execution) = execute($app, {%params, overwrite => true});
is $status, 'failed', 'SEL mancante nel database successivo blocca prima delle scritture';
is $execution->{error_code}, 'invalid_events', 'errore SEL esplicito';
is $db->selectrow_array('SELECT COUNT(*) FROM mxp_2025_bruma.st_laeq'), 6, 'dati invariati';
$db->do('DELETE FROM mxp_2026_bruma.battute_eventi_cmp WHERE evento_cmp_id=4');

$db->do("INSERT INTO mxp_2025_bruma.st_eventi_cmp VALUES "
    . "(12,227,'2025-03-29 22:00:00',60),(13,227,'2025-03-30 05:59:59',60)");
$db->do('INSERT INTO mxp_2025_bruma.battute_eventi_cmp VALUES (12),(13)');
($status) = execute($app, {%params, date_from => '2025-03-29', date_to => '2025-03-29', stations => ['1:227']});
is $status, 'completed', 'notte del cambio ora senza database successivo';
my $dst = $db->selectrow_array("SELECT valore_LAeq FROM mxp_2025_bruma.st_laeq "
    . "WHERE id_stazione=227 AND data_LAeq='2025-03-29' AND TR='N'");
ok abs($dst - 10 * log(2 * 10**6 / 28800) / log(10)) < 0.000001,
    'denominatore notturno fisso anche al cambio ora';

$db->do("UPDATE mxp_2025_bruma.st_laeq SET valore_LAeq=0 "
    . "WHERE id_stazione=227 AND data_LAeq='2025-12-30'");
$db->do(q{CREATE TRIGGER mxp_2025_bruma.laeq_test_failure BEFORE UPDATE ON mxp_2025_bruma.st_laeq
    FOR EACH ROW BEGIN IF OLD.data_LAeq='2025-12-30' AND OLD.TR='N' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='update denied'; END IF; END});
($status, $execution) = execute($app, {%params, overwrite => true});
is $status, 'failed', 'errore MyISAM durante il salvataggio propagato';
my $partial = $db->selectall_arrayref("SELECT TR,valore_LAeq FROM mxp_2025_bruma.st_laeq "
    . "WHERE id_stazione=227 AND data_LAeq='2025-12-30' ORDER BY TR");
ok abs($partial->[0][1] - $expected[0]) < 0.000001 && $partial->[1][1] == 0,
    'scrittura precedente conservata, senza rollback';
ok scalar(grep { ($_->{metadata}{operation} // '') eq 'laeq_partial_effects' }
    @{$app->repo->list_events($execution->{id})}), 'avviso di effetti parziali registrato';
is scalar(@{$app->repo->list_artifacts($execution->{id})}), 0, 'nessun report di successo dopo errore';
$db->do('DROP TRIGGER mxp_2025_bruma.laeq_test_failure');

{
    package LAeqCancelContext;
    use Mojo::Base -base, -signatures;
    has 'repo';
    has cancelled => 0;
    has logs => sub { [] };
    sub progress ($self, @args) { }
    sub log ($self, @args) {
        push @{$self->logs}, \@args;
        my %meta = @args[2..$#args];
        $self->cancelled(1) if ($meta{operation} // '') eq 'laeq_saved';
    }
    sub check_cancel ($self) {
        ScriptManager::Exception->throw('cancelled', 'Esecuzione annullata') if $self->cancelled;
    }
    sub write_artifact ($self, @args) { die "Report inatteso dopo annullamento\n" }
}
$db->do("UPDATE mxp_2025_bruma.st_laeq SET valore_LAeq=0 "
    . "WHERE id_stazione=227 AND data_LAeq='2025-12-30'");
my $cancel_ctx = LAeqCancelContext->new(repo => $app->repo);
eval { ScriptManager::Command::CalcolaLAeq->new->run($cancel_ctx, {%params, overwrite => true}) };
ok(ScriptManager::Exception->caught($@, 'cancelled'), 'annullamento interrompe il salvataggio');
$partial = $db->selectall_arrayref("SELECT TR,valore_LAeq FROM mxp_2025_bruma.st_laeq "
    . "WHERE id_stazione=227 AND data_LAeq='2025-12-30' ORDER BY TR");
ok abs($partial->[0][1] - $expected[0]) < 0.000001 && $partial->[1][1] == 0,
    'annullamento lascia le sole scritture gia eseguite';

done_testing;
