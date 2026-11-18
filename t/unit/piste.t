use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestValidationWindow;
use Mojo::File 'path';
use ScriptManager::Service::RunwayGeometry;
use ScriptManager::Command::TrovaPistaAtterraggi;
use ScriptManager::Command::TrovaPistaDecolli;
use ScriptManager::Service::ProcedureRegistry;

{
    package PisteLegacyStatement;
    use Mojo::Base -base, -signatures;
    has [qw(db sql rows)];
    sub execute ($self, @bind) {
        my $sql = $self->sql // '';
        if ($sql =~ /^SELECT p\.LONG_pista/) { $self->rows([map { [@$_[1 .. 3]] } @{$self->db->runways}]) }
        elsif ($sql =~ /^SELECT/) { $self->rows([map { [@$_] } @{$self->db->hits}]) }
        else { $self->db->update($sql) }
        return @{$self->rows // []} || '0E0';
    }
    sub fetchrow_array ($self) { return @{shift @{$self->rows} // []} }
    sub fetchall_arrayref ($self) { return $self->rows }
    sub finish ($self) { return 1 }
    sub errstr ($self) { return '' }
}
{
    package PisteLegacyDatabase;
    use Mojo::Base -base, -signatures;
    has [qw(hits runways)];
    has result => sub { {pista => undef, excluded => []} };
    sub prepare ($self, $sql) { return PisteLegacyStatement->new(db => $self, sql => $sql) }
    sub errstr ($self) { return '' }
    sub update ($self, $sql) {
        if ($sql =~ /UPDATE flay SET pista = '([^']*)'/) {
            $self->result->{pista} = $1;
            $self->result->{sid} = $1 if $sql =~ /sid = '([^']*)'/;
            $self->result->{invalid} = 1 if $sql =~ /validation_fl = 'P'/;
        }
        elsif ($sql =~ /UPDATE battute SET validation = 'X'.*row_id = '(\d+)'/) {
            push @{$self->result->{excluded}}, 0 + $1;
        }
        else { die "Unexpected legacy SQL: $sql" }
    }
}

my $root = path($FindBin::Bin, '..', '..')->realpath;
my $serial = 0;
sub runways ($airport) {
    return [
        ['35R', 1479700, 5040000, 200], ['17L', 1479700, 5060000, 200],
        ['35L', 1478900, 5040000, 200], ['17R', 1478900, 5060000, 200],
    ] if $airport eq 'LIMC';
    return [['36R', 0, 0, 200], ['18L', 0, 10000, 200]] if $airport eq 'LIML';
    return [map { [$_->[0], $_->[1], 0, 200] }
        [$airport eq 'LIME' ? '11' : '14', 0], [$airport eq 'LIME' ? '29' : '32', 10000]];
}

