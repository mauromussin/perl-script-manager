use Mojo::Base -strict, -signatures;
use Test::More;
use DBI;
use Mojo::JSON 'encode_json';
use ScriptManager::Command::CorrelaEventiCMP;

plan skip_all => 'Richiede server MariaDB isolato dedicato al test'
    unless ($ENV{TEST_CORRELA_ISOLATED_MYSQL} // '') eq '1';

{
    package CorrelaTestContext;
    use Mojo::Base -base, -signatures;
    has logs => sub { [] };
    has cancel => 0;
    has cancel_on_start => 0;
    sub log ($self, @args) {
        push @{$self->logs}, \@args;
        $self->cancel(1) if $self->cancel_on_start && grep { defined $_ && $_ eq 'correlation_station_start' } @args;
    }
    sub progress ($self, @args) { }
    sub check_cancel ($self) { die "annullato\n" if $self->cancel }
}

my $db = DBI->connect('DBI:MariaDB:host=' . $ENV{MYSQL_HOST} . ';port=' . ($ENV{MYSQL_PORT} // 3306),
    $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD}, {RaiseError => 1, PrintError => 0});
my $exists = $db->selectrow_array('SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME IN (?,?)',
    undef, 'anagrafica', 'mxp_2025_bruma');
die "Il test richiede un server isolato senza database di test preesistenti\n" if $exists;
my ($ana, $target);
END {
    if ($db) {
        $db->do('DROP DATABASE mxp_2025_bruma') if $target;
        $db->do('DROP DATABASE anagrafica') if $ana;
        $db->disconnect;
    }
}
$db->do('CREATE DATABASE anagrafica'); $ana = 1;
$db->do('CREATE DATABASE mxp_2025_bruma'); $target = 1;
$db->do('USE mxp_2025_bruma');
for my $sql (
    'CREATE TABLE anagrafica.aeroporti (row_id INT PRIMARY KEY, nome_aerop VARCHAR(4)) ENGINE=MyISAM',
    'CREATE TABLE anagrafica.stazioni (row_id INT PRIMARY KEY, aeroporti_id INT, c_cab INT, X_m DOUBLE, Y_m DOUBLE, H_m DOUBLE) ENGINE=MyISAM',
    'CREATE TABLE anagrafica.stazioni_sid (stazioni_id INT, sid VARCHAR(20)) ENGINE=MyISAM',
    'CREATE TABLE anagrafica.correla_log (IdLog INT AUTO_INCREMENT PRIMARY KEY, DataCorr DATETIME, DatabaseCorr VARCHAR(64), IdStazione INT, DataInizio DATE, DataFine DATE, CorrNumber INT, MaxTimeIn INT, MaxTimeAdv INT, MaxDistance DOUBLE) ENGINE=MyISAM',
    'CREATE TABLE st_eventi_cmp (row_id INT PRIMARY KEY, id_centralina_cmp INT, data_ora DATETIME(6), Sel DOUBLE) ENGINE=MyISAM',
    'CREATE TABLE flay (row_id INT PRIMARY KEY, sid VARCHAR(20), validation_bt INT) ENGINE=MyISAM',
    'CREATE TABLE battute (row_id INT PRIMARY KEY, flay_id INT, X_m DOUBLE, Y_m DOUBLE, A_m DOUBLE, validation CHAR(1), time_italy DATETIME) ENGINE=MyISAM',
    'CREATE TABLE battute_eventi_cmp (flay_id INT, battuta_id INT, evento_cmp_id INT, distance DOUBLE, shift INT) ENGINE=MyISAM',
    'CREATE TABLE st_lva (data_calc DATETIME, id_stazione INT, data_lva DATE, correlato TINYINT, valore DOUBLE, id_log INT, attuale TINYINT DEFAULT 0) ENGINE=MyISAM',
    'CREATE TABLE st_lvan (data_calc DATETIME, id_stazione INT, data_lvan DATE, correlato TINYINT, valore DOUBLE, id_log INT, attuale TINYINT DEFAULT 0) ENGINE=MyISAM',
) { $db->do($sql) }
$db->do("INSERT INTO anagrafica.aeroporti VALUES (1,'LIMC'),(2,'LIML')");
$db->do('INSERT INTO anagrafica.stazioni VALUES (1,1,227,0,0,0),(2,1,228,0,0,0),(3,2,229,0,0,0)');
$db->do("INSERT INTO anagrafica.stazioni_sid VALUES (227,'A'),(228,'A')");
$db->do("INSERT INTO flay VALUES (10,'A',3),(11,'A',2),(12,'B',3),(13,'A',3),(14,'A',3)");
$db->do("INSERT INTO battute VALUES "
    . "(100,10,3,4,12,'Y','2025-01-01 10:00:10'),"
    . "(101,11,0,0,0,'Y','2025-01-01 10:00:10'),"
    . "(102,12,0,0,0,'Y','2025-01-01 10:00:10'),"
    . "(103,13,0,0,0,'N','2025-01-01 10:00:10'),"
    . "(104,14,13,0,0,'Y','2025-01-01 10:00:10')");
$db->do("INSERT INTO st_eventi_cmp VALUES "
    . "(1,227,'2025-01-01 10:00:00',60),(2,227,'2025-01-01 10:00:01',90),"
    . "(3,227,'2025-01-02 23:00:00',70),(4,227,'2025-01-03 05:59:59',80),"
    . "(5,227,'2025-01-03 06:00:00',80),(6,228,'2025-01-01 10:00:00',60)");
$db->do('INSERT INTO battute_eventi_cmp VALUES (14,104,1,13,-50),(14,104,6,13,99)');

my $command = ScriptManager::Command::CorrelaEventiCMP->new;
my $params = {database => 'mxp_2025_bruma', airport => 'LIMC', date_from => '2025-01-01',
    date_to => '2025-01-03', stations => ['1:227:0:0:20:14', '2:228:0:0:20:14']};
my $ctx = CorrelaTestContext->new;
my $result = $command->run($ctx, $params);
ok $result->{success}, 'due stazioni elaborate';
is_deeply $db->selectall_arrayref('SELECT evento_cmp_id, flay_id, battuta_id, shift FROM battute_eventi_cmp ORDER BY evento_cmp_id'),
    [[1,10,100,0],[2,14,104,0],[6,10,100,0]], 'ordine cronologico, sostituzione di tutti gli shift e traccia riutilizzata per altra stazione';
is $db->selectrow_array('SELECT distance FROM battute_eventi_cmp WHERE evento_cmp_id=1'), 13, 'distanza tridimensionale';
is_deeply $db->selectall_arrayref('SELECT id_stazione, data_lva, correlato FROM st_lva ORDER BY id_stazione, data_lva, correlato'),
    [[227,'2025-01-01',0],[227,'2025-01-01',1],[227,'2025-01-02',0],[227,'2025-01-03',0],
     [228,'2025-01-01',0],[228,'2025-01-01',1]], 'LVA totale anche nei giorni senza correlazioni';
is_deeply $db->selectall_arrayref('SELECT id_stazione, data_lvan, correlato FROM st_lvan ORDER BY id_stazione, data_lvan'),
    [[227,'2025-01-02',0],[227,'2025-01-03',0]], 'LVAn totale senza correlazioni, ore 23-05';
my $night = $db->selectrow_array("SELECT valore FROM st_lvan WHERE data_lvan='2025-01-02'");
ok abs($night - (10 * log(10 ** 8 / 25200) / log(10))) < 0.000001, 'formula LVAn legacy';
my $lva = $db->selectrow_array("SELECT valore FROM st_lva WHERE id_stazione=227 AND data_lva='2025-01-03' AND correlato=0");
ok abs($lva - (10 * log((10 ** 9 + 10 ** 8) / 86400) / log(10))) < 0.000001, 'formula LVA giorno e notte';
my @complete = grep { $_->[0] eq 'info' && grep { defined $_ && $_ eq 'correlation_station_complete' } @$_ } @{$ctx->logs};
my @daily = grep { $_->[0] eq 'info' && grep { defined $_ && $_ eq 'correlation_daily_counts' } @$_ } @{$ctx->logs};
my %daily_metadata = @{$daily[0]}[2 .. $#{$daily[0]}];
is_deeply $daily_metadata{days}, [
    {giorno => '2025-01-01', eventi => 2, correlati => 2, eventi_notturni => 0, non_correlati_notturni => 0},
    {giorno => '2025-01-02', eventi => 1, correlati => 0, eventi_notturni => 1, non_correlati_notturni => 1},
    {giorno => '2025-01-03', eventi => 2, correlati => 0, eventi_notturni => 1, non_correlati_notturni => 1},
], 'conteggi giornalieri di eventi distinti salvati al momento della correlazione';
is scalar(@complete), 2, 'log strutturato per stazione';
for my $entry (@complete) {
    my %metadata = @$entry[2 .. $#$entry];
    is_deeply [sort keys %metadata], [qw(log_id operation station_code)], 'metadata evento di completamento esatti';
    like encode_json(\%metadata), qr/"station_code":\d+/, 'station_code serializzato come numero JSON';
    like encode_json(\%metadata), qr/"log_id":\d+/, 'log_id serializzato come numero JSON';
    like $metadata{station_code}, qr/\A\d+\z/, 'codice numerico';
    like $metadata{log_id}, qr/\A[1-9]\d*\z/, 'log_id numerico';
}
my $logs = $db->selectall_arrayref('SELECT IdLog, IdStazione, CorrNumber FROM anagrafica.correla_log ORDER BY IdLog');
is_deeply [map { $_->{log_id} } @{$result->{data}{stations}}], [map { $_->[0] } @$logs], 'last_insert_id distinto per stazione';
is_deeply [map { $_->[1] } @$logs], [227,228], 'log usa codici centralina';
is $db->selectrow_array('SELECT COUNT(*) FROM st_lva WHERE attuale<>0'), 0, 'nessuna attualizzazione';

$db->do("INSERT INTO flay VALUES (15,'A',3)");
$db->do("INSERT INTO battute VALUES (105,15,0,0,1,'Y','2025-01-02 23:00:00')");
$db->do("INSERT INTO st_eventi_cmp VALUES (9,227,'2025-01-02 00:00:00',70)");
my $mixed_ctx = CorrelaTestContext->new;
my $mixed = $command->run($mixed_ctx, {%$params, stations => ['1:227:0:0:20:14']});
my ($mixed_daily) = grep { grep { defined $_ && $_ eq 'correlation_daily_counts' } @$_ } @{$mixed_ctx->logs};
my %mixed_metadata = @$mixed_daily[2 .. $#$mixed_daily];
is_deeply [@{$mixed_metadata{days}[1]}{qw(eventi_notturni non_correlati_notturni)}], [2, 1],
    'evento notturno correlato incluso nel totale ma non nei non correlati';
my $mixed_id = $mixed->{data}{stations}[0]{log_id};
is_deeply $db->selectall_arrayref('SELECT data_lva,correlato FROM st_lva WHERE id_log=? ORDER BY data_lva,correlato',
    undef, $mixed_id), [['2025-01-01',0],['2025-01-01',1],['2025-01-02',0],['2025-01-02',1],['2025-01-03',0]],
    'risultati LVA associati alla data corretta anche con insiemi di giorni diversi';
is_deeply $db->selectall_arrayref('SELECT data_lvan,correlato FROM st_lvan WHERE id_log=? ORDER BY data_lvan,correlato',
    undef, $mixed_id), [['2025-01-02',0],['2025-01-02',1],['2025-01-03',0]],
    'risultati LVAn correlati e totali associati per data';
my $night_corr = $db->selectrow_array('SELECT valore FROM st_lvan WHERE id_log=? AND correlato=1', undef, $mixed_id);
ok abs($night_corr - (10 * log(10 ** 8 / 25200) / log(10))) < 0.000001, 'formula LVAn correlata';
$db->do('DELETE FROM battute WHERE row_id=105');
$db->do('DELETE FROM flay WHERE row_id=15');
$db->do('DELETE FROM st_eventi_cmp WHERE row_id=9');
$db->do('DELETE FROM battute_eventi_cmp');
$params->{stations} = ['1:227:1:-1:20:13'];
$result = $command->run(CorrelaTestContext->new, $params);
is_deeply $db->selectall_arrayref('SELECT evento_cmp_id,flay_id FROM battute_eventi_cmp'),
    [], 'soglia distanza esclusiva: distanza esattamente uguale non ammessa';
my $zero_id = $result->{data}{stations}[0]{log_id};
is $db->selectrow_array('SELECT COUNT(*) FROM st_lva WHERE id_log=? AND correlato=0', undef, $zero_id),
    3, 'zero correlazioni: tutti i giorni con eventi hanno LVA totale';
is $db->selectrow_array('SELECT COUNT(*) FROM st_lva WHERE id_log=? AND correlato=1', undef, $zero_id),
    0, 'zero correlazioni: nessun LVA correlato inventato';
is $db->selectrow_array('SELECT COUNT(*) FROM st_lvan WHERE id_log=? AND correlato=0', undef, $zero_id),
    2, 'zero correlazioni: LVAn totale presente per i giorni notturni';
$params->{stations} = ['1:227:1:-1:20:14'];
$result = $command->run(CorrelaTestContext->new, $params);
is_deeply $db->selectall_arrayref('SELECT evento_cmp_id,flay_id FROM battute_eventi_cmp ORDER BY evento_cmp_id'),
    [[1,14],[2,10]], 'shift non nullo: SEL decrescente prevale sulla data';

my $before = $db->selectrow_array('SELECT COUNT(*) FROM battute_eventi_cmp');
for my $bad (
    {%$params, cond => ' OR 1=1'},
    {%$params, database => 'lin_2025_bruma'},
    {%$params, date_from => '2025-02-30'},
    {%$params, stations => ['1:227:1:-1:20:14', '3:229:0:0:1:10']},
    {%$params, stations => ['1:228:0:0:1:10']},
    {%$params, stations => ['1:227:0:2:1:10']},
    {%$params, stations => ['1:227:32768:0:1:10']},
    {%$params, stations => ['1:227:0:0:1:1000000000']},
) {
    eval { $command->run(CorrelaTestContext->new, $bad) };
    ok $@, 'parametri invalidi rifiutati';
    is $db->selectrow_array('SELECT COUNT(*) FROM battute_eventi_cmp'), $before, 'nessuna cancellazione in preflight';
}
$db->do('INSERT INTO anagrafica.stazioni VALUES (4,1,227,0,0,0)');
eval { $command->run(CorrelaTestContext->new, $params) };
ok $@, 'codice ambiguo rifiutato';
is $db->selectrow_array('SELECT COUNT(*) FROM battute_eventi_cmp'), $before, 'nessuna cancellazione con codice ambiguo';
$db->do('DELETE FROM anagrafica.stazioni WHERE row_id=4');
$db->do("INSERT INTO st_eventi_cmp VALUES (8,227,'2025-01-01 10:00:00',NULL)");
eval { $command->run(CorrelaTestContext->new, $params) };
like "$@", qr/SEL/, 'SEL mancante rifiutato prima delle scritture';
is $db->selectrow_array('SELECT COUNT(*) FROM battute_eventi_cmp'), $before, 'nessuna cancellazione con SEL mancante';
$db->do('DELETE FROM st_eventi_cmp WHERE row_id=8');

$db->do(q{CREATE TRIGGER stop_delete BEFORE DELETE ON battute_eventi_cmp FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='delete denied'});
my $failed_ctx = CorrelaTestContext->new;
eval { $command->run($failed_ctx, $params) };
like "$@", qr/delete denied/, 'errore di cancellazione propagato';
is $db->selectrow_array('SELECT COUNT(*) FROM battute_eventi_cmp'), $before, 'cancellazione fallita non nascosta';
ok !grep({ grep { defined $_ && $_ eq 'correlation_station_complete' } @$_ } @{$failed_ctx->logs}),
    'nessun evento di completamento dopo errore';
$db->do('DROP TRIGGER stop_delete');

$db->do(q{CREATE TRIGGER stop_lvan BEFORE INSERT ON st_lvan FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='lvan denied'});
my $lvan_ctx = CorrelaTestContext->new;
eval { $command->run($lvan_ctx, $params) };
like "$@", qr/lvan denied/, 'errore salvataggio LVAn propagato';
ok !grep({ grep { defined $_ && $_ eq 'correlation_station_complete' } @$_ } @{$lvan_ctx->logs}),
    'evento di completamento non emesso se LVAn fallisce';
$db->do('DROP TRIGGER stop_lvan');

$db->do("INSERT INTO st_eventi_cmp VALUES (7,228,'2025-01-03 23:59:59.500000',70)");
$db->do('INSERT INTO battute_eventi_cmp VALUES (14,104,7,13,9)');
my $fractional = $command->run(CorrelaTestContext->new, {%$params, stations => ['2:228:0:0:1:14']});
is $db->selectrow_array('SELECT COUNT(*) FROM battute_eventi_cmp WHERE evento_cmp_id=7'), 0,
    'sostituzione comprende ultimo secondo frazionario';
is $db->selectrow_array('SELECT COUNT(*) FROM st_lvan WHERE id_log=? AND correlato=0 AND data_lvan=?',
    undef, $fractional->{data}{stations}[0]{log_id}, '2025-01-03'), 1, 'ultimo secondo frazionario nel totale';

my $cancel_ctx = CorrelaTestContext->new(cancel_on_start => 1);
eval { $command->run($cancel_ctx, $params) };
like "$@", qr/annullato/, 'annullamento dopo cancellazione propagato';
ok grep({ $_->[0] eq 'warning' && $_->[1] =~ /parziali/ } @{$cancel_ctx->logs}), 'avviso esplicito effetti parziali';
ok !grep({ grep { defined $_ && $_ eq 'correlation_station_complete' } @$_ } @{$cancel_ctx->logs}),
    'annullamento non pubblica completamento';
$db->do("INSERT INTO st_eventi_cmp VALUES "
    . "(20,228,'2025-01-02 00:00:00',70),(21,228,'2025-01-02 05:59:59',70),"
    . "(22,228,'2025-01-02 06:00:00',70),(23,228,'2025-01-02 22:59:59',70),"
    . "(24,228,'2025-01-02 23:00:00',70)");
my $boundary_ctx = CorrelaTestContext->new;
$command->run($boundary_ctx, {%$params, date_from => '2025-01-02', date_to => '2025-01-02',
    stations => ['2:228:0:0:1:14']});
my ($boundary_daily) = grep { grep { defined $_ && $_ eq 'correlation_daily_counts' } @$_ } @{$boundary_ctx->logs};
my %boundary_metadata = @$boundary_daily[2 .. $#$boundary_daily];
is_deeply [@{$boundary_metadata{days}[0]}{qw(eventi eventi_notturni non_correlati_notturni)}], [5, 3, 3],
    'intervallo notturno comprende 00:00, 05:59 e 23:00 ma esclude 06:00 e 22:59';
$before = $db->selectrow_array('SELECT COUNT(*) FROM battute_eventi_cmp');
$db->do('DROP TABLE st_lvan');
eval { $command->run(CorrelaTestContext->new, $params) };
ok $@, 'tabella mancante rilevata';
is $db->selectrow_array('SELECT COUNT(*) FROM battute_eventi_cmp'), $before, 'nessuna cancellazione con tabella mancante';

done_testing;
