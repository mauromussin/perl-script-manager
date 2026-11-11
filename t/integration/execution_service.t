use Mojo::Base -strict;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper;

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

done_testing;
