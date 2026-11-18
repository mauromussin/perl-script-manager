use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestValidationWindow;
use Mojo::File 'path';
use ScriptManager::Service::SIDGeometry;
use ScriptManager::Command::AssegnaSID;

{
    package SIDLegacyStatement;
    use Mojo::Base -base, -signatures;
    has [qw(db sql rows)];
    sub execute ($self) {
        if ($self->sql =~ /^SELECT/) { $self->rows([map { [@$_] } @{$self->db->hits}]) }
        else { $self->db->update($self->sql) }
        return 1;
    }
    sub fetchrow_array ($self) { return @{shift @{$self->rows} // []} }
    sub finish ($self) { return 1 }
    sub errstr ($self) { return '' }
}
{
    package SIDLegacyDatabase;
    use Mojo::Base -base, -signatures;
    has [qw(hits sid)];
    has validation_bt => 1;
    sub prepare ($self, $sql) { return SIDLegacyStatement->new(db => $self, sql => $sql) }
    sub errstr ($self) { return '' }
    sub update ($self, $sql) {
        $sql =~ /set sid = '([^']+)'/i or die "SQL inatteso: $sql";
        $self->sid($1);
    }
    sub do ($self, $sql) {
        die "SQL finale inatteso: $sql" unless $sql =~ /validation_bt = 1 AND pista IS NOT NULL AND sid IS NULL/;
        $self->sid('NA') if $self->validation_bt == 1 && !defined $self->sid;
        return 1;
    }
}

