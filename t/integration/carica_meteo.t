use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper;
use TestOpenMeteo;
use DBI;
use File::Temp 'tempdir';
use Mojo::File 'path';
use Mojo::JSON 'decode_json';
use Log::Any ();
use Log::Any::Adapter;
use ScriptManager::Service::Context;
use ScriptManager::Command::CaricaMeteo;
use ScriptManager::Command::CorreggiQuote;
use ScriptManager::Service::OpenMeteoQuota;

plan skip_all => 'Richiede TEST_ONLINE e TEST_MYSQL=1'
    unless TestHelper::online() && ($ENV{TEST_MYSQL} // '') eq '1';

{
    package WeatherStatement;
    use Mojo::Base -base, -signatures;
    has [qw(statement owner)];
    sub execute ($self, @values) {
        my $r = $self->statement->execute(@values);
        die "write failed after insert\n" if $self->owner->fail_write;
        return $r;
    }
    sub finish ($self) { return $self->statement->finish }
}
{
    package WeatherDatabase;
    use Mojo::Base -base, -signatures;
    has 'db';
    has fail_write => 0;
    has fail_update => 0;
    sub selectrow_arrayref ($self, @args) { return [233.782] }
    sub selectcol_arrayref ($self, @args) { return $self->db->selectcol_arrayref(@args) }
    sub selectall_arrayref ($self, @args) { return $self->db->selectall_arrayref(@args) }
    sub selectrow_array ($self, @args) { return $self->db->selectrow_array(@args) }
    sub do ($self, @args) {
        my $result = $self->db->do(@args);
        die "write failed after update\n" if $self->fail_update;
        return $result;
    }
    sub prepare ($self, @args) { return WeatherStatement->new(statement => $self->db->prepare(@args), owner => $self) }
    sub disconnect ($self) { return $self->db->disconnect }
}
{
    package WeatherContext;
    use Mojo::Base 'ScriptManager::Service::Context', -signatures;
    has fail_artifact => 0;
    sub write_artifact ($self, @args) {
        die "artifact failed\n" if $self->fail_artifact;
        return $self->SUPER::write_artifact(@args);
    }
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
    CREATE TABLE meteo (
      row_id INT UNSIGNED PRIMARY KEY AUTO_INCREMENT, data_ora DATETIME,
      precipitazione_mm DOUBLE(6,1), temperatura_C DOUBLE(4,1),
      direzione_vento1 SMALLINT UNSIGNED, direzione_vento2 SMALLINT UNSIGNED,
      velocita_vento DOUBLE(4,1) UNSIGNED, umidita_relativa TINYINT UNSIGNED,
      radiazione_netta SMALLINT, radiazione_globale SMALLINT UNSIGNED, pressione_hpa DOUBLE(5,1),
      INDEX(data_ora)
    ) ENGINE=MyISAM
});
$admin->do(q{CREATE TABLE meteo_cgp (data_ora DATETIME, temperatura_C DOUBLE) ENGINE=MyISAM});
$admin->do(q{CREATE TABLE flay (
    row_id INT PRIMARY KEY, data_ora_arr DATETIME, data_ora_italy DATETIME,
    validation_fl CHAR(1), validation_bt INT, flay_operation CHAR(1), pista CHAR(3), sid CHAR(5)
) ENGINE=MyISAM});
$admin->do(q{CREATE TABLE battute (
    row_id INT PRIMARY KEY, flay_id INT, time_italy DATETIME, validation CHAR(1),
    H_m DOUBLE, Z_m DOUBLE, A_m DOUBLE, hmod CHAR(1)
) ENGINE=MyISAM});
$admin->do(q{INSERT INTO meteo_cgp VALUES ('2025-01-15 12:00:00', 77)});
for my $day ('2025-01-14', '2025-01-15', '2025-01-17') {
    $admin->do('INSERT INTO meteo (data_ora, temperatura_C) VALUES (?, ?)', undef, "$day 12:00:00", 77);
}
my $output = tempdir(CLEANUP => 1);
my $last_id;
sub run_weather (%options) {
    my $weather = delete $options{weather} // TestOpenMeteo->new;
    my $fail_write = delete $options{fail_write} // 0;
    my $fail_artifact = delete $options{fail_artifact} // 0;
    my $cancel = delete $options{cancel};
    $last_id = $repo->create_execution(procedure_code => 'test_sum', requested_by => 'meteo-test');
    $repo->mark_running($last_id);
    $repo->request_cancel($last_id) if $cancel;
    my $ctx = WeatherContext->new(execution_id => $last_id, repo => $repo,
        output_root => $output, retention_days => 7, logger => Log::Any->get_logger, fail_artifact => $fail_artifact);
    my $command = ScriptManager::Command::CaricaMeteo->new(weather => $weather, connect_db => sub {
        my $db = DBI->connect("$dsn;database=$schema", $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD},
            {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        return WeatherDatabase->new(db => $db, fail_write => $fail_write);
    });
    my $result = eval { $command->run($ctx, {
        database => $schema, airport => 'LIMC', date_from => '2025-01-15', date_to => '2025-01-16', %options}) };
    my $error = $@;
    $repo->mark_finished($last_id, status => $error ? 'failed' : 'completed', exit_code => $error ? 1 : 0);
    $ctx->validation_guard(undef);
    die $error if $error;
    return $result;
}
sub snapshot () { return $admin->selectall_arrayref('SELECT * FROM meteo ORDER BY row_id') }
sub count_day ($day) {
    return $admin->selectrow_array('SELECT COUNT(*) FROM meteo WHERE DATE(data_ora)=?', undef, $day);
}
sub run_normalize (%options) {
    my $fail_update = delete $options{fail_update} // 0;
    my $cancel = delete $options{cancel};
    $last_id = $repo->create_execution(procedure_code => 'test_sum', requested_by => 'normalize-test');
    $repo->mark_running($last_id);
    $repo->request_cancel($last_id) if $cancel;
    my $ctx = WeatherContext->new(execution_id => $last_id, repo => $repo,
        output_root => $output, retention_days => 7, logger => Log::Any->get_logger);
    my $command = ScriptManager::Command::CorreggiQuote->new(connect_db => sub {
        my $db = DBI->connect("$dsn;database=$schema", $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD},
            {RaiseError => 1, PrintError => 0, AutoCommit => 1});
        return WeatherDatabase->new(db => $db, fail_update => $fail_update);
    });
    my $result = eval { $command->run($ctx, {
        database => $schema, airport => 'LIMC', date_from => '2025-01-15', date_to => '2025-01-15', %options}) };
    my $error = $@;
    $repo->mark_finished($last_id, status => $error ? 'failed' : 'completed', exit_code => $error ? 1 : 0);
    $ctx->validation_guard(undef);
    die $error if $error;
    return $result;
}

