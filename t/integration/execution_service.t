use Mojo::Base -strict;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper;
use File::Temp 'tempdir';
use Mojo::File 'path';
use ScriptManager::Command::CaricaDB;

plan skip_all => 'TEST_ONLINE non impostata' unless TestHelper::online();

my $t       = TestHelper::mojo();
my $service = $t->app->execution_service;
my $repo    = $t->app->repo;

subtest 'sync success' => sub {
    my $r = $service->submit(test_sum => {a => '2', b => '3'}, requested_by => 'tester');
    ok $r->{id}, 'execution created';
    my $e = $repo->get_execution($r->{id});
    is $e->{status}, 'completed';
    is $e->{summary}, 'sum=5';
    is $e->{progress}, 100;
    is $e->{requested_by}, 'tester';
    is_deeply $e->{parameters}, {a => 2, b => 3};
    ok scalar @{$repo->list_events($r->{id})} >= 2, 'events recorded';
};

subtest 'validation errors do not create executions' => sub {
    my $before = @{$repo->list_executions(limit => 100)};
    my $r      = $service->submit(test_sum => {a => 5000});
    ok $r->{errors} && @{$r->{errors}}, 'errors returned';
    is scalar @{$repo->list_executions(limit => 100)}, $before, 'nothing stored';
};

subtest 'unknown and disabled procedures' => sub {
    for my $code ('nope', 'test_disabled') {
        eval { $service->submit($code => {}) };
        ok(ScriptManager::Exception->caught($@, 'unknown_procedure'), "$code rejected");
    }
};

subtest 'failures are contained and not leaked' => sub {
    my $e = $repo->get_execution($service->submit(test_fail => {})->{id});
    is $e->{status}, 'failed';
    is $e->{error_code}, 'command_failed';

    $e = $repo->get_execution($service->submit(test_die => {})->{id});
    is $e->{status}, 'failed';
    is $e->{error_code}, 'internal_error';
    unlike $e->{error_message}, qr{/etc/passwd}, 'internal detail hidden';
    like $e->{error_message}, qr/\Q$e->{id}\E/, 'execution id for technical diagnosis';
    like $e->{error_message}, qr/docker compose logs app worker/, 'log lookup instructions';
    is $repo->list_events($e->{id})->[-1]{level}, 'critical', 'unhandled failure is CRITICAL';
    $t->get_ok("/executions/$e->{id}")->status_is(200)
        ->text_is('tr.critical td:nth-child(2)' => 'CRITICAL')
        ->content_unlike(qr{/etc/passwd});
};

subtest 'missing OUT files retain their cause in execution and events' => sub {
    my $empty = path(tempdir(CLEANUP => 1));
    local $ENV{FILE_OUT_ROOT} = 'E:\FILE_OUT';
    no warnings qw(redefine once);
    local *ScriptManager::Command::TestHandler::run = sub {
        my (undef, $ctx) = @_;
        ScriptManager::Command::CaricaDB->input_files("$empty", '.', {LIML => 'Linate'}, $ctx);
    };
    my $e = $repo->get_execution($service->submit(test_die => {})->{id});
    is $e->{status}, 'failed';
    is $e->{error_code}, 'out_files_missing';
    like $e->{error_message}, qr/Nessun file \.OUT/, 'actual cause stored';
    like $e->{error_message}, qr/FILE_OUT_ROOT/, 'actionable instruction stored';
    my $events = $repo->list_events($e->{id});
    is $events->[-1]{level}, 'error';
    is $events->[-1]{message}, $e->{error_message}, 'cause also visible in execution log';
    ok scalar(grep { $_->{message} =~ /E:\\FILE_OUT/ } @$events), 'host path recorded even when scan fails';
    $t->get_ok("/executions/$e->{id}")->status_is(200)
        ->content_like(qr/out_files_missing: Nessun file \.OUT/)
        ->content_like(qr/FILE_OUT_ROOT/);
    $t->get_ok("/api/executions/$e->{id}")->status_is(200)
        ->json_is('/error_code' => 'out_files_missing')
        ->json_is('/error_message' => $e->{error_message});
};

