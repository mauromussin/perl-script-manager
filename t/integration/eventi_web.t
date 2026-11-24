use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper;
use ScriptManager::Service::EventiCMP;

plan skip_all => 'TEST_ONLINE non impostata' unless TestHelper::online();
local $ENV{MYSQL_HOST} = 'mysql.example.invalid';
local $ENV{MYSQL_PORT} = 3306;
my $t = TestHelper::mojo();
my $sha = 'a' x 64;

{
    no warnings qw(redefine once);
    local *ScriptManager::Service::EventiCMP::preview = sub ($self, $database, $airport) {
        is $database, 'radar_test', 'database passato al servizio';
        is $airport, 'LIMC', 'aeroporto passato al servizio';
        return {
            files => [{name => 'nested/primo.txt', sha256 => $sha}, {name => 'secondo.txt', sha256 => $sha}],
            stations => [{row_id => 1, c_cab => 227, nome => 'Prima', aeroporto => 'LIMC'},
                {row_id => 3, c_cab => 229, nome => 'Altra', aeroporto => undef}],
        };
    };
    $t->get_ok('/procedures/carica_eventi_cmp')->status_is(200)
        ->element_exists('input[name=database]')->element_exists_not('select[name=stations]');
    $t->get_ok('/procedures/carica_eventi_cmp?database=radar_test&airport=LIMC')->status_is(200)
        ->element_exists('input[name=files][value="nested/primo.txt"]')
        ->element_exists('input[name=hashes][value="' . $sha . '"]')
        ->element_exists('select[name=stations] option[value="3:229"]')
        ->content_like(qr/Prima \(codice 227\)/)
        ->content_like(qr/aeroporto non associato/);
    my $token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
    $t->post_ok('/procedures/carica_eventi_cmp/run' => form => {
        csrf_token => $token, database => 'radar_test', airport => 'LIMC',
        files => ['nested/primo.txt', 'secondo.txt'], hashes => [$sha, $sha], stations => ['1:227', '3:229'],
    })->status_is(302);
    my ($id) = $t->tx->res->headers->location =~ m{/executions/([^/]+)};
    my $execution = $t->app->repo->get_execution($id);
    is_deeply $execution->{parameters}{files}, ['nested/primo.txt', 'secondo.txt'], 'file conservati in ordine';
    is_deeply $execution->{parameters}{stations}, ['1:227', '3:229'], 'associazioni e codici conservati in ordine';
}

done_testing;
