use Mojo::Base -strict, -signatures;
use Test::More;
use File::Temp 'tempdir';
use Mojo::File 'path';
use FindBin;
use lib "$FindBin::Bin/../lib";
use ScriptManager::Service::ProcedureRegistry;

my $root = path($FindBin::Bin, '..', '..')->realpath;

my $registry = ScriptManager::Service::ProcedureRegistry->new(file => $root->child('config', 'procedures.yml'))->load;
ok $registry->get('example_echo'), 'shipped catalog contains example_echo';
is $registry->get('nope'), undef, 'unknown procedure';

{
    my $file = path(tempdir(CLEANUP => 1), 'defaults.yml');
    $file->spew(<<'YAML');
procedures:
  - {code: plain, name: Plain, handler_class: ScriptManager::Command::Example, execution_mode: sync, timeout_seconds: 5}
YAML
    my $p = ScriptManager::Service::ProcedureRegistry->new(file => $file)->load->get('plain');
    ok $p, 'enabled by default';
    is $p->{description}, '', 'description defaults to empty string';
}

sub load_yaml ($yaml) {
    my $file = path(tempdir(CLEANUP => 1), 'p.yml');
    $file->spew($yaml);
    return eval { ScriptManager::Service::ProcedureRegistry->new(file => $file)->load } ? undef : $@;
}

like load_yaml(<<'YAML'), qr/fuori da ScriptManager::Command/, 'handler outside namespace rejected';
procedures:
  - {code: bad, name: Bad, handler_class: Mojo::File, execution_mode: sync, timeout_seconds: 5}
YAML

like load_yaml(<<'YAML'), qr/sync o async/, 'invalid mode rejected';
procedures:
  - {code: bad, name: Bad, handler_class: ScriptManager::Command::Example, execution_mode: later, timeout_seconds: 5}
YAML

like load_yaml(<<'YAML'), qr/x-sensitive richiedono execution_mode sync/, 'sensitive async rejected';
procedures:
  - code: bad
    name: Bad
    handler_class: ScriptManager::Command::Example
    execution_mode: async
    timeout_seconds: 5
    parameter_schema:
      properties:
        pw: {type: string, x-sensitive: true}
YAML

like load_yaml(<<'YAML'), qr/non trovato/, 'missing handler rejected';
procedures:
  - {code: bad, name: Bad, handler_class: ScriptManager::Command::Missing, execution_mode: sync, timeout_seconds: 5}
YAML

done_testing;