subtest 'logging levels and optional operation detail' => sub {
    no warnings qw(redefine once);
    local *ScriptManager::Command::TestHandler::run = sub {
        my (undef, $ctx) = @_;
        $ctx->log($_ => "operation $_") for qw(INFO WARNING ERROR CRITICAL);
        $ctx->debug_operation('record detail');
        return {success => 1, message => 'logging checked'};
    };
    for my $enabled (0, 1) {
        my $app = TestHelper::mojo(debug_operations => $enabled)->app;
        my $id = $app->execution_service->submit(test_sum => {a => 1, b => 2})->{id};
        my $events = $app->repo->list_events($id);
        for my $level (qw(info warning error critical)) {
            ok scalar(grep { $_->{level} eq $level && $_->{message} eq 'operation ' . uc($level) } @$events),
                "$level persisted";
        }
        is scalar(grep { $_->{message} eq 'record detail' && $_->{metadata}{detail} } @$events), $enabled,
            'detail follows application configuration';
        is $app->repo->get_execution($id)->{status}, 'completed', 'logging does not interrupt execution';
    }
};

subtest 'MySQL authentication failures appear as actionable ERROR events' => sub {
    my $input = path(tempdir(CLEANUP => 1));
    $input->child('LIML.OUT')->spew('connection fails before reading this file');
    local $ENV{MRT_CONFIG_FILE} = $t->app->home->child('config', 'MRT.example.json')->to_string;
    local $ENV{SCRIPT_MANAGER_OUT_ROOT} = "$input";
    local $ENV{MYSQL_HOST} = 'mysql.example.invalid';
    local $ENV{MYSQL_PORT} = 3306;
    local $ENV{MYSQL_USER} = 'test';
    local $ENV{MYSQL_PASSWORD} = 'hidden-test-password';
    my $driver = DBI->install_driver('MariaDB');
    no warnings qw(redefine once);
    local *ScriptManager::Command::TestHandler::run = sub {
        my (undef, $ctx) = @_;
        ScriptManager::Command::CaricaDB->new(connect_db => sub {
            $driver->set_err(1045, 'Access denied hidden-test-password /private/path');
            die "Access denied hidden-test-password /private/path\n";
        })->run($ctx, {radar => 'lin_2026', database => 'test_db', folder => '.'});
    };
    my $e = $repo->get_execution($service->submit(test_die => {})->{id});
    $driver->set_err(undef, undef);
    is $e->{status}, 'failed';
    is $e->{error_code}, 'mysql_authentication';
    is $repo->list_events($e->{id})->[-1]{level}, 'error', 'authentication error is not CRITICAL';
    $t->get_ok("/executions/$e->{id}")->status_is(200)
        ->content_like(qr/mysql_authentication: Autenticazione MySQL rifiutata/)
        ->content_unlike(qr/hidden-test-password|\/private\/path/);
    $t->get_ok("/api/executions/$e->{id}")->status_is(200)
        ->json_is('/error_code' => 'mysql_authentication')
        ->json_is('/error_message' => $e->{error_message});
};

subtest 'logging migration upgrades existing events' => sub {
    my $app = TestHelper::mojo()->app;
    my $migrations = Mojo::Pg::Migrations->new(pg => $app->pg)->name('script_manager')
        ->from_file($app->home->child('migrations', 'script_manager.sql')->to_string);
    $migrations->migrate(1);
    my $id = $app->pg->db->query(q{
        insert into executions (procedure_id, requested_by)
        select id, 'migration-test' from procedures where code = 'test_sum' returning id
    })->hash->{id};
    $app->repo->add_event($id, 'info', 'Evento precedente alla migrazione');
    my $before = $app->repo->list_events($id);
    $migrations->migrate;
    is_deeply $app->repo->list_events($id), $before, 'existing events preserved during upgrade';
    $app->repo->add_event($id, 'critical', 'critical after upgrade');
    is $app->repo->list_events($id)->[-1]{level}, 'critical', 'upgraded schema accepts critical';
    $migrations->migrate(1);
    is $app->repo->list_events($id)->[-1]{level}, 'error', 'downgrade preserves events as errors';
};