my $root = path($FindBin::Bin, '..', '..')->realpath;
my $source = $root->child('legacy', 'scripts', '07-assegna_sid_2.2_dal_2015_corr.pl')->slurp;
$source =~ s/\r\n/\n/g;
my (%runners, $serial);
sub legacy ($airport, $runway, $hits, $corrected = 0, $bt = 1) {
    my $key = "$airport:$corrected";
    unless ($runners{$key}) {
        $source =~ /(if \(\$aeroporto eq '\Q$airport\E'\)\s*\{.*?)(?=^#\*+ FINE ALGORITMO)/ms
            or die "Ramo SID non trovato: $airport";
        my $branch = $1;
        $branch =~ s/\$B220D\[0\]/\$B220[0]/g if $corrected;
        $source =~ /^(\$up_track3 = .*);$/m or die 'Update finale non trovato';
        my $final = "$1;\n\$db_radar->do(\$up_track3);";
        my $package = 'LegacySID' . ++$serial;
        my $ok = eval "package $package; no strict; no warnings; sub process { $branch\n$final }\n1;";
        die $@ unless $ok;
        $runners{$key} = $package;
    }
    my $package = $runners{$key};
    my $db = SIDLegacyDatabase->new(hits => $hits, validation_bt => $bt);
    {
        no strict 'refs';
        ${"${package}::aeroporto"} = $airport;
        ${"${package}::db_radar"} = $db;
        ${"${package}::selTh"} = SIDLegacyStatement->new(rows => [[1, $runway]]);
    }
    my $output = '';
    open my $capture, '>', \$output or die $!;
    local *STDOUT = $capture;
    {
        no strict 'refs';
        &{"${package}::process"}();
    }
    return $db->sid;
}

my %runways = (
    LIMC => {'070' => '35R', '071' => '35R', '358' => '35R',
        '280' => '35L', '310' => '35L', '320' => '35L', '294' => '17L', '038' => '17R'},
    LIML => {SRN5C => '36R', NIKMO => '36R', TZO5C => '36R', DORIN => '36R',
        PIKOT => '36R', PIA5D => '18L', SSUD => '18L'},
    LIME => {'267' => '29', '220' => '29', '044' => '29'},
);
my %polygons = (NIKMO => 'NIKMO5A', DORIN => 'DORIN5C');
my @fixtures;
for my $airport (qw(LIMC LIML LIME)) {
    for my $sid (sort keys %{$runways{$airport}}) {
        my $polygon = $polygons{$sid} // $sid;
        my @vertices;
        for my $letter ('A' .. 'D') {
            $source =~ /\@\Q$letter\E_?\Q$polygon\E=\(([\d.]+),([\d.]+)\)/ or die "Vertice $letter $polygon";
            push @vertices, [0 + $1, 0 + $2];
        }
        my $point = [0, 0, 1000];
        for my $v (@vertices) { $point->[$_] += $v->[$_] / 4 for 0, 1 }
        $point = [1526000, 5026000, 1000] if $sid eq 'PIA5D';
        push @fixtures, {airport => $airport, runway => $runways{$airport}{$sid},
            sid => $sid, hits => [[0, 0, 0], $point]};
    }
}

subtest 'caratterizzazione dei rami originali 2.2 corr' => sub {
    for my $fixture (@fixtures) {
        my $sid = legacy(@{$fixture}{qw(airport runway hits)});
        $fixture->{legacy} = $sid;
        is $sid, $fixture->{sid}, "$fixture->{airport} $fixture->{sid}: punto interno";
    }
    is legacy('LIMC', '17L', []), '168', 'fallback sud anche senza battute';
    is legacy('LIMC', '35R', [[1482000, 5056000, 1000]]), 'NA', 'prima battuta saltata';
    is legacy('LIME', '11', [[0, 0, 0], [0, 0, 9999]]), '150', 'pista 11 senza soglia geometrica o di quota';
    is legacy('LIML', '36R', [], 0, 2), undef, 'fallback NA globale riguarda solo bt=1';
    is legacy('LIML', '18L', [[0, 0, 0], [1524992.932, 5027165.656, 1000]]), 'NA',
        'PIA5D conserva le semirette legacy, non assume il centro dei vertici interno';
};

sub migrated ($airport, $runway, $hits, $bt = 1) {
    my $sid = ScriptManager::Service::SIDGeometry->analyze($airport, $runway, $hits);
    return !defined $sid && $bt == 1 ? 'NA' : $sid;
}

subtest 'geometria migrata confrontata ai rami legacy e correzione approvata' => sub {
    for my $fixture (@fixtures) {
        my ($airport, $runway, $hits) = @{$fixture}{qw(airport runway hits)};
        is migrated($airport, $runway, $hits), legacy($airport, $runway, $hits, 1),
            "$airport $fixture->{sid}: stessa assegnazione";
        my $height = $airport eq 'LIMC' ? 3000 : 3500;
        my $edge = [[0, 0, 0], [@{$hits->[1]}[0, 1], $height]];
        is migrated($airport, $runway, $edge), legacy($airport, $runway, $edge, 1),
            'quota esattamente sul limite esclusa';
        my $inside = [[0, 0, 0], [@{$hits->[1]}[0, 1], $height - 1]];
        is migrated($airport, $runway, $inside), $fixture->{sid}, 'quota appena sotto il limite ammessa';
        is migrated($airport, 'XX', $hits), legacy($airport, 'XX', $hits, 1), 'pista diversa non assegnata';
    }
    my $point = [[0, 0, 0], [1549000, 5056000, 1000]];
    is legacy('LIME', '29', $point), '220', 'refuso originale accetta punto sotto la retta BC corretta';
    is legacy('LIME', '29', $point, 1), 'NA', 'correzione circoscritta al denominatore BC';
    is migrated('LIME', '29', $point), 'NA', 'nuovo algoritmo usa B220, non una coordinata zero';
    my %mxp = map { $_->{sid} => $_->{hits}[1] } grep { $_->{airport} eq 'LIMC' } @fixtures;
    is migrated('LIMC', '35R', [[0,0,0], $mxp{'071'}, $mxp{'070'}]), '071',
        'precedenza temporale: prima battuta utile, non prima regola su tutta la traccia';
    is migrated('LIMC', '35R', [$mxp{'070'}]), 'NA', 'prima battuta ignorata anche se interna';
    is migrated('LIMC', '17R', []), '168', 'fallback sud conservato';
    is migrated('LIME', '11', [[0,0,0], [0,0,9999]]), '150';
    is migrated('LIML', '36R', [], 2), undef, 'esito NULL conservato per bt>1 senza match';
    eval { migrated('LIPO', '32', []) };
    ok(ScriptManager::Exception->caught($@, 'invalid_airport'), 'nessuna geometria inventata per Montichiari');
    eval { migrated('LIME', '11', [[0,0,0], [0,undef,300]]) };
    ok(ScriptManager::Exception->caught($@, 'invalid_hit'), 'dati numerici non validi espliciti');
};

{
    package SIDContext;
    use Mojo::Base -base, -signatures;
    has steps => sub { [] };
    has events => sub { [] };
    has cancel => 0;
    sub log ($self, @args) { push @{$self->events}, \@args }
    sub progress ($self, @args) { push @{$self->steps}, \@args }
    sub check_cancel ($self) {
        ScriptManager::Exception->throw('cancelled', 'Annullata') if $self->cancel;
    }
}
{
    package SIDDatabase;
    use Mojo::Base -base, -signatures;
    has [qw(ctx fail)];
    has tracks => sub { [[1, '11', 1], [2, '29', 1], [3, '29', 2]] };
    has writes => sub { [] };
    has disconnected => 0;
    sub selectall_arrayref ($self, $sql, $attributes, @bind) {
        if ($sql =~ /SELECT row_id, pista/) {
            Test::More::like($sql, qr/flay_operation = \? AND validation_bt > \?.*sid IS NULL/, 'filtro decolli bt>0, pista e SID NULL');
            Test::More::is_deeply(\@bind, ['D', 0], 'parametri SQL in lista');
            return $self->tracks;
        }
        if ($sql =~ /FROM battute/) {
            Test::More::is(scalar @{$self->writes}, 0, 'analisi prima delle scritture');
            Test::More::like($sql, qr/ORDER BY time_italy, row_id/, 'ordine deterministico');
            return [[0,0,0], [0,0,1000]];
        }
        die "report failed\n" if ($self->fail // '') eq 'report';
        Test::More::is($self->ctx->steps->[-1][0], 99, 'riepilogo al 99%');
        return [['150', 1], ['NA', 1]];
    }
    sub do ($self, $sql, $attributes, @bind) {
        Test::More::cmp_ok($self->ctx->steps->[-1][0], '>=', 50, 'scritture dal 50%');
        die "write failed\n" if ($self->fail // '') eq 'write';
        push @{$self->writes}, [$sql, \@bind];
        $self->ctx->cancel(1) if ($self->fail // '') eq 'cancel';
        return 1;
    }
    sub disconnect ($self) {
        Test::More::ok(!grep({ $_->[0] == 100 } @{$self->ctx->steps}), 'non concluso prima del disconnect');
        $self->disconnected(1);
        return 1;
    }
}

subtest 'runtime, progressione e fallimenti' => sub {
    local $ENV{MYSQL_HOST} = 'localhost';
    local $ENV{MYSQL_PORT} = 3306;
    local $ENV{MYSQL_USER} = 'test';
    local $ENV{MYSQL_PASSWORD} = 'test-password';
    for my $mode (qw(normal empty write report cancel)) {
        my $ctx = SIDContext->new;
        my $db = SIDDatabase->new(ctx => $ctx, fail => $mode);
        $db->tracks([]) if $mode eq 'empty';
        my $command = ScriptManager::Command::AssegnaSID->new(window_class => 'TestValidationWindow',
            connect_db => sub { $db });
        my $result = eval { $command->run($ctx, {database => 'radar_test', airport => 'LIME'}) };
        my $error = $@;
        if ($mode eq 'normal' || $mode eq 'empty') {
            ok $result->{success}, "$mode: successo";
            is $ctx->steps->[-1][0], 100;
            is_deeply $db->writes, $mode eq 'empty' ? [] : [
                ['UPDATE flay SET sid = ? WHERE row_id = ?', ['150', 1]],
                ['UPDATE flay SET sid = ? WHERE row_id = ?', ['NA', 2]],
            ], 'solo SID; bt>1 senza match rimane NULL';
        }
        else {
            ok $error, "$mode: errore propagato";
            ok !grep({ $_->[0] == 100 } @{$ctx->steps}), 'nessun falso 100%';
        }
        my @p = map { $_->[0] } @{$ctx->steps};
        ok !grep({ $p[$_] < $p[$_ - 1] } 1 .. $#p), 'progresso monotono';
        ok $db->disconnected, 'connessione chiusa';
    }
};

done_testing;