subtest 'importazione oraria limitata alle date, skip e report UTC persistente' => sub {
    my $weather = TestOpenMeteo->new;
    my $r = run_weather(weather => $weather);
    is_deeply $r->{data}{days_processed}, ['2025-01-16'];
    is_deeply $r->{data}{days_skipped}, ['2025-01-15'];
    is $r->{data}{rows}, 24;
    is count_day('2025-01-15'), 1, 'misura di centralina preservata anche se giorno parziale';
    is count_day('2025-01-16'), 24;
    is_deeply [@{$weather->requests->[0]}[1, 2]], ['2025-01-16', '2025-01-16'], 'nessun download per giorni saltati';
    my $values = $admin->selectrow_arrayref(
        'SELECT precipitazione_mm, temperatura_C, pressione_hpa, velocita_vento, direzione_vento2, radiazione_netta '
        . 'FROM meteo WHERE data_ora=?', undef, '2025-01-16 01:00:00');
    is_deeply [map { defined $_ ? 0 + $_ : undef } @$values], [0, 2.4, 990, 3, undef, undef];
    my $audit = decode_json(path($output, $last_id, 'meteo-open-meteo.json')->slurp);
    is $audit->{location}{elevation}, 233.782;
    is scalar @{$audit->{batches}[0]{response}{hourly}{time}}, 48;
    like $audit->{attribution}, qr/Open-Meteo.*CC BY/;
    is scalar @{$repo->list_artifacts($last_id)}, 1;
    $weather = TestOpenMeteo->new;
    $r = run_weather(weather => $weather);
    is $r->{data}{rows}, 0;
    is_deeply $weather->requests, [], 'tutti presenti: nessuna API e nessun duplicato';
    is count_day('2025-01-16'), 24;
};