subtest 'MyISAM recovery requirements remain visible as CRITICAL' => sub {
    no warnings qw(redefine once);
    local *ScriptManager::Command::TestHandler::run = sub {
        ScriptManager::Exception->throw('mysql_recovery_required', 'Recupero MyISAM necessario; caricamenti bloccati');
    };
    my $e = $repo->get_execution($service->submit(test_die => {})->{id});
    is $e->{status}, 'failed';
    is $e->{error_code}, 'mysql_recovery_required';
    is $repo->list_events($e->{id})->[-1]{level}, 'critical';
    $t->get_ok("/executions/$e->{id}")->status_is(200)
        ->text_is('tr.critical td:nth-child(2)' => 'CRITICAL')
        ->content_like(qr/Recupero MyISAM necessario/);
};

subtest 'timeout' => sub {
    my $e = $repo->get_execution($service->submit(test_slow => {})->{id});
    is $e->{status}, 'timed_out';
    is $e->{error_code}, 'timed_out';
};

subtest 'sensitive parameters are not stored' => sub {
    my $e = $repo->get_execution($service->submit(test_secret => {token => 'hunter2'})->{id});
    is $e->{status}, 'completed';
    is $e->{summary}, 'token length 7';
    is_deeply $e->{parameters}, {mode => 'secret'};
    my $events = join ' ', map { $_->{message} } @{$repo->list_events($e->{id})};
    unlike $events, qr/hunter2/;
};

subtest 'async execution through Minion' => sub {
    my $r = $service->submit(test_async => {message => 'ciao', repeat => 2});
    my $e = $repo->get_execution($r->{id});
    is $e->{status}, 'queued';
    ok defined $e->{minion_job_id}, 'job id stored';

    $t->app->minion->perform_jobs;
    $e = $repo->get_execution($r->{id});
    is $e->{status}, 'completed';
    is $e->{progress}, 100;

    my $artifacts = $repo->list_artifacts($r->{id});
    is scalar @$artifacts, 1, 'artifact registered';
    like $artifacts->[0]{sha256}, qr/\A[0-9a-f]{64}\z/;
    ok -f $t->app->output_root->child($r->{id}, 'output.txt'), 'file on disk';
};

subtest 'cancel a queued execution' => sub {
    my $r = $service->submit(test_async => {message => 'x'});
    is $service->cancel($r->{id}), 'cancelled';
    $t->app->minion->perform_jobs;
    is $repo->get_execution($r->{id})->{status}, 'cancelled', 'job never ran';
    is $service->cancel($r->{id}), undef, 'cannot cancel twice';
};

subtest 'history filters' => sub {
    my $rows = $repo->list_executions(procedure => 'test_sum');
    ok @$rows, 'filter by procedure';
    ok !(grep { $_->{procedure_code} ne 'test_sum' } @$rows);
    is scalar @{$repo->list_executions(status => 'timed_out')}, 1;
    is scalar @{$repo->list_executions(id => 'not-a-uuid')}, 0, 'invalid id yields no rows';
    is scalar @{$repo->list_executions(id => $rows->[0]{id})}, 1;
};

subtest 'database queue: FIFO fra procedure, database indipendenti e attesa senza timeout' => sub {
    local $ENV{MYSQL_HOST} = 'mysql.test';
    local $ENV{MYSQL_PORT} = 3306;
    my $one = $service->submit(test_database_a => {database => 'db_one', message => 'first'})->{id};
    my $two = $service->submit(test_database_b => {database => 'db_one', message => 'second'})->{id};
    my $other = $service->submit(test_database_a => {database => 'db_two', message => 'independent'})->{id};
    is $repo->get_execution($two)->{queue_position}, 2, 'FIFO condivisa da procedure diverse';
    is $service->execute($two), 'queued', 'non supera la richiesta precedente anche se il worker la pesca prima';
    ok !defined $repo->get_execution($two)->{started_at}, 'attesa esclusa dal timeout';
    $t->get_ok("/executions/$two")->status_is(200)->content_like(qr/posizione 2/);
    $t->get_ok("/api/executions/$two")->status_is(200)->json_is('/queue_position' => 2);
    my $guard = $repo->claim_database_queue($repo->get_execution($one));
    ok $guard, 'primo job acquisisce lock senza scadenza temporale';
    ok $repo->mark_running($one);
    is $service->execute($two), 'queued', 'nessun errore validation_busy: attende';
    is $service->execute($other), 'completed', 'stessa procedura su altro database indipendente';
    $repo->mark_finished($one, status => 'completed', exit_code => 0);
    undef $guard;
    is $service->execute($two), 'completed', 'il successivo parte dopo il rilascio del lock';
    $t->app->minion->perform_jobs;
    is $repo->get_execution($two)->{status}, 'completed', 'job duplicato non riesegue una richiesta conclusa';
};

