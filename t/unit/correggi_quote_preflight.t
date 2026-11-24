use Mojo::Base -strict, -signatures;
use Test::More;
use ScriptManager::Exception;
use ScriptManager::Service::CorreggiQuotePreflight;

{
    package QuotePreflightRepo;
    use Mojo::Base -base, -signatures;
    has events => sub { [] };
    has query => sub { [] };
    sub validation_timing_events ($self, @args) {
        $self->query(\@args);
        return $self->events;
    }
}

{
    package QuotePreflightContext;
    use Mojo::Base -base, -signatures;
    has repo => sub { QuotePreflightRepo->new };
    has execution_id => 'current';
    has timeout_seconds => 3600;
    has timeout_bypassed => 0;
    has elapsed_seconds => 10;
    has logs => sub { [] };
    sub log ($self, @args) { push @{$self->logs}, \@args }
}

subtest 'senza storico blocca le scritture e rende disponibile la conferma' => sub {
    my $ctx = QuotePreflightContext->new;
    my $preflight = ScriptManager::Service::CorreggiQuotePreflight->new;
    eval { $preflight->check_saving($ctx, 'mysql.test:3306:radar', 100) };
    ok(ScriptManager::Exception->caught($@, 'timeout_estimate_unavailable'));
    is_deeply $ctx->repo->query, [
        'mysql.test:3306:radar', 'current', 'correggi_quote', 'correggi_quote_batch_saving_v1'];

    $ctx->timeout_bypassed(1);
    is $preflight->check_saving($ctx, 'mysql.test:3306:radar', 100), undef;
    ok(scalar grep { $_->[0] eq 'warning' && $_->[1] =~ /durata sconosciuta/ } @{$ctx->logs});
};

subtest 'usa solo misure strutturate dei salvataggi a lotti e stima prima delle scritture' => sub {
    my $ctx = QuotePreflightContext->new(repo => QuotePreflightRepo->new(events => [
        {metadata => {operation => 'correggi_quote_batch_saving_v1', units => 100, seconds => 20}},
        {metadata => {operation => 'correggi_quote_batch_saving_v1', units => 200, seconds => 30}},
        {metadata => {operation => 'legacy_per_row', units => 1_000_000, seconds => 1}},
    ]));
    my $preflight = ScriptManager::Service::CorreggiQuotePreflight->new;
    is $preflight->check_saving($ctx, 'mysql.test:3306:radar', 100), 50,
        'usa la misura piu prudenziale: 10 secondi per operazione, margine 2x e tempo gia trascorso';
    is $preflight->seconds_per_operation, 0.2;

    $ctx->timeout_seconds(49);
    eval { $preflight->check_saving($ctx, 'mysql.test:3306:radar', 100) };
    ok(ScriptManager::Exception->caught($@, 'timeout_estimate'));
    $ctx->timeout_bypassed(1);
    is $preflight->check_saving($ctx, 'mysql.test:3306:radar', 100), 50;
};

subtest 'nessuna stima se non sono previste scritture' => sub {
    my $ctx = QuotePreflightContext->new;
    is(ScriptManager::Service::CorreggiQuotePreflight->new
        ->check_saving($ctx, 'mysql.test:3306:radar', 0), undef);
    is_deeply $ctx->repo->query, [];
};

done_testing;
