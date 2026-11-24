use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use Mojo::URL;
use lib "$FindBin::Bin/../lib";
use TestHelper;

plan skip_all => 'TEST_ONLINE non impostata' unless TestHelper::online();

my $t = TestHelper::mojo();
my $repo = $t->app->repo;

sub add_execution ($database, $code, $status, $from, $to, $requested, $finished = undef) {
    my %params = defined $database ? (database => $database) : ();
    $params{date_from} = $from if defined $from;
    $params{date_to} = $to if defined $to;
    my $id = $repo->create_execution(
        procedure_code => $code, requested_by => 'dashboard-test', parameters => \%params);
    $repo->pg->db->query(
        'update executions set status = ?, requested_at = ?::timestamptz, finished_at = ?::timestamptz where id = ?',
        $status, $requested, $finished, $id);
    return $id;
}

$t->get_ok('/')->status_is(200)->element_exists('nav a[href="/cruscotto"]');
$t->get_ok('/cruscotto')->status_is(200)->content_like(qr/Nessun database/);
subtest 'accesso al cruscotto controlla i worker interrotti' => sub {
    my $checks = 0;
    no warnings qw(redefine once);
    local *ScriptManager::Service::ExecutionService::reconcile_interrupted = sub { $checks++ };
    $t->get_ok('/cruscotto')->status_is(200);
    is $checks, 1, 'riconcilia prima di mostrare gli stati';
};

my $old = add_execution('radar_a', 'valida_battute', 'completed', '2025-12-01', '2026-03-31',
    '2026-11-01T10:00:00Z', '2026-11-01T12:00:00Z');
my $failed = add_execution('radar_a', 'valida_battute', 'failed', '2026-02-01', '2026-02-28',
    '2026-11-02T10:00:00Z', '2026-11-02T12:00:00Z');
my $timeout = add_execution('radar_a', 'rettifica_quote', 'timed_out', '2026-03-01', '2026-03-31',
    '2026-11-03T10:00:00Z', '2026-11-23T23:30:00Z');
my $queued = add_execution('radar_a', 'valida_battute', 'queued', '2026-04-01', '2026-04-30',
    '2026-11-04T10:00:00Z');
my $running = add_execution('radar_a', 'valida_battute', 'running', '2026-05-01', '2026-05-31',
    '2026-11-05T10:00:00Z');
my $missing = add_execution('radar_a', 'rettifica_quote', 'completed', undef, undef,
    '2026-11-06T10:00:00Z', '2026-11-06T12:00:00Z');
my $other = add_execution('radar_b', 'valida_battute', 'completed', '2024-01-01', '2024-01-31',
    '2026-11-07T10:00:00Z', '2026-11-07T12:00:00Z');
add_execution(undef, 'test_sum', 'completed', undef, undef, '2026-11-08T10:00:00Z');

subtest 'filtri e heatmap leggono tutto lo storico, senza limite di pagina' => sub {
    for (1 .. 26) {
        add_execution('radar_a', 'valida_battute', 'completed', '2026-06-01', '2026-06-30',
            '2026-11-10T10:00:00Z', '2026-11-10T12:00:00Z');
    }
    is_deeply $repo->dashboard_databases, ['radar_a', 'radar_b'];
    $t->get_ok('/cruscotto?database=radar_a&year=2026')->status_is(200)
        ->element_exists('select[name=database] option[value=radar_a][selected]')
        ->element_exists('select[name=year] option[value=2026][selected]')
        ->element_exists('select[name=year] option[value=2025]')
        ->element_exists_not('select[name=year] option[value=2024]');
    my $base = 'tr[data-procedure=valida_battute]';
    $t->element_exists("$base td[data-month=1] a.heat-success[href=\"/executions/$old\"]")
        ->element_exists("$base td[data-month=2] a.heat-failure[href=\"/executions/$failed\"]")
        ->element_exists("$base td[data-month=4] a.heat-active[href=\"/executions/$queued\"]")
        ->element_exists("$base td[data-month=5] a.heat-active[href=\"/executions/$running\"]")
        ->element_exists("$base td[data-month=7] .heat-empty")
        ->element_exists('tr[data-procedure=rettifica_quote] td[data-month=3] a.heat-timeout')
        ->text_like('tr[data-procedure=rettifica_quote] td[data-month=3] a span:last-child', qr/24\/11\/2026/)
        ->text_like("$base td[data-month=4] a span:last-child", qr/Non conclusa/)
        ->text_like("$base td[data-month=1] a span:last-child", qr/01\/11\/2026/)
        ->attr_like("$base td[data-month=1] a", 'title', qr/Riuscita; completamento: 01\/11\/2026/)
        ->attr_like("$base td[data-month=4] a", 'title', qr/Accodata; completamento: Non conclusa/)
        ->element_exists("table.dashboard-unknown a[href=\"/executions/$missing\"]")
        ->text_like('[role=alert]', qr/1 esecuzioni senza intervallo/);
    is $t->tx->res->dom->find("$base td")->size, 12, 'esattamente dodici mesi';
    $t->get_ok('/cruscotto?database=radar_a&year=2025')->status_is(200)
        ->element_exists("$base td[data-month=12] a[href=\"/executions/$old\"]")
        ->element_exists("$base td[data-month=1] .heat-empty");
    $t->get_ok('/cruscotto?database=radar_b')->status_is(200)
        ->element_exists('select[name=year] option[value=2024][selected]')
        ->element_exists("$base td[data-month=1] a[href=\"/executions/$other\"]")
        ->element_exists_not('.dashboard-unknown');
};

subtest 'ordine delle richieste non del completamento, spareggio persistente' => sub {
    add_execution('radar_order', 'rettifica_quote', 'completed', '2026-01-01', '2026-01-31',
        '2026-11-01T10:00:00Z', '2026-11-24T10:00:00Z');
    add_execution('radar_order', 'rettifica_quote', 'failed', '2026-01-01', '2026-01-31',
        '2026-11-02T10:00:00Z', '2026-11-23T10:00:00Z');
    my $latest = add_execution('radar_order', 'rettifica_quote', 'queued', '2026-01-01', '2026-01-31',
        '2026-11-02T10:00:00Z');
    $t->get_ok('/cruscotto?database=radar_order&year=2026')->status_is(200)
        ->element_exists("tr[data-procedure=rettifica_quote] td[data-month=1] a.heat-active[href=\"/executions/$latest\"]");
};

subtest 'input non valido esplicito, escaping ed esecuzioni senza date' => sub {
    $t->get_ok('/cruscotto?database=unknown')->status_is(422);
    $t->get_ok('/cruscotto?database=radar_a&year=2027')->status_is(422);
    $t->get_ok('/cruscotto?database=radar_a&year=2026%27')->status_is(422);
    add_execution('<script>alert(1)</script>', 'valida_battute', 'failed', undef, undef,
        '2026-11-24T10:00:00Z', '2026-11-24T11:00:00Z');
    my $url = Mojo::URL->new('/cruscotto')->query(database => '<script>alert(1)</script>');
    $t->get_ok($url)->status_is(200)
        ->content_unlike(qr/<script>alert\(1\)<\/script>/)
        ->content_like(qr/&lt;script&gt;/)
        ->element_exists('.dashboard-unknown')
        ->element_exists_not('.heatmap a');
};

done_testing;