subtest 'database queue: annullamento, errori e worker interrotti non bloccano i successivi' => sub {
    local $ENV{MYSQL_HOST} = 'mysql.test';
    local $ENV{MYSQL_PORT} = 3306;
    my $one = $service->submit(test_database_a => {database => 'db_cancel', message => 'cancel'})->{id};
    my $two = $service->submit(test_database_b => {database => 'db_cancel', message => 'continue'})->{id};
    is $service->cancel($one), 'cancelled';
    is $service->execute($two), 'completed', 'richiesta annullata rimossa dalla coda';
    my $orphan = $service->submit(test_database_a => {database => 'db_orphan', message => 'interrupted'})->{id};
    ok $repo->mark_running($orphan), 'simula worker morto dopo il passaggio a running';
    my $next = $service->submit(test_database_b => {database => 'db_orphan', message => 'next'})->{id};
    is $service->execute($next), 'completed', 'assenza del lock permette recupero del job orfano';
    is $repo->get_execution($orphan)->{error_code}, 'worker_interrupted', 'nessun falso successo o riavvio di scritture parziali';
    is $service->execute($orphan), undef, 'job orfano non viene ripetuto automaticamente';
    my $changed = $service->submit(test_database_a => {database => 'db_changed', message => 'never'})->{id};
    local $ENV{MYSQL_HOST} = 'different.test';
    is $service->execute($changed), 'failed', 'configurazione cambiata non sposta silenziosamente la richiesta';
    is $repo->get_execution($changed)->{error_code}, 'queue_target_changed';
};

subtest 'Minion rinvia i job in attesa, poi procede senza errore di concorrenza' => sub {
    local $ENV{MYSQL_HOST} = 'mysql.test';
    local $ENV{MYSQL_PORT} = 3306;
    my $one = $service->submit(test_database_a => {database => 'db_minion', message => 'head'})->{id};
    my $two = $service->submit(test_database_b => {database => 'db_minion', message => 'tail'})->{id};
    my $guard = $repo->claim_database_queue($repo->get_execution($one));
    ok $repo->mark_running($one);
    $t->app->minion->perform_jobs;
    my $waiting = $repo->get_execution($two);
    is $waiting->{status}, 'queued';
    ok !defined $waiting->{started_at}, 'il tentativo Minion non avvia il timeout';
    my $job = $t->app->minion->job($waiting->{minion_job_id})->info;
    is $job->{state}, 'inactive', 'job riprogrammato invece di fallire';
    ok $job->{retries} > 0;
    $repo->mark_finished($one, status => 'completed', exit_code => 0);
    undef $guard;
    is $service->execute($two), 'completed';
};

subtest 'un errore di enqueue non lascia una testa di coda fantasma' => sub {
    local $ENV{MYSQL_HOST} = 'mysql.test';
    local $ENV{MYSQL_PORT} = 3306;
    {
        no warnings qw(redefine once);
        local *Minion::enqueue = sub { die "backend unavailable\n" };
        eval { $service->submit(test_database_a => {database => 'db_enqueue', message => 'fail'}) };
        ok(ScriptManager::Exception->caught($@, 'queue_enqueue_failed'));
    }
    my $next = $service->submit(test_database_b => {database => 'db_enqueue', message => 'next'})->{id};
    is $repo->get_execution($next)->{queue_position}, 1;
    is $service->execute($next), 'completed';
};

done_testing;
