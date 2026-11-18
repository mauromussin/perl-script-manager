use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper;
use DBI;
use Log::Any ();
use Log::Any::Adapter;
use ScriptManager::Service::Context;
use ScriptManager::Command::ValidaTracce;
use ScriptManager::Command::ValidaBattute;
use ScriptManager::Command::TrovaPistaAtterraggi;
use ScriptManager::Command::TrovaPistaDecolli;
use ScriptManager::Command::AssegnaSID;

plan skip_all => 'Richiede TEST_ONLINE e TEST_MYSQL=1'
    unless TestHelper::online() && ($ENV{TEST_MYSQL} // '') eq '1';

{
    package ScopedValidationDatabase;
    use Mojo::Base -base, -signatures;
    has 'db';
    has fail_write => 0;
    sub selectrow_arrayref ($self, $sql, @bind) {
        return [0, 0, 200] if $sql =~ /FROM anagrafica/;
        return $self->db->selectrow_arrayref($sql, @bind);
    }
    sub selectall_arrayref ($self, $sql, @bind) {
        return [['11', 0, 0, 200], ['29', 10000, 0, 200]] if $sql =~ /FROM anagrafica/;
        return $self->db->selectall_arrayref($sql, @bind);
    }
    sub selectrow_array ($self, @args) { return $self->db->selectrow_array(@args) }
    sub selectcol_arrayref ($self, @args) { return $self->db->selectcol_arrayref(@args) }
    sub do ($self, @args) {
        my $result = $self->db->do(@args);
        die "write failed after update\n" if $self->fail_write;
        return $result;
    }
    sub disconnect ($self) { return $self->db->disconnect }
}

my $app = TestHelper::mojo()->app;
Log::Any::Adapter->set('Null');
my $repo = $app->repo;
my $schema = sprintf 'sm_test_validation_%d_%d', $$, int rand 1_000_000;
die "Nome database test non valido\n" unless $schema =~ /\Asm_test_validation_\d+_\d+\z/;
my $dsn = 'DBI:MariaDB:host=' . ($ENV{MYSQL_HOST} // '') . ';port=' . ($ENV{MYSQL_PORT} // 3306);
my $admin = DBI->connect($dsn, $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD}, {RaiseError => 1, PrintError => 0});
my $created = 0;
END {
    if ($created && $admin) {
        $admin->do('DROP DATABASE ' . $admin->quote_identifier($schema));
        $admin->disconnect;
    }
}
$admin->do('CREATE DATABASE ' . $admin->quote_identifier($schema));
$created = 1;
$admin->do('USE ' . $admin->quote_identifier($schema));
$admin->do(q{
    CREATE TABLE flay (
      row_id INT PRIMARY KEY, flay_operation CHAR(1), data DATE, data_ora_italy DATETIME,
      validation_fl ENUM('Y','N','L','D','P','M'), validation_bt TINYINT,
      data_ora_arr DATETIME, pista CHAR(3), sid CHAR(5)
    ) ENGINE=MyISAM
});
$admin->do(q{
    CREATE TABLE battute (
      row_id INT PRIMARY KEY AUTO_INCREMENT, flay_id INT, time_italy DATETIME,
      X_m DOUBLE, Y_m DOUBLE, H_m DOUBLE, validation CHAR(1)
    ) ENGINE=MyISAM
});
for my $id (1 .. 8) {
    my $day = int(($id - 1) / 2) + 1;
    my $date = $id == 7 ? undef : $id == 8 ? '2026-11-02 12:00:00'
        : $id == 3 ? '2026-11-02 00:00:00' : $id == 4 ? '2026-11-02 23:59:59'
        : $id == 5 ? '2026-11-03 00:00:00'
        : sprintf('2026-11-%02d 12:00:00', $day);
    $admin->do('INSERT INTO flay (row_id, flay_operation, data, data_ora_italy, validation_fl) VALUES (?, ?, ?, ?, ?)',
        undef, $id, $id % 2 ? 'A' : 'D', '2026-11-01', $date, $id == 8 ? 'M' : undef);
    for my $i (0 .. 7) {
        $admin->do('INSERT INTO battute (flay_id, time_italy, X_m, Y_m, H_m) VALUES (?, ?, ?, ?, ?)',
            undef, $id, sprintf('2026-11-02 12:00:%02d', $i), 100 * $i, 0, 300);
    }
}

my %classes = (3 => 'ScriptManager::Command::ValidaTracce', 4 => 'ScriptManager::Command::ValidaBattute',
    5 => 'ScriptManager::Command::TrovaPistaAtterraggi', 6 => 'ScriptManager::Command::TrovaPistaDecolli',
    7 => 'ScriptManager::Command::AssegnaSID');
my $target = join ':', lc($ENV{MYSQL_HOST}), $ENV{MYSQL_PORT} // 3306, $schema;
my $last_id;
sub run_stage ($stage, %extra) {
    my $fail = delete $extra{fail_write};
    my $id = $repo->create_execution(procedure_code => 'test_sum', requested_by => 'validation-test');
    $last_id = $id;
    $repo->mark_running($id);
    my $ctx = ScriptManager::Service::Context->new(
        execution_id => $id, repo => $repo, logger => Log::Any->get_logger);
    my $command = $classes{$stage}->new(connect_db => sub {
        my $db = DBI->connect("$dsn;database=$schema", $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD},
            {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        return ScopedValidationDatabase->new(db => $db, fail_write => $fail // 0);
    });
    my $result = eval { $command->run($ctx,
        {database => $schema, ($stage == 4 ? () : (airport => 'LIME')),
            date_from => '2026-11-02', date_to => '2026-11-02', %extra}) };
    my $error = $@;
    $repo->mark_finished($id, status => $error ? 'failed' : 'completed', exit_code => $error ? 1 : 0);
    $ctx->validation_guard(undef);
    die $error if $error;
    return $result;
}
sub track_state ($id) {
    return $admin->selectrow_arrayref(
        'SELECT validation_fl, validation_bt, pista, sid, data_ora_arr FROM flay WHERE row_id = ?', undef, $id);
}
sub days ($code) { return $repo->completed_validation_days($target, $code) }

subtest 'intervallo locale inclusivo e nessun effetto su altri giorni, M o date mancanti' => sub {
    my $r = run_stage(3);
    is_deeply $r->{data}{days_processed}, ['2026-11-02'];
    is_deeply [@{track_state(3)}[0, 1]], ['Y', undef], 'data locale Nov 2, anche se data UTC Nov 1';
    is_deeply [@{track_state(4)}[0, 1]], ['Y', undef];
    is_deeply track_state(1), [undef, undef, undef, undef, undef], 'giorno precedente intatto';
    is_deeply track_state(5), [undef, undef, undef, undef, undef], 'giorno seguente intatto';
    is_deeply track_state(7), [undef, undef, undef, undef, undef], 'data assente esclusa';
    is track_state(8)->[0], 'M', 'traccia unita esclusa';
    ok grep({ $_->{message} =~ /senza data_ora_italy escluse/ } @{$repo->list_events($last_id)}), 'avviso persistente';
    is_deeply days('valida_tracce'), ['2026-11-02'];
};

subtest '04 limita anche completamento date e riepilogo' => sub {
    $admin->do(q{UPDATE flay SET validation_fl = 'Y', validation_bt = 1 WHERE row_id = 1});
    $admin->do(q{UPDATE battute SET validation = 'Y' WHERE flay_id = 1});
    my $r = run_stage(4);
    is_deeply [@{track_state(3)}[0, 1]], ['Y', 1];
    is_deeply [@{track_state(4)}[0, 1]], ['Y', 1];
    is track_state(3)->[4], '2026-11-02 12:00:07', 'ultima battuta arrivo';
    is track_state(4)->[4], '2026-11-02 12:00:00', 'prima battuta decollo';
    is track_state(1)->[4], undef, 'non completa date fuori intervallo';
    is_deeply $r->{data}{report}, [['Y', 16]], 'report limitato ai giorni elaborati';
};

subtest '05 e 06 indipendenti e skip per precedente completamento' => sub {
    run_stage(5);
    run_stage(6);
    is_deeply [@{track_state(3)}[2, 3]], ['11', '11'], 'atterraggi pista e SID';
    is_deeply [@{track_state(4)}[2, 3]], ['11', undef], 'decolli solo pista';
    my $r = run_stage(3);
    is_deeply $r->{data}{days_processed}, [];
    is_deeply $r->{data}{days_skipped}, ['2026-11-02'];
    is track_state(3)->[2], '11', 'skip non invalida passaggi successivi';
};

subtest 'sovrascrittura 05/06 ripristina upstream e non tocca altri giorni' => sub {
    $admin->do(q{UPDATE flay SET validation_fl='P', validation_bt=0, pista='NA', sid='OLD' WHERE row_id IN (3,4)});
    $admin->do(q{UPDATE battute SET validation='X' WHERE flay_id=3 ORDER BY row_id DESC LIMIT 1});
    $admin->do(q{UPDATE battute SET validation='N' WHERE flay_id=3 ORDER BY row_id LIMIT 1});
    run_stage(5, overwrite => 1);
    is_deeply [@{track_state(3)}[0 .. 3]], ['L', 1, '11', '11'], 'ripristina 04 corto e ricalcola arrivo con X';
    is $admin->selectrow_array(q{SELECT COUNT(*) FROM battute WHERE flay_id=3 AND validation='X'}), 0;
    is_deeply days('trova_pista_decolli'), ['2026-11-02'], '05 non invalida lo storico di 06';
    run_stage(6, overwrite => 1);
    is_deeply [@{track_state(4)}[0 .. 3]], ['Y', 1, '11', undef], 'ricalcola decollo e azzera SID dipendente';
    is_deeply days('valida_battute'), ['2026-11-02'], 'conserva storico 04';
    $admin->do(q{UPDATE flay SET validation_fl='P', validation_bt=0, pista='NA' WHERE row_id=3});
    $admin->do(q{UPDATE battute SET validation='N' WHERE flay_id=3 AND row_id NOT IN (SELECT id FROM (SELECT row_id AS id FROM battute WHERE flay_id=3 ORDER BY row_id LIMIT 3) t)});
    eval { run_stage(5, overwrite => 1) };
    ok(ScriptManager::Exception->caught($@, 'validation_state'), 'stato non ricostruibile blocca prima del reset');
    is track_state(3)->[2], 'NA', 'nessun reset distruttivo dopo errore di precondizione';
};

subtest 'sovrascrittura 04 ricostruisce tutte le classificazioni e invalida piste' => sub {
    run_stage(4, overwrite => 1);
    is_deeply [@{track_state(3)}[0 .. 3]], ['Y', 1, undef, undef];
    is_deeply [@{track_state(4)}[0 .. 3]], ['Y', 1, undef, undef];
    is $admin->selectrow_array(q{SELECT COUNT(*) FROM battute WHERE flay_id IN (3,4) AND validation='Y'}), 16,
        'riscrive anche i flag uguali a quelli precedenti al reset';
    is_deeply days('trova_pista_atterraggi'), [];
    is_deeply days('trova_pista_decolli'), [];
    is_deeply days('valida_tracce'), ['2026-11-02'];
};

subtest 'errore dopo scrittura non genera skip e invalida i completamenti dipendenti' => sub {
    eval { run_stage(3, overwrite => 1, fail_write => 1) };
    like "$@", qr/write failed after update/, 'errore propagato';
    is_deeply days('valida_tracce'), [];
    is_deeply days('valida_battute'), [];
    run_stage(3, overwrite => 1);
    is_deeply [@{track_state(3)}[0 .. 4]], ['Y', undef, undef, undef, undef], 'ripristino e nuovo 03 riusciti';
    is $admin->selectrow_array('SELECT COUNT(*) FROM battute WHERE flay_id IN (3,4) AND validation IS NULL'), 16;
    is track_state(8)->[0], 'M';
    is track_state(1)->[1], 1, 'nessun reset del giorno precedente';
};

subtest 'lock fra fasi diverse e isolamento per database' => sub {
    my $guard = $repo->lock_validation_target($target);
    eval { $repo->lock_validation_target($target) };
    ok(ScriptManager::Exception->caught($@, 'validation_busy'), 'non ammette due pipeline concorrenti sullo stesso target');
    my $other = $repo->lock_validation_target("$target-other");
    ok $other, 'database diverso indipendente';
    is_deeply $repo->completed_validation_days("$target-other", 'valida_tracce'), [], 'storico non condiviso fra database';
    undef $guard;
    ok $repo->lock_validation_target($target), 'lock rilasciato al termine';
};

subtest 'un record giornaliero non basta senza esecuzione completata' => sub {
    my $id = $repo->create_execution(procedure_code => 'test_sum', requested_by => 'validation-test');
    $repo->mark_running($id);
    my $key = "$target-lifecycle";
    $repo->complete_validation_days($key, 'valida_tracce', ['2026-11-01'], $id);
    is_deeply $repo->completed_validation_days($key, 'valida_tracce'), [], 'running non determina skip';
    $repo->mark_finished($id, status => 'failed', exit_code => 1);
    is_deeply $repo->completed_validation_days($key, 'valida_tracce'), [], 'failed non determina skip';
    $repo->mark_finished($id, status => 'cancelled', exit_code => 1);
    is_deeply $repo->completed_validation_days($key, 'valida_tracce'), [], 'cancelled non determina skip';
    $repo->mark_finished($id, status => 'completed', exit_code => 0);
    is_deeply $repo->completed_validation_days($key, 'valida_tracce'), ['2026-11-01'];
};

subtest 'senza intervallo copre tutti i giorni tranne quelli completati' => sub {
    my $r = run_stage(3, date_from => undef, date_to => undef);
    is_deeply $r->{data}{days_processed}, ['2026-11-01', '2026-11-03'];
    is_deeply $r->{data}{days_skipped}, ['2026-11-02'];
    is track_state(5)->[0], 'Y', 'incluso anche il giorno successivo';
    is track_state(7)->[0], undef, 'esclusa data assente anche senza limiti';
};

subtest '03 sovrascrive anche scarti precedenti, 04 conserva gli scarti di 03' => sub {
    $admin->do('UPDATE battute SET X_m = X_m + 100000 WHERE flay_id = 5');
    run_stage(3, date_from => '2026-11-03', date_to => '2026-11-03', overwrite => 1);
    is track_state(5)->[0], 'N', 'nuovo esito negativo su traccia prima valida';
    run_stage(4, date_from => '2026-11-03', date_to => '2026-11-03', overwrite => 1);
    is track_state(5)->[0], 'N', '04 non ripristina gli scarti di 03';
    is $admin->selectrow_array(q{SELECT COUNT(*) FROM battute WHERE flay_id=5 AND validation='A'}), 8;
    $admin->do('UPDATE battute SET X_m = X_m - 100000 WHERE flay_id = 5');
    run_stage(3, date_from => '2026-11-03', date_to => '2026-11-03', overwrite => 1);
    is track_state(5)->[0], 'Y', 'scarto precedente riesaminato con dati corretti';
    is $admin->selectrow_array('SELECT COUNT(*) FROM battute WHERE flay_id=5 AND validation IS NULL'), 8,
        'rimuove le classificazioni A obsolete';
};

subtest '07 usa data_ora_arr, preserva le SID senza overwrite e limita anche NA' => sub {
    for my $id (10 .. 18) {
        my $local_date = $id == 10 ? '2026-11-04 12:00:00' : $id == 18 ? undef : '2026-11-05 12:00:00';
        my $arrival_date = $id == 10 ? '2026-11-05 00:00:00' : $id == 11 ? '2026-11-05 23:59:59'
            : $id == 12 ? '2026-11-06 00:00:00' : $id == 14 ? undef : '2026-11-05 12:00:00';
        $admin->do('INSERT INTO flay (row_id, flay_operation, data_ora_italy, data_ora_arr, validation_fl, validation_bt, pista, sid) '
            . 'VALUES (?, ?, ?, ?, ?, ?, ?, ?)', undef, $id, $id == 13 ? 'A' : 'D',
            $local_date, $arrival_date, $id == 17 ? 'M' : 'Y', $id == 15 ? 2 : 1,
            $id == 15 || $id == 16 ? '29' : '11', $id == 11 ? 'KEEP' : undef);
        for my $i (0 .. 2) {
            $admin->do('INSERT INTO battute (flay_id, time_italy, X_m, Y_m, H_m, validation) VALUES (?, ?, ?, ?, ?, ?)',
                undef, $id, sprintf('2026-11-05 12:00:%02d', $i), 100 * $i, 0, 300, 'Y');
        }
    }
    $admin->do('DELETE FROM battute WHERE flay_id = 16');
    for my $hit (['2026-11-05 12:00:02', 1546520, 5057500], ['2026-11-05 12:00:01', 0, 0]) {
        $admin->do('INSERT INTO battute (flay_id, time_italy, X_m, Y_m, H_m, validation) VALUES (?, ?, ?, ?, ?, ?)',
            undef, 16, @$hit, 1000, 'Y');
    }
    my $r = run_stage(7, date_from => '2026-11-05', date_to => '2026-11-05');
    is_deeply [@{$r->{data}}{qw(tracks assigned unassigned)}], [4, 3, 1];
    is track_state(10)->[3], '150', 'data arrivo inclusa anche con data locale fuori intervallo';
    is track_state(11)->[3], 'KEEP', 'SID esistente preservata senza overwrite';
    is track_state(12)->[3], undef, 'escluso il giorno successivo anche se data locale nel range';
    is track_state(13)->[3], undef, 'nessun fallback NA sugli arrivi';
    is track_state(14)->[3], undef, 'data_ora_arr mancante esclusa';
    is track_state(15)->[3], undef, 'bt>1 senza match rimane NULL come nel legacy';
    is track_state(16)->[3], '267', 'salta la prima battuta cronologica, non la prima inserita';
    is track_state(17)->[3], undef, 'M preservata';
    is track_state(18)->[3], '150', 'data locale assente non esclude una data_ora_arr valida';
    $r = run_stage(7, date_from => '2026-11-05', date_to => '2026-11-05');
    is_deeply $r->{data}{days_skipped}, ['2026-11-05'];
    run_stage(7, date_from => '2026-11-05', date_to => '2026-11-05', overwrite => 1);
    is_deeply [@{track_state(11)}[0 .. 3]], ['Y', 1, '11', '150'], 'overwrite modifica solo SID';
};

subtest '07 valida prima del reset e non registra successo dopo errori di scrittura' => sub {
    my $before = $admin->selectall_arrayref('SELECT row_id, sid FROM flay ORDER BY row_id');
    $admin->do('UPDATE battute SET H_m = NULL WHERE flay_id = 16');
    eval { run_stage(7, date_from => '2026-11-05', date_to => '2026-11-05', overwrite => 1) };
    ok(ScriptManager::Exception->caught($@, 'invalid_hit'), 'dati non validi fermano prima di azzerare SID');
    is_deeply $admin->selectall_arrayref('SELECT row_id, sid FROM flay ORDER BY row_id'), $before;
    $admin->do('UPDATE battute SET H_m = 1000 WHERE flay_id = 16');
    eval { run_stage(7, date_from => '2026-11-05', date_to => '2026-11-05', overwrite => 1, fail_write => 1) };
    like "$@", qr/write failed after update/, 'errore dopo reset propagato';
    is_deeply days('assegna_sid'), [], 'nessun completamento obsoleto dopo reset interrotto';
    cmp_ok $repo->get_execution($last_id)->{progress}, '<', 100, 'nessun falso 100%';
    run_stage(7, date_from => '2026-11-05', date_to => '2026-11-05', overwrite => 1);
    is track_state(11)->[3], '150', 'ricalcolo dopo errore riuscito';
};

subtest '06 e 04 invalidano 07 sulla data dei decolli, anche se cambia giorno' => sub {
    run_stage(6, date_from => '2026-11-04', date_to => '2026-11-04', overwrite => 1);
    is_deeply days('assegna_sid'), [], '06 sul giorno locale 4 invalida lo storico SID del giorno 5';
    run_stage(7, date_from => '2026-11-05', date_to => '2026-11-05');
    $repo->complete_validation_days($target, 'assegna_sid', ['2026-11-07'], $last_id);
    for (1 .. 5) {
        $admin->do('INSERT INTO battute (flay_id, time_italy, X_m, Y_m, H_m, validation) VALUES (?, ?, ?, ?, ?, ?)',
            undef, 10, '2026-11-07 12:00:00', 0, 0, 300, 'Y');
    }
    my $hits = $admin->selectcol_arrayref('SELECT row_id FROM battute WHERE flay_id = 10 ORDER BY row_id');
    for my $i (0 .. $#$hits) {
        $admin->do('UPDATE battute SET time_italy = ?, X_m = ? WHERE row_id = ?',
            undef, sprintf('2026-11-07 12:00:%02d', $i), 100 * $i, $hits->[$i]);
    }
    run_stage(4, date_from => '2026-11-04', date_to => '2026-11-04', overwrite => 1);
    is track_state(10)->[4], '2026-11-07 12:00:00', '04 sposta la data calcolata al giorno 7';
    is_deeply days('assegna_sid'), [], 'invalidati sia il vecchio giorno 5 sia quello nuovo 7';
};

subtest 'form web: due selettori data e sovrascrittura non preselezionata' => sub {
    my $root = $app->home;
    local $ENV{MRT_CONFIG_FILE} = $root->child('config', 'MRT.example.json')->to_string;
    my $web = TestHelper::mojo(paths => {procedures_file => $root->child('config', 'procedures.yml')->to_string});
    Log::Any::Adapter->set('Null');
    for my $code (qw(valida_tracce valida_battute trova_pista_atterraggi trova_pista_decolli assegna_sid)) {
        $web->get_ok("/procedures/$code")->status_is(200)
            ->element_exists('input[type=date][name=date_from]')
            ->element_exists('input[type=date][name=date_to]')
            ->element_exists('input[type=checkbox][name=overwrite]')
            ->element_exists_not('input[name=overwrite][checked]');
    }
};

done_testing;