subtest 'overwrite sostituisce solo i giorni richiesti e conserva meteo_cgp' => sub {
    my $r = run_weather(overwrite => 1);
    is $r->{data}{rows}, 48;
    is count_day('2025-01-15'), 24, 'sostituita anche la misura di centralina, come approvato';
    is count_day('2025-01-16'), 24, 'nessun duplicato';
    is count_day('2025-01-14'), 1;
    is count_day('2025-01-17'), 1;
    is $admin->selectrow_array('SELECT temperatura_C FROM meteo_cgp'), 77;
};

subtest 'API, dati, report e annullamento falliscono prima delle scritture' => sub {
    my $before = snapshot();
    for my $case ({weather => TestOpenMeteo->new(fail_request => 1)},
        {weather => TestOpenMeteo->new(null_pressure => 1)}, {fail_artifact => 1}, {cancel => 1}) {
        eval { run_weather(overwrite => 1, %$case) };
        ok $@, 'errore propagato';
        is_deeply snapshot(), $before, 'nessun DELETE o INSERT prima della fine analisi/report';
        cmp_ok $repo->get_execution($last_id)->{progress}, '<', 100;
    }
    my $target = join ':', lc($ENV{MYSQL_HOST}), $ENV{MYSQL_PORT} // 3306, $schema;
    my $guard = $repo->lock_validation_target($target);
    eval { run_weather(overwrite => 1) };
    ok(ScriptManager::Exception->caught($@, 'validation_busy'), '09 condivide il blocco con 03-08');
    undef $guard;
    is_deeply snapshot(), $before;
};

subtest 'scrittura parziale esplicita, giorno successivo intatto e recupero con overwrite' => sub {
    my $later = $admin->selectall_arrayref('SELECT * FROM meteo WHERE DATE(data_ora)=?', undef, '2025-01-16');
    eval { run_weather(overwrite => 1, fail_write => 1) };
    like "$@", qr/write failed after insert/;
    is count_day('2025-01-15'), 1, 'AutoCommit: prima riga rimane, non promette rollback';
    is_deeply $admin->selectall_arrayref('SELECT * FROM meteo WHERE DATE(data_ora)=?', undef, '2025-01-16'),
        $later, 'non cancella anticipatamente i giorni successivi';
    cmp_ok $repo->get_execution($last_id)->{progress}, '<', 100;
    run_weather(overwrite => 1);
    is count_day('2025-01-15'), 24;
};

subtest 'DST e giorni consecutivi nel calendario locale, senza zeri inventati' => sub {
    run_weather(date_from => '2025-03-30', date_to => '2025-03-30');
    is count_day('2025-03-30'), 23;
    run_weather(date_from => '2025-10-26', date_to => '2025-10-26');
    is count_day('2025-10-26'), 24;
    is $admin->selectrow_array('SELECT temperatura_C FROM meteo WHERE data_ora=?',
        undef, '2025-10-26 02:00:00'), 2.5;
    my $audit = decode_json(path($output, $last_id, 'meteo-open-meteo.json')->slurp);
    is scalar @{$audit->{batches}[0]{discarded}}, 1;
    ok grep({ $_->{message} =~ /Ora ripetuta/ } @{$repo->list_events($last_id)}), 'avviso persistente DST';
    my $weather = TestOpenMeteo->new;
    run_weather(date_from => '2024-02-01', date_to => '2024-03-02', weather => $weather);
    is scalar @{$weather->requests}, 3, 'massimo 13 giorni locali piu margine UTC per richiesta: sempre 1 chiamata';
    is count_day('2024-02-29'), 24, 'giorno bisestile incluso';
};

subtest 'form con date obbligatorie e avviso sostituzione centraline' => sub {
    my $root = $app->home;
    local $ENV{MRT_CONFIG_FILE} = $root->child('config', 'MRT.example.json')->to_string;
    my $web = TestHelper::mojo(paths => {procedures_file => $root->child('config', 'procedures.yml')->to_string});
    Log::Any::Adapter->set('Null');
    $web->get_ok('/procedures/carica_meteo')->status_is(200)
        ->element_exists('input[type=date][name=date_from][required]')
        ->element_exists('input[type=date][name=date_to][required]')
        ->element_exists_not('input[name=overwrite][checked]')
        ->content_like(qr/centraline/);
    $web->get_ok('/procedures/correggi_quote')->status_is(200)
        ->element_exists('input[type=date][name=date_from]')
        ->element_exists('input[type=date][name=date_to]')
        ->element_exists_not('input[name=date_from][required]')
        ->element_exists_not('input[name=overwrite][checked]')
        ->content_like(qr/ARP/);
};

