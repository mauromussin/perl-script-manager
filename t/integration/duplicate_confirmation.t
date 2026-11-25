use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper;
use Mojo::JSON qw(true false);
use File::Copy 'copy';
use File::Temp 'tempdir';
use Config;
use IPC::Open3 'open3';
use Mojo::File 'path';
use Symbol 'gensym';

plan skip_all => 'TEST_ONLINE non impostata' unless TestHelper::online();

my $t = TestHelper::mojo();
my $app = $t->app;
my $service = $app->execution_service;
my $repo = $app->repo;

my $first = $service->submit(test_sum => {a => '2', b => 3})->{id};
is $repo->get_execution($first)->{status}, 'completed', 'prima esecuzione completata';
my $before = scalar @{$repo->list_executions(limit => 100)};
my $duplicate = $service->submit(test_sum => {a => 2, b => '3'});
is $duplicate->{duplicate}{id}, $first, 'parametri equivalenti dopo validazione';
is scalar(@{$repo->list_executions(limit => 100)}), $before, 'nessuna richiesta creata senza conferma';
ok $service->submit(test_sum => {a => 2, b => 4})->{id}, 'parametri diversi ammessi';
my $failed = $repo->create_execution(procedure_code => 'test_sum', requested_by => 'test',
    parameters => {a => 50, b => 4});
$repo->mark_finished($failed, status => 'failed', error_code => 'command_failed');
ok $service->submit(test_sum => {a => 50, b => 4})->{id}, 'esecuzioni fallite non richiedono conferma';
ok $service->submit(test_sum => {a => 2, b => 4}, confirm_completed_execution => $first)->{errors},
    'conferma non valida per parametri modificati';
