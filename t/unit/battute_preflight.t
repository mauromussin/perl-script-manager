use Mojo::Base -strict, -signatures;
use Test::More;
use ScriptManager::Service::BattutePreflight;

{
    package PreflightRepo;
    use Mojo::Base -base, -signatures;
    has events => sub { [{execution_id => 'previous', metadata => {
        operation => 'validation_saving', units => 1000, seconds => 10}}] };
    sub battute_timing_events ($self, @args) { return $self->events }
}
{
    package PreflightContext;
    use Mojo::Base -base, -signatures;
    has repo => sub { PreflightRepo->new };
    has timeout_seconds => 3600;
    has timeout_bypassed => 0;
    has elapsed_seconds => 0;
    has execution_id => 'current';
    has logs => sub { [] };
    sub check_cancel ($self) { }
    sub log ($self, @args) { push @{$self->logs}, \@args }
    sub progress ($self, @args) { }
}
{
    package PreflightWindow;
    use Mojo::Base -base, -signatures;
    has days => sub { ['2026-09-01'] };
    has target => 'mysql.test:3306:radar';
}
{
    package PreflightDB;
    use Mojo::Base -base, -signatures;
    has reads => 0;
    sub selectall_arrayref ($self, $sql, $attr, @bind) {
        $self->reads($self->reads + 1);
        Test::More::like($sql, qr/SELECT row_id FROM flay WHERE validation_bt IS NULL/);
        Test::More::is_deeply(\@bind, ['2026-09-01'], 'stesso scope e placeholder della selezione reale');
        return [[1, 8], [2, 8], [3, 1000], [4, 2000]];
    }
}

subtest 'storico legacy e misure strutturate: velocita piu prudenziale' => sub {
    my $events = [
        {execution_id => 'a', time => 100, message => 'Salvataggio: classificazioni delle battute e delle tracce: 50%'},
        {execution_id => 'a', time => 120, message => 'Salvataggio: traccia 7 (100 di 300 operazioni): 66%'},
        {execution_id => 'b', time => 500, message => 'Salvataggio: traccia 8 (200 di 400 operazioni): 74%'},
        {execution_id => 'b', time => 550, message => 'Salvataggio: 300 di 400 operazioni: 87%'},
    ];
    is(ScriptManager::Service::BattutePreflight->saving_rate($events), 0.5);
    push @$events, {metadata => {operation => 'validation_saving', units => 1000, seconds => 750}};
    is(ScriptManager::Service::BattutePreflight->saving_rate($events), 0.75);
    is(ScriptManager::Service::BattutePreflight->saving_rate([]), undef);
};

subtest 'soglia esatta inclusiva e ricontrollo prima delle scritture' => sub {
    my $ctx = PreflightContext->new(timeout_seconds => 100, elapsed_seconds => 10);
    my $check = ScriptManager::Service::BattutePreflight->new(seconds_per_operation => 1);
    is $check->check_saving($ctx, 45), 100, '100 secondi stimati ammessi per timeout 100';
    eval { $check->check_saving($ctx, 46) };
    ok(ScriptManager::Exception->caught($@, 'timeout_estimate'), '102 secondi rifiutati');
    like "$@", qr/ridurre l intervallo/;
    $ctx->timeout_bypassed(1);
    is $check->check_saving($ctx, 46), 102, 'conferma permette anche il ricontrollo oltre soglia';
    ok scalar(grep { $_->[0] eq 'warning' && $_->[1] =~ /conferma utente/ } @{$ctx->logs}),
        'bypass della stima segnalato esplicitamente';
};

subtest 'campiona operazioni e dimensioni differenti, nessuna scrittura radar' => sub {
    my $ctx = PreflightContext->new;
    my $db = PreflightDB->new;
    my @sampled;
    my $check = ScriptManager::Service::BattutePreflight->new;
    my $seconds = $check->check($db, $ctx, PreflightWindow->new,
        [[1, 'A'], [2, 'D'], [3, 'A'], [4, 'A']], 'validation_bt IS NULL', ['2026-09-01'],
        sub ($track) {
            push @sampled, $track->[0];
            return {updates => {Y => [1 .. ($track->[0] == 4 ? 1000 : 8)]}};
        });
    ok $seconds > 0;
    is_deeply [sort {$a <=> $b} @sampled], [1, 2, 3, 4], 'include A/D e tracce con molte battute';
    is $db->reads, 1, 'un solo conteggio aggregato in sola lettura';
    $ctx->timeout_seconds(0.001);
    eval { $check->check_saving($ctx, 10) };
    ok(ScriptManager::Exception->caught($@, 'timeout_estimate'), 'rifiuta prima del salvataggio');
};

subtest 'assenza storico blocca; intero intervallo gia saltato non richiede stima' => sub {
    my $ctx = PreflightContext->new(repo => PreflightRepo->new(events => []), timeout_bypassed => 1);
    my $db = PreflightDB->new;
    my $check = ScriptManager::Service::BattutePreflight->new;
    eval { $check->check($db, $ctx, PreflightWindow->new, [], '', [], sub { die 'not called' }) };
    ok(ScriptManager::Exception->caught($@, 'timeout_estimate_unavailable'), 'conferma non inventa uno storico mancante');
    is $db->reads, 0, 'non tenta di stimare o scrivere con valori inventati';
    $check->check($db, $ctx, PreflightWindow->new(days => []), [], '', [], sub { die 'not called' });
    is $db->reads, 0, 'skip non esegue lavoro o richiede calibrazione';
};

done_testing;
