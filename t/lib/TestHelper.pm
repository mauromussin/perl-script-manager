package TestHelper;
use Mojo::Base -strict, -signatures;

use File::Temp 'tempdir';
use FindBin;
use Mojo::File 'path';
use Mojo::Pg;
use Test::Mojo;

my @schemas;

sub online () { return $ENV{TEST_ONLINE} }

# Each call gets its own PostgreSQL schema and output directory.
sub config (%o) {
    my $schema = sprintf 'sm_test_%d_%d', $$, int rand 1_000_000;
    Mojo::Pg->new($ENV{TEST_ONLINE})->db->query("create schema $schema");
    push @schemas, $schema;
    return {
        secret   => 'test-secret',
        database => {url => $ENV{TEST_ONLINE}, schema => $schema},
        paths    => {
            output_dir      => tempdir(CLEANUP => 1),
            procedures_file => path($FindBin::Bin, '..', 'fixtures', 'procedures.yml')->realpath->to_string,
        },
        %o,
    };
}

sub mojo (%o) { return Test::Mojo->new('ScriptManager', config(%o)) }

END {
    if (@schemas) {
        my $db = Mojo::Pg->new($ENV{TEST_ONLINE})->db;
        $db->query("drop schema if exists $_ cascade") for @schemas;
    }
}

1;
