use Mojo::Base -strict, -signatures;
use Test::More;
use ScriptManager::Service::Dashboard;

{
    package DashboardRepository;
    use Mojo::Base -base, -signatures;
    has databases => sub { ['radar'] };
    has executions => sub { [] };
    sub dashboard_databases ($self) { return $self->databases }
    sub dashboard_executions ($self, $database) { return $self->executions }
}
{
    package DashboardLogger;
    use Mojo::Base -base, -signatures;
    has warnings => sub { [] };
    sub warn ($self, $message) { push @{$self->warnings}, $message }
}

my $procedures = [
    {code => 'height', name => '08-quote', parameter_schema => {properties => {database => {}}}},
    {code => 'tracks', name => '03-tracce', parameter_schema => {properties => {database => {}}}},
    {code => 'other', name => 'senza database', parameter_schema => {properties => {}}},
];
sub execution ($id, $code, $status, $from = undef, $to = undef) {
    return {id => $id, procedure_code => $code, procedure_name => $code, status => $status,
        date_from => $from, date_to => $to, finished_date => '24/11/2026'};
}

subtest 'mesi dei dati, ultima richiesta e intervalli a cavallo anno' => sub {
    my $repo = DashboardRepository->new(executions => [
        execution('latest', 'tracks', 'failed', '2026-02-10', '2026-02-11'),
        execution('older', 'tracks', 'completed', '2025-12-15', '2026-03-01'),
    ]);
    my $service = ScriptManager::Service::Dashboard->new(repo => $repo);
    my $data = $service->load($procedures, 'radar', 2026);
    is $data->{cells}{tracks}{1}{id}, 'older', 'richiesta multianno comprende gennaio';
    is $data->{cells}{tracks}{2}{id}, 'latest', 'ultima richiesta anche per sottointervallo';
    is $data->{cells}{tracks}{2}{tone}, 'failure';
    is $data->{cells}{tracks}{3}{id}, 'older', 'estremo finale incluso';
    ok !exists $data->{cells}{tracks}{4}, 'mesi non compresi restano vuoti';
    is_deeply $data->{years}, [2026, 2025], 'anni derivati dai dati, non dal completamento';
    is_deeply [map { $_->{code} } @{$data->{procedures}}], ['tracks', 'height'];
    $data = $service->load($procedures, 'radar', 2025);
    is $data->{cells}{tracks}{12}{id}, 'older';
    ok !exists $data->{cells}{tracks}{11};
};

subtest 'stati attivi grigi, timeout giallo, annullate rosse' => sub {
    my $repo = DashboardRepository->new;
    my $service = ScriptManager::Service::Dashboard->new(repo => $repo);
    for my $case ([queued => 'active'], [running => 'active'], [cancel_requested => 'active'],
        [timed_out => 'timeout'], [cancelled => 'failure'], [completed => 'success']) {
        $repo->executions([execution('one', 'tracks', $case->[0], '2026-01-01', '2026-01-31')]);
        is $service->load($procedures)->{cells}{tracks}{1}{tone}, $case->[1], $case->[0];
    }
};

subtest 'date mancanti o malformate separate con warning, mai mesi inventati' => sub {
    my $repo = DashboardRepository->new(executions => [
        execution('missing', 'tracks', 'running'),
        execution('partial', 'tracks', 'failed', '2026-01-01'),
        execution('invalid', 'height', 'completed', '2026-02-30', '2026-03-01'),
        execution('reverse', 'height', 'failed', '2026-04-02', '2026-04-01'),
    ]);
    my $logger = DashboardLogger->new;
    my $data = ScriptManager::Service::Dashboard->new(repo => $repo, logger => $logger)
        ->load($procedures, 'radar', 2026);
    is_deeply $data->{cells}, {}, 'nessun mese attribuito a esecuzioni senza intervallo valido';
    is scalar @{$data->{unknown}}, 2, 'riepilogo separato per procedura';
    is $data->{unknown}[0]{execution}{id}, 'missing', 'mostra ultima richiesta senza date';
    is $data->{unknown}[0]{count}, 2, 'conteggia anche quelle precedenti';
    like $data->{warnings}[0], qr/4 esecuzioni/;
    like $logger->warnings->[0], qr/Cruscotto database radar: 4 esecuzioni/;
};

subtest 'filtri non validi espliciti e storico vuoto' => sub {
    my $repo = DashboardRepository->new(executions => [
        execution('one', 'tracks', 'completed', '2026-01-01', '2026-01-31')]);
    my $service = ScriptManager::Service::Dashboard->new(repo => $repo);
    for my $args (['unknown', 2026], ['radar', 'bad'], ['radar', 2025]) {
        eval { $service->load($procedures, @$args) };
        ok(ScriptManager::Exception->caught($@, 'invalid_dashboard_filter'));
    }
    $repo->databases([]);
    my $data = $service->load($procedures);
    is_deeply $data->{databases}, [];
    is_deeply $data->{cells}, {};
    is_deeply $data->{unknown}, [];
};

done_testing;