sub legacy ($fixture) {
    my $mode = $fixture->{mode};
    my $revision = $fixture->{revision} // '1.2';
    my $file = $mode eq 'A' ? "05-trova_pista_atterraggi_$revision.pl" : '06-trova_pista_decolli_1.1.pl';
    my $source = $root->child('legacy', 'scripts', $file)->slurp;
    $source =~ s/\r\n/\n/g;
    my $airport = $fixture->{airport};
    $source =~ /(if \(\$aeroporto eq '\Q$airport\E'\)\s*\{.*?)(?=^#\*+ FINE ALGORITMO)/ms
        or die "Ramo legacy non trovato: $file $airport";
    my $branch = $1;
    $source =~ /(sub distance\b.*)\z/s or die 'Funzioni geometriche non trovate';
    my $functions = $1;
    my $db = PisteLegacyDatabase->new(hits => $fixture->{hits}, runways => runways($airport));
    my $package = 'LegacyPiste' . ++$serial;
    {
        no strict 'refs';
        ${"${package}::aeroporto"} = $airport;
        ${"${package}::db_radar"} = $db;
        ${"${package}::selTh"} = PisteLegacyStatement->new(rows => [[1]]);
        ${"${package}::selBh"} = PisteLegacyStatement->new(db => $db, sql => 'SELECT hits');
        ${"${package}::X_aerop"} = 1479300;
        ${"${package}::Y_aerop"} = 5050000;
    }
    open my $input, '<', \"Y\n" or die $!;
    my $output = '';
    open my $capture, '>', \$output or die $!;
    local *STDIN = $input;
    local *STDOUT = $capture;
    my $ok = eval "package $package; no strict; no warnings; $branch\n$functions\n1;";
    die $@ unless $ok;
    return $db->result;
}

my @fixtures;
for my $mode ('A', 'D') {
    for my $airport (qw(LIMC LIML LIME LIPO)) {
        for my $reverse (0, 1) {
            my $hits = $airport eq 'LIMC'
                ? [map { [1479700, 5050000 + $_ * 100, 300, $_ + 1] } 0 .. 3]
                : $airport eq 'LIML'
                ? [map { [0, $_ * 100, 300, $_ + 1] } 0 .. 3]
                : [map { [$_ * 100, $airport eq 'LIPO' && $mode eq 'A' ? -2515 : -376, 300, $_ + 1] } 0 .. 3];
            $hits = [reverse @$hits] if $reverse;
            push @fixtures, {name => "$mode $airport reverse=$reverse", mode => $mode, airport => $airport, hits => $hits};
        }
    }
}
for my $revision ('1.0', '1.1', '1.2') {
    my $hits = [map { [$_ == 1 ? 1000 : $_ * 100, 400, 300, $_ + 1] } 0 .. 9];
    push @fixtures, {name => "Orio revisione $revision", mode => 'A', airport => 'LIME', revision => $revision, hits => $hits};
}
push @fixtures,
    {name => 'Malpensa OVEST atterraggio nord', mode => 'A', airport => 'LIMC',
        hits => [[1478900, 5050000, 300, 1], [1478900, 5050100, 300, 2]]},
    {name => 'Malpensa OVEST atterraggio sud', mode => 'A', airport => 'LIMC',
        hits => [[1478900, 5050100, 300, 1], [1478900, 5050000, 300, 2]]},
    {name => 'Malpensa OVEST decollo nord', mode => 'D', airport => 'LIMC',
        hits => [[1478900, 5050000, 300, 1], [1478900, 5050100, 300, 2], [0, 0, 300, 3]]},
    {name => 'Malpensa OVEST decollo sud', mode => 'D', airport => 'LIMC',
        hits => [[1478900, 5050100, 300, 1], [1478900, 5050000, 300, 2], [0, 0, 300, 3]]},
    {name => 'Malpensa rettifica EST', mode => 'D', airport => 'LIMC',
        hits => [[1479900, 5054000, 300, 1], [1479900, 5053900, 300, 2], [0, 0, 300, 3]]},
    {name => 'Malpensa rettifica OVEST', mode => 'D', airport => 'LIMC',
        hits => [[1477700, 5054000, 300, 1], [1477700, 5053900, 300, 2], [0, 0, 300, 3]]},
    {name => 'Montichiari revisione 1.1', mode => 'A', airport => 'LIPO', revision => '1.1',
        hits => [[0, -2515, 300, 1], [100, -2515, 300, 2], [200, -2515, 300, 3]]},
    {name => 'Malpensa recupero ultima battuta', mode => 'A', airport => 'LIMC',
        hits => [[1479700, 5050000, 300, 1], [1479700, 5050100, 300, 2], [0, 0, 300, 3]]},
    {name => 'Malpensa quota limite esclusa', mode => 'A', airport => 'LIMC',
        hits => [[1479700, 5050000, 800, 1], [1479700, 5050100, 800, 2]]},
    {name => 'Malpensa senza battute', mode => 'A', airport => 'LIMC', hits => []},
    {name => 'Malpensa taxi', mode => 'D', airport => 'LIMC',
        hits => [[1479700, 5050000, 300, 1], [1479700, 5050100, 300, 2], [1479000, 5052000, 300, 3]]},
    {name => 'Malpensa perpendicolare', mode => 'D', airport => 'LIMC',
        hits => [[1479700, 5052000, 300, 1], [1479800, 5052000, 300, 2], [0, 0, 300, 3]]},
    {name => 'Linate seconda battuta mancante', mode => 'D', airport => 'LIML',
        hits => [[0, 0, 300, 1], [0, 100, 300, 2]]};

subtest 'caratterizzazione dei rami legacy originali' => sub {
    for my $fixture (@fixtures) {
        $fixture->{legacy} = legacy($fixture);
        ok exists $fixture->{legacy}{pista}, "$fixture->{name}: ramo eseguito";
    }
    is $fixtures[0]{legacy}{pista}, '35R', 'Malpensa EST verso nord';
    is $fixtures[1]{legacy}{pista}, '17L', 'Malpensa EST verso sud';
    my %by_name = map { $_->{name} => $_->{legacy} } @fixtures;
    is $by_name{'Malpensa OVEST atterraggio nord'}{pista}, '35L';
    is $by_name{'Malpensa OVEST atterraggio sud'}{pista}, '17R';
    is $by_name{'Malpensa OVEST decollo nord'}{pista}, '35L';
    is $by_name{'Malpensa OVEST decollo sud'}{pista}, '17R';
    is $by_name{'Malpensa rettifica EST'}{pista}, '35R';
    is $by_name{'Malpensa rettifica OVEST'}{pista}, '35L';
    is $by_name{'Orio revisione 1.0'}{pista}, '29', 'offset legacy 1.0';
    is $by_name{'Orio revisione 1.2'}{pista}, '11', 'offset rimosso nella 1.2';
    is_deeply $by_name{'Malpensa recupero ultima battuta'}{excluded}, [3], 'recupero marca X';
    is $by_name{'Malpensa taxi'}{pista}, 'N2', 'taxi prevale sull assegnazione';
    is $by_name{'Malpensa perpendicolare'}{pista}, 'N1';
    is $by_name{'Linate seconda battuta mancante'}{pista}, '18L',
        'difetto legacy: array vuoto confrontato con stringa, coordinata mancante trattata come zero';
};

subtest 'geometria estratta equivalente ai rami legacy determinati' => sub {
    for my $fixture (@fixtures) {
        next if $fixture->{name} eq 'Linate seconda battuta mancante';
        my $geometry = ScriptManager::Service::RunwayGeometry->prepare(
            $fixture->{airport}, $fixture->{mode}, $fixture->{revision} // '1.2',
            [reverse @{runways($fixture->{airport})}], [1479300, 5050000]);
        my $result = ScriptManager::Service::RunwayGeometry->analyze($geometry, $fixture->{hits});
        is_deeply {map { $_ => $result->{$_} } qw(pista invalid excluded)},
            {pista => $fixture->{legacy}{pista}, invalid => $fixture->{legacy}{invalid} // 0,
                excluded => $fixture->{legacy}{excluded}}, $fixture->{name} . ': righe anagrafica riordinate';
    }
};

subtest 'correzioni conservative e associazione degli estremi per nome' => sub {
    my $rows = runways('LIML');
    push @$rows, ['36L', 90000, 0, 200], ['18R', 90000, 10000, 200];
    my $geometry = ScriptManager::Service::RunwayGeometry->prepare('LIML', 'D', '1.2', [reverse @$rows]);
    my $missing = ScriptManager::Service::RunwayGeometry->analyze($geometry, [[0, 0, 300, 1], [0, 100, 300, 2]]);
    is $missing->{pista}, 'NA', 'battuta mancante non diventa coordinata zero';
    ok $missing->{invalid}, 'traccia invalidata esplicitamente';
    my $valid = ScriptManager::Service::RunwayGeometry->analyze($geometry,
        [[0, 0, 300, 1], [0, 100, 300, 2], [0, 200, 300, 3]]);
    is $valid->{pista}, '36R', 'Linate ignora gli estremi della pista secondaria';
    my $arrival = ScriptManager::Service::RunwayGeometry->prepare('LIML', 'A', '1.2', $rows);
    is(ScriptManager::Service::RunwayGeometry->analyze($arrival, [[0, 0, 300, 1]])->{pista}, 'NA',
        'singola battuta non eredita la pista della traccia precedente');
    eval { ScriptManager::Service::RunwayGeometry->prepare('LIPO', 'A', '1.0', runways('LIPO')) };
    ok(ScriptManager::Exception->caught($@, 'invalid_airport'), 'Montichiari non simulato nella 1.0');
    for my $bad ([], [['36R', 0, 0, 200], ['18L', 0, 0, 200]],
        [['36R', undef, 0, 200], ['18L', 0, 1, 200]],
        [@$rows, ['36R', 0, 1, 200]]) {
        eval { ScriptManager::Service::RunwayGeometry->prepare('LIML', 'A', '1.2', $bad) };
        ok(ScriptManager::Exception->caught($@, 'runway_geometry'), 'anagrafica mancante o degenere rifiutata');
    }
    eval { ScriptManager::Service::RunwayGeometry->analyze($geometry, [[0, undef, 300, 1]]) };
    ok(ScriptManager::Exception->caught($@, 'invalid_hit'), 'coordinate mancanti non convertite in zero');
};

{
    package PisteContext;
    use Mojo::Base -base, -signatures;
    has steps => sub { [] };
    has events => sub { [] };
    has cancel => 0;
    sub log ($self, @event) { push @{$self->events}, \@event }
    sub progress ($self, @step) { push @{$self->steps}, \@step }
    sub check_cancel ($self) {
        ScriptManager::Exception->throw('cancelled', 'Annullata') if $self->cancel;
    }
}
{
    package PisteDatabase;
    use Mojo::Base -base, -signatures;
    has [qw(ctx fail operation)];
    has ids => sub { [1, 2] };
    has hits => sub { {
        1 => [[1479700, 5050000, 300, 11], [1479700, 5050100, 300, 12], [0, 0, 300, 13]],
        2 => [],
    } };
    has writes => sub { [] };
    has disconnected => 0;
    sub selectcol_arrayref ($self, $sql, $attributes, @bind) {
        Test::More::like($sql, qr/validation_bt = \? AND pista IS NULL/, 'filtro tracce validate senza pista');
        Test::More::is_deeply(\@bind, [$self->operation, 1], 'A/D e validation_bt tramite placeholder');
        return $self->ids;
    }
    sub selectrow_arrayref ($self, $sql, $attributes, $airport) { return [1479300, 5050000] }
    sub selectall_arrayref ($self, $sql, $attributes, @bind) {
        if ($sql =~ /FROM anagrafica/) {
            return [] if ($self->fail // '') eq 'geometry';
            return [reverse @{main::runways('LIMC')}];
        }
        if ($sql =~ /FROM battute/) {
            Test::More::is(scalar @{$self->writes}, 0, 'analisi prima delle scritture');
            Test::More::like($sql, qr/ORDER BY time_italy, row_id/, 'tempo con spareggio deterministico');
            Test::More::is($bind[1], 'Y', 'solo battute Y');
            return $self->hits->{$bind[0]};
        }
        if ($sql =~ /GROUP BY pista/) {
            Test::More::is($self->ctx->steps->[-1][0], 99, 'riepilogo al 99%');
            Test::More::is(!!($sql =~ /sid IS NULL/), $self->operation eq 'D' ? 1 : '', 'filtro SID solo nel riepilogo decolli');
            die "report failed\n" if ($self->fail // '') eq 'report';
            return [['35R', 1], ['NA', 1]];
        }
        die "Unexpected SQL $sql";
    }
    sub do ($self, $sql, $attributes, @bind) {
        my $step = $self->ctx->steps->[-1];
        Test::More::cmp_ok($step->[0], '>=', 50, 'scritture dal 50%');
        Test::More::cmp_ok($step->[0], '<', 99, 'scritture prima del riepilogo');
        Test::More::like($step->[1], qr/Salvataggio/, 'fase visibile durante le scritture');
        die "write failed\n" if ($self->fail // '') eq 'write';
        $self->ctx->cancel(1) if ($self->fail // '') eq 'cancel';
        push @{$self->writes}, [$sql, \@bind];
        return 1;
    }
    sub disconnect ($self) {
        Test::More::ok(!grep({ $_->[0] == 100 } @{$self->ctx->steps}), 'non concluso prima della chiusura');
        die "disconnect failed\n" if ($self->fail // '') eq 'disconnect';
        $self->disconnected(1);
        return 1;
    }
}

subtest 'catalogo e parametri' => sub {
    local $ENV{MRT_CONFIG_FILE} = $root->child('config', 'MRT.example.json')->to_string;
    my $registry = ScriptManager::Service::ProcedureRegistry->new(file => $root->child('config', 'procedures.yml'))->load;
    for my $code (qw(trova_pista_atterraggi trova_pista_decolli)) {
        my $procedure = $registry->get($code);
        ok $procedure, "$code nel catalogo";
        my ($data, $errors) = $registry->validator($procedure)->validate({database => 'radar_test', airport => 'LIMC'});
        is_deeply $errors, [], 'parametri accettati';
        is $data->{revision}, '1.2', 'default revisione atterraggi' if $code eq 'trova_pista_atterraggi';
        (undef, $errors) = $registry->validator($procedure)->validate({database => 'db;drop', airport => 'XXXX'});
        ok @$errors, 'parametri non validi rifiutati';
    }
    my $command = ScriptManager::Command::TrovaPistaAtterraggi->new(
        connect_db => sub { die "Connessione non prevista\n" });
    eval { $command->run(PisteContext->new, {database => 'radar_test', airport => 'LIPO', revision => '1.0'}) };
    ok(ScriptManager::Exception->caught($@, 'invalid_airport'), 'LIPO 1.0 rifiutato prima della connessione');
};

subtest 'salvataggi e avanzamento dei due comandi' => sub {
    local $ENV{MYSQL_HOST} = 'localhost';
    local $ENV{MYSQL_PORT} = 3306;
    local $ENV{MYSQL_USER} = 'test';
    local $ENV{MYSQL_PASSWORD} = 'not-a-real-password';
    for my $operation ('A', 'D') {
        for my $mode (qw(normal empty geometry write report disconnect cancel)) {
            subtest "$operation $mode" => sub {
                my $ctx = PisteContext->new;
                my $db = PisteDatabase->new(ctx => $ctx, operation => $operation, fail => $mode);
                $db->ids([]) if $mode eq 'empty';
                $db->hits->{1}[2] = [1479700, 5050200, 300, 13] if $operation eq 'D';
                my $class = $operation eq 'A' ? 'ScriptManager::Command::TrovaPistaAtterraggi'
                    : 'ScriptManager::Command::TrovaPistaDecolli';
                my $command = $class->new(window_class => 'TestValidationWindow', connect_db => sub (@args) {
                    Test::More::like($args[0], qr/database=radar_test;host=localhost;port=3306/, 'database selezionato');
                    return $db;
                });
                my $result = eval { $command->run($ctx, {database => 'radar_test', airport => 'LIMC'}) };
                my $error = $@;
                my @percent = map { $_->[0] } @{$ctx->steps};
                ok !grep({ $percent[$_] < $percent[$_ - 1] } 1 .. $#percent), 'progresso monotono';
                if ($mode eq 'normal' || $mode eq 'empty') {
                    ok $result->{success}, 'comando completato';
                    is $percent[-1], 100, '100 solo alla conclusione';
                    ok $db->disconnected, 'connessione chiusa';
                    if ($mode eq 'normal') {
                        is_deeply [@{$result->{data}}{qw(tracks assigned unassigned)}], [2, 1, 1], 'conteggi della singola esecuzione';
                        my @tracks = grep { $_->[0] =~ /UPDATE flay/ } @{$db->writes};
                        my $sql = $tracks[0][0];
                        is_deeply $tracks[0][1], $operation eq 'A' ? ['35R', '35R', 1] : ['35R', 1], 'pista e SID corretti';
                        like $sql, qr/sid = \?/, 'atterraggi assegnano SID' if $operation eq 'A';
                        unlike $sql, qr/sid|validation_fl|validation_bt/, 'decolli validi preservano SID e stati' if $operation eq 'D';
                        is_deeply $tracks[1][1], [$operation eq 'A' ? 'N9' : 'NA', 'P', 0, 2],
                            'fallimento pista invalida la traccia';
                        my @excluded = grep { $_->[0] =~ /UPDATE battute/ } @{$db->writes};
                        is_deeply [map { $_->[1] } @excluded], $operation eq 'A' ? [['X', 1, 13]] : [],
                            'X solo nel recupero degli atterraggi';
                    }
                    else { is scalar @{$db->writes}, 0, 'nessuna traccia: nessuna scrittura' }
                }
                else {
                    ok $error, 'errore non nascosto';
                    ok !grep({ $_ == 100 } @percent), 'nessun falso 100%';
                    if ($mode eq 'geometry') {
                        ok(ScriptManager::Exception->caught($error, 'runway_geometry'), 'anagrafica non utilizzabile esplicita');
                        is scalar @{$db->writes}, 0, 'errore prima di scrivere';
                    }
                    elsif ($mode eq 'cancel') {
                        ok(ScriptManager::Exception->caught($error, 'cancelled'), 'cancellazione rispettata');
                    }
                    else { like "$error", qr/\Q$mode\E failed/, 'errore originale preservato' }
                }
                unlike join(' ', map { join ' ', @$_ } @{$ctx->events}), qr/not-a-real-password/, 'nessuna password nei log';
            };
        }
    }
};

done_testing;