subtest 'budget persistente globale: tentativi, finestre mobili, nessuna chiamata per skip' => sub {
    my $quota = ScriptManager::Service::OpenMeteoQuota->new(repo => $repo, execution_id => $last_id);
    my $before = $quota->snapshot;
    my $other = ScriptManager::Service::OpenMeteoQuota->new(repo => $repo);
    my $id = $other->reserve;
    $other->finish($id, 0);
    my $after = $quota->snapshot;
    is $after->{used}{day}, $before->{used}{day} + 1, 'fallimento conta globalmente fra esecuzioni/database';
    is $after->{remaining}{day}, $after->{limits}{day} - $after->{used}{day};
    $repo->pg->db->query(q{update weather_api_calls set reserved_at = clock_timestamp() - interval '2 minutes' where id = ?}, $id);
    is $quota->snapshot->{used}{minute}, $after->{used}{minute} - 1, 'minuto mobile si ripristina';
    is $quota->snapshot->{used}{day}, $after->{used}{day}, 'giorno mantiene il consumo';
    $repo->pg->db->query(q{update weather_api_calls set reserved_at = clock_timestamp() - interval '32 days' where id = ?}, $id);
    is $quota->snapshot->{used}{month}, $before->{used}{month}, 'finestra prudenziale mensile 31 giorni';
    my $weather = TestOpenMeteo->new;
    $before = $quota->snapshot;
    run_weather(weather => $weather);
    is_deeply $weather->requests, [];
    is $quota->snapshot->{used}{day}, $before->{used}{day}, 'skip non consuma chiamate';
    my $limited = $repo->reserve_weather_call(undef, {minute => 1000000, hour => 1000000, day => 1000000, month => 1000000});
    my $usage = $repo->weather_usage(undef);
    eval { $repo->reserve_weather_call(undef, {minute => $usage->{minute}, hour => 1000000, day => 1000000, month => 1000000}) };
    ok(ScriptManager::Exception->caught($@, 'weather_quota'), 'limite verificato nella prenotazione atomica');
    is $repo->weather_usage(undef)->{minute}, $usage->{minute}, 'rifiuto non registra o invia una chiamata';
    $repo->pg->db->query('delete from weather_api_calls where id = ?', $limited);
    my $snapshot = $quota->snapshot;
    $snapshot->{remaining}{day} = 0;
    eval { $quota->check(1, $snapshot) };
    ok(ScriptManager::Exception->caught($@, 'weather_quota'), 'previsione intercetta budget insufficiente');
    $before = $quota->snapshot;
    eval { run_weather(overwrite => 1, weather => TestOpenMeteo->new(fail_request => 1)) };
    ok $@, 'errore HTTP propagato';
    is $quota->snapshot->{used}{day}, $before->{used}{day} + 1, 'tentativo HTTP fallito contabilizzato';
    is $repo->pg->db->query('select status from weather_api_calls where execution_id = ?', $last_id)->hash->{status},
        'failed', 'stato persistente del tentativo fallito';
};

