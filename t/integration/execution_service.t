use Mojo::Base -strict;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper;
use File::Temp 'tempdir';
use Mojo::File 'path';
use ScriptManager::Command::CaricaDB;
use ScriptManager::Command::CorreggiQuote;

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
    ok !$app->repo->get_execution($id)->{timeout_bypassed}, 'migrazione mantiene il timeout delle vecchie richieste';
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

subtest 'riconciliazione Minion: orfani, processi vivi, concorrenza e vecchie esecuzioni' => sub {
    my $app = TestHelper::mojo()->app;
    my $monitor = $app->execution_service;
    my $repository = $app->repo;
    my $minion = $app->minion;
    my $worker = $minion->worker->register;
    my $start = sub {
        my $id = $monitor->submit(test_async => {message => 'monitor-test'})->{id};
        my $exec = $repository->get_execution($id);
        my $job = $worker->dequeue(0 => {id => $exec->{minion_job_id}});
        die "Job di test non acquisito\n" unless $job;
        $repository->mark_running($id);
        return ($id, $job);
    };

    my ($dead, $dead_job) = $start->();
    $repository->update_progress($dead, 73, 'Salvataggio interrotto');
    $dead_job->fail('Worker went away');
    is $monitor->reconcile_interrupted(1), 1, 'job gia fallito: corregge anche record senza queue_target';
    my $failed = $repository->get_execution($dead);
    is $failed->{status}, 'failed';
    is $failed->{error_code}, 'worker_interrupted';
    is $failed->{progress}, 73, 'non inventa un completamento';
    ok defined $failed->{finished_at};
    like $failed->{error_message}, qr/scritture parziali/;
    is $repository->list_events($dead)->[-1]{metadata}{minion_state}, 'failed';
    my $events = scalar @{$repository->list_events($dead)};
    is $monitor->reconcile_interrupted(1), 0, 'controllo idempotente';
    is scalar @{$repository->list_events($dead)}, $events, 'nessun evento duplicato';

    my ($live, $live_job) = $start->();
    $repository->pg->db->query(q{
        update executions set started_at = now() - interval '2 days' where id = ?
    }, $live);
    is $monitor->reconcile_interrupted(1), 0, 'nessun limite basato su durata o ultimo log';
    is $repository->get_execution($live)->{status}, 'running', 'job attivo conservato anche senza nuovo lock';

    my ($protected, $protected_job) = $start->();
    my $guard = $repository->lock_execution($protected);
    $protected_job->fail('Worker missing but command still alive');
    is $monitor->reconcile_interrupted(1), 0, 'lock vivo prevale anche sullo stato Minion';
    is $repository->get_execution($protected)->{status}, 'running';
    undef $guard;
    is $monitor->reconcile_interrupted(1), 1, 'diventa fallito solo dopo rilascio del lock';

    my $missing = $monitor->submit(test_async => {message => 'missing-job'})->{id};
    $minion->job($repository->get_execution($missing)->{minion_job_id})->remove;
    $repository->mark_running($missing);
    is $monitor->reconcile_interrupted(1), 1, 'job eliminato dal backend riconosciuto';
    is $repository->list_events($missing)->[-1]{metadata}{minion_state}, 'missing';

    my ($cancelled, $cancel_job) = $start->();
    $repository->request_cancel($cancelled);
    $cancel_job->fail('Worker went away');
    is $monitor->reconcile_interrupted(1), 1, 'recupera anche cancel_requested rimasti appesi';
    is $repository->get_execution($cancelled)->{status}, 'failed', 'non dichiara annullate scritture parziali';

    my ($unfinished, $finished_job) = $start->();
    $finished_job->finish;
    is $monitor->reconcile_interrupted(1), 1, 'job concluso senza stato finale applicativo riconosciuto';
    is $repository->get_execution($unfinished)->{status}, 'failed', 'nessun successo inventato dal monitor';

    $repository->pg->db->query(q{
        update minion_workers set notified = now() - (? * interval '1 second') where id = ?
    }, $minion->missing_after + 1, $worker->id);
    is $monitor->reconcile_interrupted(1), 1, 'riparazione Minion rileva worker senza heartbeat oltre missing_after';
    is $repository->get_execution($live)->{status}, 'failed';
    is $repository->mark_interrupted($dead, $dead_job->id, 'failed'), 0, 'nessuna riscrittura di record finali';

    my $queued = $monitor->submit(test_async => {message => 'still-queued'})->{id};
    is $monitor->reconcile_interrupted(1), 0;
    is $repository->get_execution($queued)->{status}, 'queued', 'nessun errore per richieste in attesa';

    {
        no warnings qw(redefine once);
        local *ScriptManager::Command::Example::run = sub {
            my (undef, $ctx) = @_;
            ok !$repository->lock_execution($ctx->execution_id), 'execute mantiene il lock fino al termine';
            is $monitor->reconcile_interrupted(1), 0, 'esecuzione diretta protetta anche con job Minion inattivo';
            is $repository->get_execution($ctx->execution_id)->{status}, 'running';
            return {success => 1, message => 'protected'};
        };
        is $monitor->execute($queued), 'completed';
    }
};

