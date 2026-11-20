use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestValidationWindow;
use Mojo::File 'path';
use ScriptManager::Command::ValidaBattute;
use ScriptManager::Service::ProcedureRegistry;

{
    package BattuteLegacyStatement;
    use Mojo::Base -base, -signatures;
    has [qw(db sql rows)];
    sub execute ($self) {
        my $sql = $self->sql;
        if ($sql =~ /^SELECT/) {
            my @hits = grep { $sql !~ /validation IS NULL/ || !defined $_->[5] } @{$self->db->hits};
            @hits = sort { $a->[1] <=> $b->[1] } @hits if $sql =~ /order by time_italy/i;
            @hits = reverse @hits if $sql =~ /desc/i;
            $self->rows([map {
                $sql =~ /X_m,Y_m,H_m/ ? [@$_[0 .. 4]]
                    : $sql =~ /X_m, Y_m/ ? [@$_[0 .. 3]] : [@$_[0, 1]]
            } @hits]);
        }
        else { $self->db->do($sql) }
        return 1;
    }
    sub fetchall_arrayref ($self) { return $self->rows }
    sub fetchrow_array ($self) { return @{shift @{$self->rows} // []} }
    sub finish ($self) { return 1 }
}
{
    package BattuteLegacyDatabase;
    use Mojo::Base -base, -signatures;
    has hits => sub { [] };
    has track => sub { {validation_fl => 'Y', validation_bt => undef} };
    sub prepare ($self, $sql) { return BattuteLegacyStatement->new(db => $self, sql => $sql) }
    sub do ($self, $sql) {
        $sql =~ s/\s+/ /g;
        if ($sql =~ /UPDATE battute SET validation = '(\w)' WHERE row_id\s*(?:in \(([^)]+)\)|= '(\d+)')/i) {
            my ($flag, $ids) = ($1, $2 // $3);
            my %ids = map { $_ => 1 } split /,/, $ids;
            $_->[5] = $flag for grep { $ids{$_->[0]} } @{$self->hits};
        }
        elsif ($sql =~ /UPDATE FLAY SET (.*) WHERE row_id/i) {
            my $set = $1;
            $self->track->{validation_fl} = $1 if $set =~ /validation_fl = '(\w)'/;
            $self->track->{validation_bt} = 0 + $1 if $set =~ /validation_bt = (\d)/;
        }
        else { die "Unexpected legacy SQL: $sql" }
        return 1;
    }
}

my $root = path($FindBin::Bin, '..', '..')->realpath;
my $source = $root->child('legacy', 'scripts', '04-valida_battute_1.0.pl')->slurp;
$source =~ s/\r\n/\n/g;
$source =~ /(\$soglia=500;.*?\$sel_flay_h->finish;)/s or die 'Ciclo legacy non trovato';
my $loop = $1;
$source =~ /(sub distanza3\b.*)\z/s or die 'Distanze legacy non trovate';
my $distances = $1;
my $serial = 0;

sub legacy ($hits, $operation) {
    my $db = BattuteLegacyDatabase->new(hits => [map { [@$_] } @$hits]);
    my $package = 'LegacyBattute' . ++$serial;
    {
        no strict 'refs';
        ${"${package}::db_radar"} = $db;
        ${"${package}::sel_flay_h"} = BattuteLegacyStatement->new(rows => [[1, $operation]]);
    }
    my $output = '';
    open my $capture, '>', \$output or die $!;
    local *STDOUT = $capture;
    my $ok = eval "package $package; no strict; no warnings; $loop\n$distances\n1;";
    die $@ unless $ok;
    return {flags => {map { $_->[0] => $_->[5] } @{$db->hits}}, %{$db->track}};
}

sub line_hits ($count, $speed = 100) {
    return [map { [$_ + 1, $_ * 10, $_ * 10 * $speed, 0, 100, undef] } 0 .. $count - 1];
}

my @fixtures;
for my $count (3, 4, 5, 7, 8, 10) {
    push @fixtures, {name => "$count battute rettilinee", hits => line_hits($count), operation => 'D'};
}
push @fixtures,
    {name => 'taxi sotto 28 m/s', hits => line_hits(8, 27), operation => 'D'},
    {name => 'soglia taxi inclusa', hits => line_hits(8, 28), operation => 'D'},
    {name => 'soglia iniziale 500 esclusa', hits => line_hits(8, 500), operation => 'D'};
my $few_valid = line_hits(5);
$_->[4] = 100000 for @$few_valid[2 .. 4];
push @fixtures, {name => 'meno di quattro valide', hits => $few_valid, operation => 'D'};
my $four_valid = line_hits(5);
$four_valid->[-1][4] = 100000;
push @fixtures, {name => 'quattro valide', hits => $four_valid, operation => 'D'};
my $gap_limit = line_hits(10);
$_->[1] += 50 for @$gap_limit[6 .. 9];
$_->[2] += 5000 for @$gap_limit[6 .. 9];
push @fixtures, {name => 'intervallo di 60 secondi ammesso', hits => $gap_limit, operation => 'D'};
for my $operation ('D', 'A') {
    my $hits = line_hits(12);
    $_->[1] += 61 for @$hits[6 .. 11];
    push @fixtures, {name => "spezzatura $operation", hits => $hits, operation => $operation};
}
for my $kind ('time', 'stationary', 'turn', 'altitude', 'zero_altitude', 'speed_limit') {
    my $hits = line_hits(10);
    $hits->[8][1] = $hits->[7][1] if $kind eq 'time';
    $hits->[8][2] = $hits->[7][2] if $kind eq 'stationary';
    $hits->[8][2] = $hits->[7][2] - 1000 if $kind eq 'turn';
    $hits->[8][4] = 10000 if $kind eq 'altitude';
    $hits->[8][4] = 0 if $kind eq 'zero_altitude';
    $hits->[8][2] = $hits->[7][2] + 5000 if $kind eq 'speed_limit';
    push @fixtures, {name => $kind, hits => $hits, operation => 'D'};
}
my $marked = line_hits(10);
$marked->[2][5] = 'A';
push @fixtures, {name => 'stati preesistenti', hits => $marked, operation => 'D'};

subtest 'caratterizzazione del ciclo legacy reale' => sub {
    my $straight = legacy(line_hits(8), 'D');
    is_deeply [values %{$straight->{flags}}], [('Y') x 8], 'otto battute rettilinee valide';
    is $straight->{validation_fl}, 'Y';
    is $straight->{validation_bt}, 1;
    my $short = legacy(line_hits(5), 'D');
    is $short->{validation_fl}, 'L', 'cinque battute: traccia corta';
    my $taxi = legacy(line_hits(8, 27), 'D');
    is_deeply [values %{$taxi->{flags}}], [('T') x 8], 'taxi scartati';
    is $taxi->{validation_fl}, 'D';
    my $four = legacy(line_hits(4), 'D');
    is $four->{validation_fl}, 'D', 'quattro battute non bastano a inizializzare il controllo';
    for my $fixture (@fixtures) {
        my $result = legacy($fixture->{hits}, $fixture->{operation});
        ok defined $result->{validation_bt}, "$fixture->{name}: ciclo termina";
        $fixture->{legacy} = $result;
    }
};

subtest 'equivalenza sui casi definiti del legacy' => sub {
    for my $fixture (@fixtures) {
        next if @{$fixture->{hits}} < 5 || $fixture->{name} eq 'soglia iniziale 500 esclusa';
        is_deeply(ScriptManager::Command::ValidaBattute->analyze_track($fixture->{hits}, $fixture->{operation}),
            $fixture->{legacy}, $fixture->{name});
    }
};

subtest 'casi difettosi corretti secondo le regole approvate' => sub {
    for my $hits ([], line_hits(3), line_hits(4), line_hits(8, 500)) {
        my $result = ScriptManager::Command::ValidaBattute->analyze_track($hits, 'D');
        is $result->{validation_fl}, 'D', 'senza inizializzazione la traccia e D';
        is $result->{validation_bt}, 0;
        is_deeply [values %{$result->{flags}}], [('N') x @$hits], 'tutte le candidate sono N';
    }
    eval { ScriptManager::Command::ValidaBattute->analyze_track(line_hits(8), 'N') };
    ok(ScriptManager::Exception->caught($@, 'invalid_operation'), 'operazione non supportata esplicita');
    my $bad = line_hits(8);
    $bad->[3][1] = undef;
    eval { ScriptManager::Command::ValidaBattute->analyze_track($bad, 'D') };
    ok(ScriptManager::Exception->caught($@, 'invalid_hit'), 'tempo mancante non diventa zero');
};

{
    package AlgorithmOnlyPreflight;
    use Mojo::Base -base, -signatures;
    sub check ($self, @args) { }
    sub check_saving ($self, @args) { }
}
{
    package BattuteContext;
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
    package BattuteDatabase;
    use Mojo::Base -base, -signatures;
    has [qw(ctx fail)];
    has tracks => sub { [[1, 'D'], [2, 'A']] };
    has hits => sub {
        my $taxi = main::line_hits(5, 27);
        $_->[0] += 1000 for @$taxi;
        return {1 => main::line_hits(8), 2 => $taxi};
    };
    has writes => sub { [] };
    has observations => sub { [] };
    has disconnected => 0;
    sub selectall_arrayref ($self, $sql, $attributes = undef, @bind) {
        if ($sql =~ /SELECT row_id, flay_operation/) {
            Test::More::is_deeply(\@bind, ['Y'], 'selezione solo tracce Y con validation_bt NULL');
            Test::More::like($sql, qr/validation_bt IS NULL/, 'filtro validation_bt');
            return $self->tracks;
        }
        if ($sql =~ /FROM battute WHERE flay_id/) {
            Test::More::is(scalar @{$self->writes}, 0, 'analisi senza scritture');
            Test::More::like($sql, qr/ORDER BY row_id/, 'ordine deterministico');
            return $self->hits->{$bind[0]};
        }
        if ($sql =~ /GROUP BY validation/) {
            push @{$self->observations}, ['report', [@{$self->ctx->steps->[-1]}]];
            die "report failed\n" if ($self->fail // '') eq 'report';
            return [['Y', 8], ['T', 5]];
        }
        die "Unexpected query $sql";
    }
    sub do ($self, $sql, $attributes, @bind) {
        my $phase = $sql =~ /data_ora_arr/ ? 'dates' : 'flags';
        push @{$self->observations}, [$phase, [@{$self->ctx->steps->[-1]}]];
        die "$phase failed\n" if ($self->fail // '') eq $phase;
        $self->ctx->cancel(1) if ($self->fail // '') eq 'cancel';
        push @{$self->writes}, [$sql, \@bind];
        return 1;
    }
    sub disconnect ($self) {
        push @{$self->observations}, ['disconnect', [@{$self->ctx->steps->[-1]}]];
        die "disconnect failed\n" if ($self->fail // '') eq 'disconnect';
        $self->disconnected(1);
        return 1;
    }
}

subtest 'catalogo e schema' => sub {
    local $ENV{MRT_CONFIG_FILE} = $root->child('config', 'MRT.example.json')->to_string;
    my $registry = ScriptManager::Service::ProcedureRegistry->new(file => $root->child('config', 'procedures.yml'))->load;
    my $procedure = $registry->get('valida_battute');
    ok $procedure, 'procedura disponibile';
    my ($data, $errors) = $registry->validator($procedure)->validate({database => 'radar_test'});
    is_deeply $errors, [], 'basta il database, aeroporto non utilizzato';
    (undef, $errors) = $registry->validator($procedure)->validate({database => 'bad;db'});
    ok @$errors, 'database non valido rifiutato';
};

subtest 'esecuzione e progressione di tutte le fasi' => sub {
    local $ENV{MYSQL_HOST} = 'localhost';
    local $ENV{MYSQL_PORT} = 3306;
    local $ENV{MYSQL_USER} = 'test';
    local $ENV{MYSQL_PASSWORD} = 'not-a-real-password';
    for my $mode ('normal', 'empty', 'batch', 'flags', 'dates', 'report', 'disconnect', 'cancel', 'operation') {
        subtest $mode => sub {
            my $ctx = BattuteContext->new;
            my $db = BattuteDatabase->new(ctx => $ctx, fail => $mode);
            $db->tracks([]) if $mode eq 'empty';
            $db->hits->{1} = line_hits(501) if $mode eq 'batch';
            $db->tracks([[1, 'D'], [2, 'N']]) if $mode eq 'operation';
            my $command = ScriptManager::Command::ValidaBattute->new(
                preflight => AlgorithmOnlyPreflight->new, window_class => 'TestValidationWindow', connect_db => sub (@args) {
                like $args[0], qr/database=radar_test;host=localhost;port=3306/, 'connessione richiesta';
                ok $args[3]{AutoCommit}, 'comportamento legacy AutoCommit esplicito';
                return $db;
            });
            my $result = eval { $command->run($ctx, {database => 'radar_test'}) };
            my $error = $@;
            my @percent = map { $_->[0] } @{$ctx->steps};
            ok !grep({ $percent[$_] < $percent[$_ - 1] } 1 .. $#percent), 'avanzamento monotono';
            if ($mode eq 'normal' || $mode eq 'empty' || $mode eq 'batch') {
                ok $result->{success}, 'completato';
                is $result->{data}{tracks}, $mode eq 'empty' ? 0 : 2;
                is $percent[-1], 100, '100 solo a conclusione';
                ok $db->disconnected, 'connessione chiusa';
                my @dates = grep { $_->[0] =~ /data_ora_arr/ } @{$db->writes};
                is scalar @dates, 2, 'date completate anche senza nuove tracce';
                like $dates[0][0], qr/MIN\(time_italy\)/, 'minimo per decolli';
                like $dates[1][0], qr/MAX\(time_italy\)/, 'massimo per atterraggi';
                for my $date (@dates) {
                    like $date->[0], qr/f\.data_ora_arr IS NULL/, 'date gia presenti preservate';
                    is_deeply [@{$date->[1]}[0, 1, 3]], ['Y', 'L', 1], 'solo battute Y/L e tracce validation_bt=1';
                }
                if ($mode eq 'normal') {
                    my @flags = grep { $_->[0] =~ /^UPDATE battute/ } @{$db->writes};
                    is_deeply $flags[0][1], ['Y', 1 .. 8], 'battute valide salvate con placeholder';
                    is_deeply $flags[1][1], ['T', 1001 .. 1005], 'taxi salvati con placeholder';
                    my @tracks = grep { $_->[0] =~ /^UPDATE flay SET/ } @{$db->writes};
                    is_deeply [map { $_->[1] } @tracks], [['Y', 1, 1], ['D', 0, 2]], 'stati delle tracce salvati';
                }
                if ($mode eq 'batch') {
                    my @flags = grep { $_->[0] =~ /^UPDATE battute/ && $_->[1][0] eq 'Y' } @{$db->writes};
                    is_deeply [map { scalar(@{$_->[1]}) - 1 } @flags], [500, 1],
                        'UPDATE limitati a 500 identificatori senza perdere battute';
                }
            }
            else {
                ok $error, 'errore non nascosto';
                ok !grep({ $_ == 100 } @percent), 'nessun falso completamento';
                if ($mode eq 'operation') {
                    ok(ScriptManager::Exception->caught($error, 'invalid_operation'), 'operazione non supportata');
                    is scalar @{$db->writes}, 0, 'rifiuto prima delle scritture';
                }
                elsif ($mode eq 'cancel') {
                    ok(ScriptManager::Exception->caught($error, 'cancelled'), 'cancellazione propagata');
                }
                else { like "$error", qr/\Q$mode\E failed/, 'errore originale conservato' }
            }
            for my $observation (@{$db->observations}) {
                my ($phase, $step) = @$observation;
                cmp_ok $step->[0], '<', 100, "$phase prima del 100%";
                if ($phase eq 'report' || $phase eq 'disconnect') {
                    is $step->[0], 99, 'riepilogo al 99%' if $mode eq 'normal' || $mode eq 'empty';
                }
                else {
                    cmp_ok $step->[0], '>=', 50, 'scritture dal 50%';
                    cmp_ok $step->[0], '<', 99, 'date comprese nel salvataggio';
                    like $step->[1], qr/Salvataggio/, 'fase di salvataggio visibile';
                }
            }
            unlike join(' ', map { join ' ', @$_ } @{$ctx->events}), qr/not-a-real-password/, 'password non loggata';
        };
    }
};

done_testing;