subtest 'soglie pubbliche esatte, riserva atomica e consumo conservato dopo pulizia esecuzioni' => sub {
    my $isolated = TestHelper::mojo()->app->repo;
    Log::Any::Adapter->set('Null');
    my $quota = ScriptManager::Service::OpenMeteoQuota->new(repo => $isolated);
    my $db = $isolated->pg->db;
    for my $case (['minute', 600, '0 seconds'], ['hour', 5000, '2 minutes'],
        ['day', 10000, '2 hours'], ['month', 300000, '2 days']) {
        my ($window, $limit, $age) = @$case;
        $db->query('delete from weather_api_calls');
        $db->query(q{
            insert into weather_api_calls (reserved_at)
            select clock_timestamp() - ?::interval from generate_series(1, ?)
        }, $age, $limit - 1);
        ok $quota->reserve, "$window: chiamata $limit ammessa";
        eval { $quota->reserve };
        ok(ScriptManager::Exception->caught($@, 'weather_quota'), "$window: chiamata successiva rifiutata");
        is $quota->snapshot->{used}{$window}, $limit, "$window: nessuna prenotazione oltre soglia";
        is $quota->snapshot->{remaining}{$window}, 0;
    }
    $db->query('delete from weather_api_calls');
    my $execution = $isolated->create_execution(procedure_code => 'test_sum', requested_by => 'quota-test');
    my $id = $isolated->reserve_weather_call($execution, $quota->limits);
    $db->query('delete from executions where id = ?', $execution);
    is $quota->snapshot->{used}{day}, 1, 'pulizia storico esecuzioni non restituisce budget';
    is_deeply $db->query('select execution_id, status from weather_api_calls where id = ?', $id)->array,
        [undef, 'reserved'], 'tentativo interrotto rimane conteggiato anche senza esecuzione';
};