subtest '04: conferma oltre stima disattiva il timeout reale solo per la nuova richiesta in coda' => sub {
    local $ENV{MYSQL_HOST} = 'mysql.test';
    local $ENV{MYSQL_PORT} = 3306;
    my $app = TestHelper::mojo()->app;
    my $svc = $app->execution_service;
    my $repository = $app->repo;
    my $input = {database => 'timeout_test', date_from => '2026-09-01', date_to => '2026-09-30',
        overwrite => Mojo::JSON::true};
    my $cancel_run = 0;
    no warnings qw(redefine once);
    local *ScriptManager::Command::ValidaBattute::run = sub {
        my (undef, $ctx) = @_;
        ScriptManager::Service::BattutePreflight->new(seconds_per_operation => 1)->check_saving($ctx, 2);
        Time::HiRes::sleep(1.2);
        $repository->request_cancel($ctx->execution_id) if $cancel_run;
        $ctx->check_cancel;
        return {success => 1, message => 'oltre il timeout configurato'};
    };
    my $source = $svc->submit(valida_battute => $input)->{id};
    is $svc->execute($source), 'failed', 'richiesta normale rifiutata dalla stima';
    is $repository->get_execution($source)->{error_code}, 'timeout_estimate';
    ok $svc->can_bypass_timeout($repository->get_execution($source));
    my $head = $svc->submit(valida_battute => $input)->{id};
    my $retry = $svc->submit(valida_battute => {database => 'tampered'},
        timeout_bypass_from => $source, requested_by => 'confirmed-user')->{id};
    my $exec = $repository->get_execution($retry);
    isnt $retry, $source, 'nuovo record, non modifica la richiesta rifiutata';
    is_deeply $exec->{parameters}, $repository->get_execution($source)->{parameters},
        'copia solo i parametri originali, non input modificati';
    ok $exec->{timeout_bypassed}, 'scelta persistita fuori dai parametri del comando';
    is $exec->{queue_position}, 2, 'nessun salto della coda';
    is $svc->execute($retry), 'queued';
    is $svc->cancel($head), 'cancelled';
    my $started = Time::HiRes::time();
    is $svc->execute($retry), 'completed';
    cmp_ok Time::HiRes::time() - $started, '>=', 1, 'termina oltre il vero timeout di un secondo';
    my ($audit) = grep { ($_->{metadata}{operation} // '') eq 'timeout_bypass' }
        @{$repository->list_events($retry)};
    is $audit->{metadata}{source_execution_id}, $source, 'conferma tracciata con origine';
    is $repository->get_execution($retry)->{requested_by}, 'confirmed-user';
    my $normal = $svc->submit(valida_battute => $exec->{parameters},
        confirm_completed_execution => $retry)->{id};
    ok !$repository->get_execution($normal)->{timeout_bypassed}, 'un normale Riesegui non eredita il bypass';
    is $svc->execute($normal), 'failed', 'il controllo della stima resta attivo nelle richieste ordinarie';
    $cancel_run = 1;
    my $cancelled = $svc->submit(valida_battute => {}, timeout_bypass_from => $source,
        confirm_completed_execution => $retry)->{id};
    is $svc->execute($cancelled), 'cancelled', 'bypass non disattiva la cancellazione cooperativa';
    eval { $svc->submit(test_async => {}, timeout_bypass_from => $source) };
    ok(ScriptManager::Exception->caught($@, 'timeout_bypass_not_allowed'), 'bypass non esteso ad altre procedure');
    $repository->mark_finished($source, status => 'failed', error_code => 'timeout_estimate_unavailable');
    ok $svc->can_bypass_timeout($repository->get_execution($source)), 'override disponibile senza storico';
    $cancel_run = 0;
    my $uncalibrated = $svc->submit(valida_battute => {}, timeout_bypass_from => $source,
        confirm_completed_execution => $retry)->{id};
    ok $repository->get_execution($uncalibrated)->{timeout_bypassed}, 'conferma persistita senza storico';
    is $svc->execute($uncalibrated), 'completed', 'riesecuzione confermata supera il timeout reale';
};

subtest '08: conferma senza storico elimina timeout reale, non la cancellazione' => sub {
    local $ENV{MYSQL_HOST} = 'mysql.test';
    my $app = TestHelper::mojo()->app;
    my $svc = $app->execution_service;
    my $repository = $app->repo;
    my $source = $svc->submit(rettifica_quote => {database => 'height_timeout'})->{id};
    $repository->mark_finished($source, status => 'failed', exit_code => 1,
        error_code => 'timeout_estimate_unavailable');
    my $id = $svc->submit(rettifica_quote => {}, timeout_bypass_from => $source)->{id};
    my $cancel_run = 0;
    no warnings qw(redefine once);
    local *ScriptManager::Command::RettificaQuote::run = sub {
        my (undef, $ctx) = @_;
        ok $ctx->timeout_bypassed, 'bypass nel contesto della sola 08 confermata';
        Time::HiRes::sleep(1.2);
        $repository->request_cancel($ctx->execution_id) if $cancel_run;
        $ctx->check_cancel;
        return {success => 1, message => '08 completata'};
    };
    is $svc->execute($id), 'completed', 'supera il timeout configurato di 1 secondo';
    my ($audit) = grep { ($_->{metadata}{operation} // '') eq 'timeout_bypass' } @{$repository->list_events($id)};
    is $audit->{metadata}{source_execution_id}, $source, 'conferma tracciata';
    my $head = $svc->submit(rettifica_quote => {database => 'height_timeout'},
        confirm_completed_execution => $id)->{id};
    my $retry = $svc->submit(rettifica_quote => {}, timeout_bypass_from => $source,
        confirm_completed_execution => $id)->{id};
    is $svc->execute($retry), 'queued', 'conferma rispetta la coda FIFO';
    is $svc->cancel($head), 'cancelled';
    $cancel_run = 1;
    is $svc->execute($retry), 'cancelled', 'bypass non disattiva la cancellazione';
};

subtest '02: conferma preventiva limita il bypass alla richiesta' => sub {
    local $ENV{MYSQL_HOST} = 'mysql.test';
    local $ENV{MYSQL_PORT} = 3306;
    my $app = TestHelper::mojo()->app;
    my $svc = $app->execution_service;
    my $repository = $app->repo;
    my $input = {database => 'radar_initial', folder => 'BGY_2026', radar => 'lin_2026',
        merge_midnight => Mojo::JSON::false};
    my $cancel_run = 0;
    no warnings qw(redefine once);
    local *ScriptManager::Command::Example::run = sub {
        my (undef, $ctx) = @_;
        Time::HiRes::sleep(1.2);
        $repository->request_cancel($ctx->execution_id) if $cancel_run;
        $ctx->check_cancel;
        return {success => 1, message => '02 completata'};
    };
    my $head = $svc->submit(carica_db => $input)->{id};
    my $id = $svc->submit(carica_db => $input, timeout_bypass_confirmed => 1,
        requested_by => 'confirmed-user')->{id};
    my $execution = $repository->get_execution($id);
    ok $execution->{timeout_bypassed}, 'scelta persistita sulla richiesta confermata';
    is $execution->{queue_position}, 2, 'rimane nella coda del database';
    is_deeply $execution->{parameters}, $repository->get_execution($head)->{parameters},
        'conferma separata dai parametri del comando';
    is $execution->{requested_by}, 'confirmed-user';
    my ($audit) = grep { ($_->{metadata}{operation} // '') eq 'timeout_bypass' }
        @{$repository->list_events($id)};
    is $audit->{metadata}{source}, 'initial_confirmation', 'conferma preventiva registrata';
    ok !exists $audit->{metadata}{source_execution_id}, 'nessuna esecuzione precedente inventata';
    is $svc->execute($id), 'queued', 'non supera la coda';
    is $svc->cancel($head), 'cancelled';
    is $svc->execute($id), 'completed', 'supera il timeout configurato';
    my $normal = $svc->submit(carica_db => $input, confirm_completed_execution => $id)->{id};
    ok !$repository->get_execution($normal)->{timeout_bypassed}, 'timeout normale ancora attivo';
    is $svc->execute($normal), 'timed_out';
    $cancel_run = 1;
    my $cancelled = $svc->submit(carica_db => $input, timeout_bypass_confirmed => 1,
        confirm_completed_execution => $id)->{id};
    is $svc->execute($cancelled), 'cancelled', 'cancellazione ancora attiva';
    for my $case ([test_async => 1], [carica_db => 0]) {
        eval { $svc->submit($case->[0] => $input, timeout_bypass_confirmed => $case->[1]) };
        ok(ScriptManager::Exception->caught($@, 'timeout_bypass_not_allowed'), 'conferma non valida rifiutata');
    }
    eval { $svc->submit(carica_db => $input, timeout_bypass_confirmed => 1, timeout_bypass_from => $normal) };
    ok(ScriptManager::Exception->caught($@, 'timeout_bypass_not_allowed'),
        'conferma preventiva non aggira i controlli sulla riesecuzione');
};

subtest '02: bypass dopo timeout, con stessi parametri e coda' => sub {
    local $ENV{MYSQL_HOST} = 'mysql.test';
    local $ENV{MYSQL_PORT} = 3306;
    my $app = TestHelper::mojo()->app;
    my $svc = $app->execution_service;
    my $repository = $app->repo;
    my $input = {database => 'radar_timeout', folder => 'BGY_2026', radar => 'lin_2026',
        merge_midnight => Mojo::JSON::false};
    my $cancel_run = 0;
    no warnings qw(redefine once);
    local *ScriptManager::Command::Example::run = sub {
        my (undef, $ctx) = @_;
        Time::HiRes::sleep(1.2);
        $repository->request_cancel($ctx->execution_id) if $cancel_run;
        $ctx->check_cancel;
        return {success => 1, message => '02 completata'};
    };
    my $source = $svc->submit(carica_db => $input)->{id};
    is $svc->execute($source), 'timed_out', 'il timeout ordinario resta attivo';
    my $original = $repository->get_execution($source);
    ok $svc->can_bypass_timeout($original), 'conferma disponibile dopo timeout reale';
    my $head = $svc->submit(carica_db => $input)->{id};
    my $retry = $svc->submit(carica_db => {database => 'tampered'}, timeout_bypass_from => $source,
        requested_by => 'confirmed-user')->{id};
    my $execution = $repository->get_execution($retry);
    is_deeply $execution->{parameters}, $original->{parameters}, 'parametri originali preservati';
    is $execution->{queue_target}, $original->{queue_target}, 'stesso target';
    is $execution->{queue_position}, 2, 'nessun salto della coda';
    ok $execution->{timeout_bypassed}, 'bypass persistito';
    is $svc->execute($retry), 'queued', 'il bypass non aggira la coda';
    is $svc->cancel($head), 'cancelled';
    is $svc->execute($retry), 'completed', 'la richiesta confermata supera il timeout';
    my ($audit) = grep { ($_->{metadata}{operation} // '') eq 'timeout_bypass' }
        @{$repository->list_events($retry)};
    is $audit->{metadata}{source_execution_id}, $source, 'origine registrata';
    is $execution->{requested_by}, 'confirmed-user', 'utente registrato';
    unlike $audit->{message}, qr/stima/, 'nessun riferimento alla stima assente nella 02';
    my $normal = $svc->submit(carica_db => $input, confirm_completed_execution => $retry)->{id};
    ok !$repository->get_execution($normal)->{timeout_bypassed}, 'riesecuzione normale non eredita il bypass';
    is $svc->execute($normal), 'timed_out', 'timeout attivo sulle richieste ordinarie';
    $cancel_run = 1;
    my $cancelled = $svc->submit(carica_db => {}, timeout_bypass_from => $source,
        confirm_completed_execution => $retry)->{id};
    is $svc->execute($cancelled), 'cancelled', 'cancellazione ancora attiva';

    {
        local $ENV{MYSQL_HOST} = 'other.test';
        my $result = $svc->submit(carica_db => {}, timeout_bypass_from => $source);
        like $result->{errors}[0]{message}, qr/Target MySQL cambiato/, 'server cambiato rifiutato';
    }
    for my $case (
        ['failed', 'timeout_estimate'],
        ['failed', 'timeout_estimate_unavailable'],
        ['failed', 'mysql_recovery_required'],
        ['failed', 'mysql_already_published'],
        ['failed', 'timed_out'],
        ['timed_out', 'mysql_recovery_required'],
    ) {
        $repository->mark_finished($source, status => $case->[0], error_code => $case->[1]);
        ok !$svc->can_bypass_timeout($repository->get_execution($source)),
            "bypass rifiutato per $case->[0]/$case->[1]";
        eval { $svc->submit(carica_db => {}, timeout_bypass_from => $source) };
        ok(ScriptManager::Exception->caught($@, 'timeout_bypass_not_allowed'), 'invio rifiutato');
    }
    for my $operation (qw(commit commit_complete rollback_failed myisam_publish_complete)) {
        my $old = $svc->submit(carica_db => $input, confirm_completed_execution => $retry)->{id};
        $repository->add_event($old, 'warning', 'test evento precedente', metadata => {operation => $operation});
        $repository->mark_finished($old, status => 'timed_out', error_code => 'timed_out');
        ok !$svc->can_bypass_timeout($repository->get_execution($old)),
            "bypass rifiutato per timeout storico con evento $operation";
        eval { $svc->submit(carica_db => {}, timeout_bypass_from => $old) };
        ok(ScriptManager::Exception->caught($@, 'timeout_bypass_not_allowed'), 'invio rifiutato');
    }
};

subtest '10: conferma puo riprendere una normalizzazione terminata per timeout' => sub {
    local $ENV{MYSQL_HOST} = 'mysql.test';
    my $app = TestHelper::mojo()->app;
    my $svc = $app->execution_service;
    my $repository = $app->repo;
    my $source = $svc->submit(correggi_quote => {database => 'quote_timeout'})->{id};
    $repository->mark_finished($source, status => 'timed_out', exit_code => 1,
        error_code => 'timed_out', error_message => 'Timeout 10');
    ok $svc->can_bypass_timeout($repository->get_execution($source)),
        'la 10 scaduta espone una conferma esplicita';

    my $retry = $svc->submit(correggi_quote => {}, timeout_bypass_from => $source)->{id};
    no warnings qw(redefine once);
    local *ScriptManager::Command::CorreggiQuote::run = sub {
        my (undef, $ctx) = @_;
        ok $ctx->timeout_bypassed, 'bypass limitato alla nuova esecuzione confermata';
        Time::HiRes::sleep(1.2);
        return {success => 1, message => '10 completata'};
    };
    is $svc->execute($retry), 'completed', 'la 10 supera il timeout configurato';
    my ($audit) = grep { ($_->{metadata}{operation} // '') eq 'timeout_bypass' }
        @{$repository->list_events($retry)};
    is $audit->{metadata}{source_execution_id}, $source, 'conferma tracciata con origine';

    my $estimate = $svc->submit(correggi_quote => {database => 'quote_timeout'},
        confirm_completed_execution => $retry)->{id};
    $repository->mark_finished($estimate, status => 'failed', exit_code => 1,
        error_code => 'timeout_estimate_unavailable');
    ok $svc->can_bypass_timeout($repository->get_execution($estimate)),
        'anche una stima non disponibile offre l override';
};

subtest 'controlli automatici nel worker e nella consultazione web/API' => sub {
    my $web = TestHelper::mojo();
    my $app = $web->app;
    my $monitor = $app->execution_service;
    my $repository = $app->repo;
    my $worker = $app->minion->worker->register;
    my $make_orphan = sub {
        my $id = $monitor->submit(test_async => {message => 'automatic-monitor'})->{id};
        my $job = $worker->dequeue(0 => {id => $repository->get_execution($id)->{minion_job_id}});
        die "Job di test non acquisito\n" unless $job;
        $repository->mark_running($id);
        die "Fallimento del job di test non registrato\n" unless $job->fail('Worker went away');
        return $id;
    };
    for my $event (qw(wait busy)) {
        my $id = $make_orphan->();
        $monitor->next_reconciliation(0);
        $app->minion->worker->emit($event);
        is $repository->get_execution($id)->{status}, 'failed', "controllo automatico su evento $event";
    }
    my $id = $make_orphan->();
    $monitor->next_reconciliation(0);
    $web->get_ok("/api/executions/$id")->status_is(200)
        ->json_is('/status' => 'failed')->json_is('/error_code' => 'worker_interrupted');
    $id = $make_orphan->();
    is $monitor->reconcile_interrupted, 0, 'controlli periodici limitati a uno ogni 30 secondi';
    is $repository->get_execution($id)->{status}, 'running';
    $monitor->next_reconciliation(0);
    $web->get_ok('/executions?status=failed')->status_is(200);
    is $repository->get_execution($id)->{status}, 'failed', 'anche lo storico aggiorna gli orfani';
    $worker->unregister;
};

done_testing;
