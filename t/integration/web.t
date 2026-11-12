use Mojo::Base -strict;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper;

plan skip_all => 'TEST_ONLINE non impostata' unless TestHelper::online();

my $t = TestHelper::mojo();

sub csrf { $t->tx->res->dom->at('input[name=csrf_token]')->attr('value') }

$t->get_ok('/healthz')->status_is(200)->content_is('ok');

$t->get_ok('/')->status_is(200)
    ->content_like(qr/Somma di prova/)
    ->content_unlike(qr/Disabilitata/)
    ->header_is('X-Content-Type-Options' => 'nosniff')
    ->header_like('Content-Security-Policy' => qr/default-src 'self'/);

$t->get_ok('/procedures/test_sum')->status_is(200)->element_exists('input[name=a]');
$t->get_ok('/procedures/test_disabled')->status_is(404);
$t->get_ok('/procedures/../../etc/passwd')->status_is(404);

subtest 'form validation' => sub {
    $t->get_ok('/procedures/test_sum');
    $t->post_ok('/procedures/test_sum/run' => form => {csrf_token => csrf(), a => 'x'})
        ->status_is(422)->content_like(qr/Parametri non validi/);
    $t->post_ok('/procedures/test_sum/run' => form => {a => 1, b => 2})->status_is(403, 'CSRF required');
};

my $location;
subtest 'start and follow an execution' => sub {
    $t->get_ok('/procedures/test_sum');
    $t->post_ok('/procedures/test_sum/run' => form => {csrf_token => csrf(), a => 1, b => 2})
        ->status_is(302);
    $location = $t->tx->res->headers->location;
    $t->get_ok($location)->status_is(200)->content_like(qr/completed/)->content_like(qr/sum=3/);
    $t->get_ok('/executions')->status_is(200)->content_like(qr/Somma di prova/);
    $t->get_ok('/executions?status=failed')->status_is(200)
        ->text_is('tbody tr td', 'Nessuna esecuzione trovata.');
};

subtest 're-run prefills the form with a new record' => sub {
    my ($id) = $location =~ m{/executions/([0-9a-f-]+)};
    $t->get_ok("/procedures/test_sum?from=$id")->status_is(200)->element_exists('input[name=a][value="1"]');
    $t->get_ok('/executions/not-a-uuid')->status_is(404);
};

subtest 'JSON API' => sub {
    $t->get_ok('/api/procedures')->status_is(200)->json_has('/procedures/0/code');
    $t->post_ok('/api/procedures/test_sum/executions' => json => {a => 4, b => 5})
        ->status_is(201)->json_has('/id');
    my $id = $t->tx->res->json->{id};
    $t->get_ok("/api/executions/$id")->status_is(200)
        ->json_is('/status' => 'completed')->json_is('/summary' => 'sum=9')->json_hasnt('/minion_job_id');
    $t->post_ok('/api/procedures/test_sum/executions' => json => {a => 'zzz'})->status_is(422)->json_has('/errors/0');
    $t->post_ok('/api/procedures/test_sum/executions' => form => {a => 1})->status_is(400);
    $t->post_ok('/api/procedures/nope/executions' => json => {})->status_is(404);
};

subtest 'async cancel via web' => sub {
    $t->get_ok('/procedures/test_async');
    $t->post_ok('/procedures/test_async/run' => form => {csrf_token => csrf(), message => 'hi'})->status_is(302);
    my $page = $t->tx->res->headers->location;
    $t->get_ok($page)->status_is(200)->content_like(qr/queued/)->element_exists('meta[http-equiv=refresh]');
    my $token = csrf();
    $t->post_ok("$page/cancel" => form => {csrf_token => $token})->status_is(302);
    $t->get_ok($page)->content_like(qr/cancelled/)->element_exists_not('meta[http-equiv=refresh]');
};

subtest 'controlled artifact download' => sub {
    my $service = $t->app->execution_service;
    my $r       = $service->submit(test_async => {message => 'file', repeat => 1});
    $t->app->minion->perform_jobs;
    my $id = $r->{id};
    my $artifact = $t->app->repo->list_artifacts($id)->[0];

    $t->get_ok("/executions/$id/artifacts/$artifact->{id}")->status_is(200)
        ->content_like(qr/1: file/)
        ->header_like('Content-Disposition' => qr/attachment; filename="output\.txt"/);

    $t->get_ok("/executions/$id/artifacts/99999")->status_is(404);
    $t->get_ok("/executions/$id/artifacts/abc")->status_is(404);

    # Path traversal attempt through a tampered record
    my $secret = $t->app->output_root->child('..', 'outside.txt');
    $secret->spew('secret');
    $t->app->pg->db->query('update execution_artifacts set relative_path = ? where id = ?', "$id/../../outside.txt", $artifact->{id});
    $t->get_ok("/executions/$id/artifacts/$artifact->{id}")->status_is(404);
    $secret->remove;
};

done_testing;