subtest '10: normalizza solo tracce eleggibili e usa ora contenente e quota ARP, senza API' => sub {
    run_weather(overwrite => 1);
    for my $id (1 .. 8) {
        my $time = $id == 3 ? '2025-01-16 01:37:00' : $id == 5 ? undef : '2025-01-15 01:37:00';
        $admin->do('INSERT INTO flay VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            undef, $id, $time, '2025-01-17 01:00:00', $id == 4 ? 'M' : 'Y',
            $id == 6 ? 1 : $id == 7 ? 3 : 2, $id % 2 ? 'A' : 'D', '29', 'KEEP');
        $admin->do('INSERT INTO battute VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            undef, $id, $id, '2025-01-15 01:00:00', 'Y', 1200, 1000, $id == 7 ? 777 : undef, 'M');
    }
    $admin->do(q{UPDATE battute SET Z_m=NULL WHERE flay_id=8});
    for my $hit ([20, 'N'], [21, 'A'], [22, undef], [23, 'S']) {
        $admin->do('INSERT INTO battute VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            undef, $hit->[0], 1, '2025-01-15 01:00:00', $hit->[1], 1200, 1000, undef, undef);
    }
    my $before = $repo->weather_usage(undef)->{day};
    my $r = run_normalize();
    is_deeply [@{$r->{data}}{qw(tracks hits skipped_tracks)}], [2, 3, 1], 'A/D, nessun avanzamento senza Z_m';
    my $expected = ScriptManager::Command::CorreggiQuote->normalize(1000, 990, 2.4, 233.782);
    cmp_ok abs($admin->selectrow_array('SELECT A_m FROM battute WHERE row_id=1') - $expected), '<', 0.00001,
        'usa 01:00 per 01:37 e quota ARP, non quota Ferno';
    is $admin->selectrow_array('SELECT validation_bt FROM flay WHERE row_id=1'), 3;
    is $admin->selectrow_array('SELECT validation_bt FROM flay WHERE row_id=2'), 3, 'anche decolli';
    for my $id (3 .. 8, 20 .. 22) {
        is $admin->selectrow_array('SELECT A_m FROM battute WHERE row_id=?', undef, $id),
            $id == 7 ? 777 : undef, "battuta $id fuori ambito o esclusa preservata";
    }
    ok defined $admin->selectrow_array('SELECT A_m FROM battute WHERE row_id=23'), 'S inclusa come nel legacy 10';
    is $repo->weather_usage(undef)->{day}, $before, 'fase 10 non chiama Open-Meteo';
    my $target = join ':', lc($ENV{MYSQL_HOST}), $ENV{MYSQL_PORT} // 3306, $schema;
    is_deeply $repo->completed_validation_days($target, 'correggi_quote'), [], 'giorno con skip non marcato completo';
    $admin->do(q{UPDATE battute SET Z_m=1000 WHERE flay_id=8});
    $r = run_normalize();
    is $r->{data}{tracks}, 1, 'ritenta solo la traccia rimasta allo stato 2';
    is_deeply $repo->completed_validation_days($target, 'correggi_quote'), ['2025-01-15'];
    $r = run_normalize();
    is_deeply $r->{data}{days_skipped}, ['2025-01-15'];
    run_normalize(overwrite => 1);
    cmp_ok abs($admin->selectrow_array('SELECT A_m FROM battute WHERE row_id=7') - $expected), '<', 0.00001,
        'overwrite include stato 3 e ricalcola da Z_m';
    is_deeply $admin->selectrow_arrayref('SELECT H_m, Z_m, hmod FROM battute WHERE row_id=1'), [1200, 1000, 'M'];
};

subtest '10: provenienza obbligatoria, modifiche meteo rilevate e fallimenti recuperabili' => sub {
    my $target = join ':', lc($ENV{MYSQL_HOST}), $ENV{MYSQL_PORT} // 3306, $schema;
    $admin->do(q{UPDATE flay SET validation_bt=2 WHERE row_id=1});
    $admin->do(q{UPDATE meteo SET temperatura_C=99 WHERE data_ora='2025-01-15 01:00:00'});
    my $r = run_normalize(overwrite => 1);
    is $r->{data}{tracks}, 0, 'nessun utilizzo del meteo manomesso o di centraline';
    ok $r->{data}{skipped_tracks} > 0;
    is $admin->selectrow_array('SELECT validation_bt FROM flay WHERE row_id=1'), 2;
    run_weather(overwrite => 1);
    is_deeply $repo->completed_validation_days($target, 'correggi_quote'), [], '09 invalida storico 10';
    eval { run_normalize(overwrite => 1, fail_update => 1) };
    like "$@", qr/write failed after update/;
    cmp_ok $repo->get_execution($last_id)->{progress}, '<', 100;
    run_normalize(overwrite => 1);
    is $admin->selectrow_array('SELECT validation_bt FROM flay WHERE row_id=1'), 3;
    my $guard = $repo->lock_validation_target($target);
    eval { run_normalize(overwrite => 1) };
    ok(ScriptManager::Exception->caught($@, 'validation_busy'));
    undef $guard;
    eval { run_normalize(overwrite => 1, cancel => 1) };
    ok(ScriptManager::Exception->caught($@, 'cancelled'));
    $repo->invalidate_weather_day($target, '2025-01-15');
    $r = run_normalize(overwrite => 1);
    is $r->{data}{tracks}, 0, 'meteo senza provenienza non assunto come Open-Meteo';
    ok grep({ $_->{message} =~ /provenienza Open-Meteo assente/ } @{$repo->list_events($last_id)}), 'avviso esplicito';
};

subtest '10: provenienza ARP incompleta o incompatibile salta senza modificare le tracce' => sub {
    run_weather(overwrite => 1);
    my $import_id = $last_id;
    my $target = join ':', lc($ENV{MYSQL_HOST}), $ENV{MYSQL_PORT} // 3306, $schema;
    my $record = $repo->weather_day($target, '2025-01-15');
    my $before = $admin->selectall_arrayref('SELECT row_id, A_m FROM battute ORDER BY row_id');
    for my $source (undef, 'invalid', {}, {%{$record->{location}}, latitude => undef},
        {%{$record->{location}}, airport => 'LIML'}, {%{$record->{location}}, elevation => 120}) {
        $repo->record_weather_day($target, '2025-01-15', $source, $record->{fingerprint}, $import_id);
        my $r = run_normalize(overwrite => 1);
        is $r->{data}{tracks}, 0, 'metadati non verificabili non usati nella formula';
        ok $r->{data}{skipped_tracks} > 0;
        is_deeply $admin->selectall_arrayref('SELECT row_id, A_m FROM battute ORDER BY row_id'), $before,
            'overwrite non azzera le quote delle tracce saltate';
    }
};

subtest 'richiesta reale Open-Meteo e persistenza isolata (opt-in)' => sub {
    plan skip_all => 'Richiede TEST_OPEN_METEO=1' unless ($ENV{TEST_OPEN_METEO} // '') eq '1';
    my $r = run_weather(weather => ScriptManager::Service::OpenMeteo->new,
        date_from => '2025-01-20', date_to => '2025-01-20');
    is $r->{data}{rows}, 24;
    is count_day('2025-01-20'), 24, 'dati reali scritti solo nel database temporaneo';
    my $audit = decode_json(path($output, $last_id, 'meteo-open-meteo.json')->slurp);
    like $audit->{batches}[0]{request}, qr{https://archive-api.open-meteo.com/v1/archive};
    is $audit->{batches}[0]{response}{elevation}, 233.782;
};

done_testing;