my $rerun = $service->submit(test_sum => {a => 2, b => 3}, confirm_completed_execution => $first);
is $repo->get_execution($rerun->{id})->{status}, 'completed', 'conferma esplicita autorizza riesecuzione';
ok scalar(grep { ($_->{metadata}{operation} // '') eq 'duplicate_confirmed'
    && $_->{metadata}{source_execution_id} eq $first } @{$repo->list_events($rerun->{id})}),
    'conferma e riferimento tracciati';

$t->get_ok('/procedures/test_sum')->status_is(200);
my $token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
$t->post_ok('/procedures/test_sum/run' => form => {csrf_token => $token, a => 2, b => 3})
    ->status_is(409)->content_like(qr/Conferma riesecuzione/)
    ->element_exists('input[name=confirm_duplicate][required]');
my $prior = $t->tx->res->dom->at('input[name=confirm_completed_execution]')->attr('value');
$token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
$t->post_ok('/procedures/test_sum/run' => form => {
    csrf_token => $token, a => 2, b => 3, confirm_completed_execution => $prior,
})->status_is(409, 'la sola presenza del riferimento non conferma');
$t->post_ok('/procedures/test_sum/run' => form => {
    csrf_token => $token, a => 2, b => 4, confirm_completed_execution => $prior, confirm_duplicate => 1,
})->status_is(422, 'parametri modificati non autorizzati');
$t->post_ok('/procedures/test_sum/run' => form => {
    csrf_token => $token, a => 2, b => 3, confirm_completed_execution => $prior, confirm_duplicate => 1,
})->status_is(302);

$t->post_ok('/api/procedures/test_sum/executions' => json => {a => 2, b => 3})
    ->status_is(409)->json_has('/duplicate/id');
my $api_prior = $t->tx->res->json->{duplicate}{id};
$t->post_ok('/api/procedures/test_sum/executions' =>
    {'X-Confirm-Completed-Execution' => $api_prior} => json => {a => 2, b => 3})
    ->status_is(201)->json_has('/id');
$t->post_ok('/api/procedures/test_sum/executions' =>
    {'X-Confirm-Completed-Execution' => $api_prior} => json => {a => 6, b => 7})
    ->status_is(422, 'API rifiuta conferma per richiesta diversa');

my $secret = $service->submit(test_secret => {token => 'first-secret'})->{id};
is $repo->get_execution($secret)->{status}, 'completed', 'esecuzione con parametro sensibile';
$t->get_ok('/procedures/test_secret');
$token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
$t->post_ok('/procedures/test_secret/run' => form => {csrf_token => $token, token => 'second-secret'})
    ->status_is(409)->content_like(qr/possibile/)->content_unlike(qr/second-secret|first-secret/)
    ->element_exists('input[type=password][name=token][required]');
my $secret_prior = $t->tx->res->dom->at('input[name=confirm_completed_execution]')->attr('value');
$token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
$t->post_ok('/procedures/test_secret/run' => form => {
    csrf_token => $token, token => 'second-secret', confirm_completed_execution => $secret_prior,
    confirm_duplicate => 1,
})->status_is(302);

local $ENV{MYSQL_HOST} = 'mysql.test';
local $ENV{MYSQL_PORT} = 3306;
my $one = $service->submit(test_database_a => {database => 'queue_test', message => 'same'})->{id};
my $two = $service->submit(test_database_a => {database => 'queue_test', message => 'same'})->{id};
is $service->execute($one), 'completed', 'prima esecuzione accodata completata';
is $service->execute($two), 'failed', 'seconda intercettata prima del comando';
my $second = $repo->get_execution($two);
is $second->{error_code}, 'duplicate_confirmation_required', 'motivo esplicito';
ok scalar(grep { ($_->{metadata}{operation} // '') eq 'duplicate_detected'
    && $_->{metadata}{source_execution_id} eq $one } @{$repo->list_events($two)}),
    'riferimento nel log del lavoro in coda';
$t->get_ok("/executions/$two")->status_is(200)->content_like(qr/mentre questa richiesta era in coda/)
    ->element_exists('input[name=confirm_duplicate][required]');
$token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
my $confirm_url = "/executions/$two/confirm-duplicate";
$t->post_ok($confirm_url => form => {confirm_duplicate => 1})->status_is(403, 'CSRF obbligatorio');
$t->post_ok($confirm_url => form => {csrf_token => $token})->status_is(422, 'conferma obbligatoria');
{
    local $ENV{MYSQL_HOST} = 'other.test';
    $t->post_ok($confirm_url => form => {csrf_token => $token, confirm_duplicate => 1})
        ->status_is(409, 'target modificato non autorizzato');
}
$t->post_ok($confirm_url => form => {csrf_token => $token, confirm_duplicate => 1})->status_is(302);
my ($queued_retry) = $t->tx->res->headers->location =~ m{/executions/([0-9a-f-]+)};
is $service->execute($queued_retry), 'completed', 'riesecuzione in coda confermata dalla pagina';
is_deeply $repo->get_execution($queued_retry)->{parameters}, $second->{parameters},
    'parametri della richiesta bloccata mantenuti';
my $different_target = $service->submit(test_database_a => {database => 'different_test', message => 'same'});
ok $different_target->{id}, 'altro database non considerato identico';
$service->cancel($different_target->{id});
{
    local $ENV{MYSQL_HOST} = 'other.test';
    my $different_server = $service->submit(test_database_a => {database => 'queue_test', message => 'same'});
    ok $different_server->{id}, 'altro server non considerato identico';
    $service->cancel($different_server->{id});
}

my $weather = {database => 'weather_test',
    date_from => '2025-01-01', date_to => '2025-01-02'};
my $recorded = $repo->create_execution(procedure_code => 'valida_battute', requested_by => 'test',
    queue_target => 'mysql.test:3306:weather_test', parameters => {%$weather, overwrite => false});
$repo->mark_finished($recorded, status => 'completed');
my $weather_duplicate = $service->submit(valida_battute => {%$weather, overwrite => true});
is $weather_duplicate->{duplicate}{id}, $recorded, 'scelta Sovrascrivi esclusa dal confronto';
my $weather_rerun = $service->submit(valida_battute => {%$weather, overwrite => true},
    confirm_completed_execution => $recorded);
ok $repo->get_execution($weather_rerun->{id})->{parameters}{overwrite},
    'la conferma mantiene la scelta di sovrascrittura';
$service->cancel($weather_rerun->{id});

my $timeout_source = $repo->create_execution(procedure_code => 'valida_battute', requested_by => 'test',
    queue_target => 'mysql.test:3306:weather_test', parameters => {%$weather, overwrite => false});
$repo->mark_finished($timeout_source, status => 'failed', error_code => 'timeout_estimate');
$t->get_ok("/executions/$timeout_source")->status_is(200);
$token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
my $timeout_url = "/executions/$timeout_source/retry-without-timeout";
$t->post_ok($timeout_url => form => {csrf_token => $token, confirm_timeout_bypass => 1})
    ->status_is(409)->element_exists('input[name=confirm_timeout_bypass][value="1"]');
my $timeout_prior = $t->tx->res->dom->at('input[name=confirm_completed_execution]')->attr('value');
$token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
$t->post_ok($timeout_url => form => {csrf_token => $token, confirm_timeout_bypass => 1,
    confirm_completed_execution => $timeout_prior, confirm_duplicate => 1})->status_is(302);
my ($timeout_id) = $t->tx->res->headers->location =~ m{/executions/([0-9a-f-]+)};
ok $repo->get_execution($timeout_id)->{timeout_bypassed}, 'conferme distinte preservate';
$service->cancel($timeout_id);

my $radar = {database => 'race_initial', radar => 'lin_2026', folder => '.'};
my $radar_first = $service->submit(carica_db => $radar)->{id};
my $radar_queued = $service->submit(carica_db => $radar, timeout_bypass_confirmed => 1)->{id};
$repo->mark_finished($radar_first, status => 'completed');
is $service->execute($radar_queued), 'failed', 'duplicato in coda con bypass iniziale fermato';
$t->get_ok("/executions/$radar_queued")->status_is(200);
$token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
$t->post_ok("/executions/$radar_queued/confirm-duplicate" => form =>
    {csrf_token => $token, confirm_duplicate => 1})->status_is(302);
my ($radar_retry) = $t->tx->res->headers->location =~ m{/executions/([0-9a-f-]+)};
ok $repo->get_execution($radar_retry)->{timeout_bypassed}, 'bypass preventivo mantenuto';
$service->cancel($radar_retry);

my $race_params = {database => 'race_timeout'};
my $race_source = $service->submit(valida_battute => $race_params)->{id};
$repo->mark_finished($race_source, status => 'failed', error_code => 'timeout_estimate');
my $race_first = $service->submit(valida_battute => $race_params)->{id};
my $race_queued = $service->submit(valida_battute => {}, timeout_bypass_from => $race_source)->{id};
$repo->mark_finished($race_first, status => 'completed');
is $service->execute($race_queued), 'failed', 'duplicato in coda con bypass da timeout fermato';
$t->get_ok("/executions/$race_queued")->status_is(200);
$token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
$t->post_ok("/executions/$race_queued/confirm-duplicate" => form =>
    {csrf_token => $token, confirm_duplicate => 1})->status_is(302);
my ($race_retry) = $t->tx->res->headers->location =~ m{/executions/([0-9a-f-]+)};
ok $repo->get_execution($race_retry)->{timeout_bypassed}, 'bypass da timeout mantenuto';
$service->cancel($race_retry);

subtest 'conferma CLI' => sub {
    my $home = path(tempdir(CLEANUP => 1));
    $home->child('config')->make_path;
    $home->child('migrations')->make_path;
    copy("$FindBin::Bin/../fixtures/procedures.yml", $home->child('config', 'procedures.yml')) or die $!;
    copy("$FindBin::Bin/../../migrations/script_manager.sql", $home->child('migrations', 'script_manager.sql')) or die $!;
    local $ENV{MOJO_HOME} = "$home";
    local $ENV{DATABASE_URL} = $ENV{TEST_ONLINE};
    local $ENV{SCRIPT_MANAGER_SECRET} = 'test-secret';
    local $ENV{SCRIPT_MANAGER_DATABASE_SCHEMA} = $app->config->{database}{schema};
    local $ENV{PERL5LIB} = join $Config{path_sep}, "$FindBin::Bin/../lib", ($ENV{PERL5LIB} // '');
    my $run = sub (@args) {
        my $err = gensym;
        my $pid = open3(undef, my $out, $err, $^X, "$FindBin::Bin/../../bin/procedure", @args);
        local $/;
        my $stdout = <$out> // '';
        my $stderr = <$err> // '';
        waitpid($pid, 0);
        return ($? >> 8, $stdout, $stderr);
    };
    my ($exit, $stdout, $stderr) = $run->(qw(run test_sum --a 31 --b 4));
    is $exit, 0, 'prima esecuzione CLI completata';
    diag $stderr if $exit;
    my ($id) = $stdout =~ /\A([0-9a-f-]{36})/;
    ok $id, 'identificatore restituito';
    return unless $id;
    ($exit, $stdout, $stderr) = $run->(qw(run test_sum --a 31 --b 4));
    is $exit, 2, 'CLI blocca senza conferma';
    like $stderr, qr/\Q$id\E/, 'CLI indica il riferimento';
    ($exit, $stdout, $stderr) = $run->(qw(run test_sum --a 31 --b 4), "--confirm-completed-execution=$id");
    is $exit, 0, 'CLI conferma esplicita con riferimento';
};

done_testing;
