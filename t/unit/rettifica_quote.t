use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File 'path';
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestValidationWindow;
use ScriptManager::Command::RettificaQuote;

{
    package HeightLegacyStatement;
    use Mojo::Base -base, -signatures;
    has [qw(db sql rows)];
    sub execute ($self, @bind) {
        if ($self->sql =~ /SELECT row_id FROM flay/) { $self->rows([[1]]) }
        elsif ($self->sql =~ /SELECT row_id,X_m/) { $self->rows([map { [@$_] } @{$self->db->hits}]) }
        elsif ($self->sql =~ /SET validation_bt = 2/) { $self->db->completed(1) }
        elsif ($self->sql =~ /SET Z_m\s*=\s*([^,]+),\s*hmod\s*=\s*'M' WHERE row_id\s*=\s*(\d+)/i) {
            my ($z, $id) = ($1, $2);
            die "Quota SQL vuota\n" unless $z =~ /\S/;
            $self->db->updates->{$id} = 0 + $z;
        }
        else { die "SQL inatteso: " . $self->sql }
        return 1;
    }
    sub fetchrow_array ($self) { return @{shift @{$self->rows} // []} }
    sub fetchall_arrayref ($self) { return $self->rows }
    sub finish ($self) { return 1 }
}
{
    package HeightLegacyDatabase;
    use Mojo::Base -base, -signatures;
    has 'hits';
    has updates => sub { {} };
    has completed => 0;
    sub prepare ($self, $sql) { return HeightLegacyStatement->new(db => $self, sql => $sql) }
}

my $source = path($FindBin::Bin, '..', '..', 'legacy', 'scripts',
    '08-rettifica_quote_nulle_1.1.pl')->slurp;
$source =~ s/\r\n/\n/g;
$source =~ /(\$sel_on_flay = .*?)^\$sel_flay_h->finish;/ms or die 'Ciclo legacy non trovato';
my $loop = $1;
$source =~ /(sub distanza2.*)/s or die 'Distanza legacy non trovata';
my $distance = $1;
my $serial = 0;
sub legacy ($hits) {
    my $package = 'LegacyHeight' . ++$serial;
    my $ok = eval "package $package; no strict; no warnings; $distance\nsub process { $loop }\n1;";
    die $@ unless $ok;
    my $db = HeightLegacyDatabase->new(hits => $hits);
    {
        no strict 'refs';
        ${"${package}::db_radar"} = $db;
    }
    my $output = '';
    open my $capture, '>', \$output or die $!;
    local *STDOUT = $capture;
    {
        no strict 'refs';
        local *{"${package}::FILEOUTPUT"} = $capture;
        &{"${package}::process"}();
    }
    return $db;
}

sub hits (@heights) { return [map { [$_ + 1, 10 * $_, 0, $heights[$_], 'Y', undef] } 0 .. $#heights] }

subtest 'caratterizzazione del ciclo originale 1.1 senza scritture operative' => sub {
    my $r = legacy(hits(100, 0, 300, 400));
    is_deeply $r->updates, {2 => 200}, 'interpolazione con ancore interne';
    ok $r->completed, 'avanza validation_bt a 2';
    is_deeply legacy(hits(0, 100, 200))->updates, {1 => 0}, 'estrapolazione iniziale e limite zero';
    is_deeply legacy(hits(100, 200, 0))->updates, {3 => 300}, 'estrapolazione finale';
    is_deeply legacy(hits(100, 0, 300))->updates, {2 => 0},
        'difetto verificato: ultima battuta non usata come ancora successiva';
    eval { legacy(hits(0, 0, 0)) };
    like "$@", qr/Quota SQL vuota|SQL inatteso: UPDATE battute/,
        'difetto verificato: tutte zero genera UPDATE senza quota';
    is_deeply legacy(hits(100, 200, 300))->updates, {}, 'codice non copia H_m in Z_m';
    ok !legacy(hits(100, 200))->completed, 'meno di tre battute: traccia non avanzata';
    my $h = hits(100, 0, 300, 400);
    $h->[1][5] = 'M';
    is_deeply legacy($h)->updates, {}, 'hmod M non viene rielaborato';
};

sub migrated ($heights) { return ScriptManager::Command::RettificaQuote->analyze($heights) }

subtest 'calcolo migrato: parita nei casi definiti e correzioni approvate' => sub {
    for my $heights ([100, 0, 300, 400], [0, 100, 200], [100, 200, 0]) {
        my $h = hits(@$heights);
        my $original = legacy($h)->updates;
        my %interpolated = map { $_->[0] => $_->[1] }
            grep { ($_->[2] // '') eq 'M' } @{migrated($h)->{updates}};
        is_deeply \%interpolated, $original, 'stesso risultato del legacy nei casi con ancore definite';
    }
    is_deeply migrated(hits(100, 0, 300))->{updates},
        [[1, 100, undef], [2, 200, 'M'], [3, 300, undef]],
        'ultima ancora inclusa e quote originali copiate senza hmod M';
    my $r = migrated(hits(0, 0, 200, 0, 400, 0, 0));
    is_deeply [map { $_->[1] } @{$r->{updates}}], [0, 100, 200, 300, 400, 500, 600],
        'zeri consecutivi agli estremi e interni; nessuna propagazione delle quote calcolate';
    $r = migrated(hits(0, 250, 0));
    is_deeply [map { $_->[1] } @{$r->{updates}}], [250, 250, 250], 'una sola ancora: quota costante';
    is scalar @{$r->{warnings}}, 2, 'fallback segnalati';
    like migrated(hits(0, 0, 0))->{reason}, qr/tutte le quote/, 'nessuna ancora: nessuna quota inventata';
    like migrated(hits(100, 200))->{reason}, qr/meno di tre/, 'minimo legacy conservato';
    my $h = hits(100, 0, 300);
    $h->[1][5] = 'M';
    is_deeply migrated($h)->{updates}, [[1, 100, undef], [3, 300, undef]], 'rispetta hmod M';
    $h = hits(100, 0, 300);
    $_->[1] = 0 for @$h;
    is_deeply migrated($h)->{updates}[1], [2, 100, 'M'], 'distanza nulla: ancora precedente';
    like migrated($h)->{warnings}[0], qr/distanza nulla/, 'distanza nulla segnalata';
    $h = hits(100, 0, 300);
    $h->[1][1] = undef;
    eval { migrated($h) };
    ok(ScriptManager::Exception->caught($@, 'invalid_hit'), 'valori numerici mancanti rifiutati');
    $h->[1][1] = 'NaN';
    eval { migrated($h) };
    ok(ScriptManager::Exception->caught($@, 'invalid_hit'), 'NaN rifiutato');
};

{
    package HeightContext;
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
    package HeightDatabase;
    use Mojo::Base -base, -signatures;
    has tracks => sub { [1] };
    has hits => sub { main::hits(100, 0, 300) };
    has writes => sub { [] };
    has closed => 0;
    has fail => 0;
    sub selectcol_arrayref ($self, @args) { return $self->tracks }
    sub selectall_arrayref ($self, $sql, @args) {
        return [] if $sql =~ /COUNT/;
        return [map { [@$_] } @{$self->hits}];
    }
    sub do ($self, @args) {
        die "write failed\n" if $self->fail;
        push @{$self->writes}, \@args;
        return 1;
    }
    sub disconnect ($self) { $self->closed(1); return 1 }
}

subtest 'runtime: progresso completo, errori e annullamento senza falso successo' => sub {
    local @ENV{qw(MYSQL_HOST MYSQL_USER MYSQL_PASSWORD)} = ('mysql.test', 'test', 'test');
    my $run = sub ($db, $ctx) {
        return ScriptManager::Command::RettificaQuote->new(connect_db => sub { $db },
            window_class => 'TestValidationWindow')->run($ctx, {database => 'radar_test'});
    };
    my $db = HeightDatabase->new;
    my $ctx = HeightContext->new;
    my $r = $run->($db, $ctx);
    is_deeply [@{$r->{data}}{qw(tracks interpolated copied skipped_tracks)}], [1, 1, 2, 0];
    is scalar @{$db->writes}, 4, 'tre quote e un aggiornamento di stato';
    is_deeply $db->writes->[1], [
        'UPDATE battute SET Z_m = ?, hmod = ? WHERE row_id = ? AND flay_id = ?', undef, 200, 'M', 2, 1],
        'quote parametrizzate e confinate alla traccia';
    is_deeply $db->writes->[-1], [
        'UPDATE flay SET validation_bt = ? WHERE row_id = ?', undef, 2, 1], 'stato aggiornato dopo le battute';
    is_deeply [map { $_->[0] } @{$ctx->steps}], [0, 50, 50, 62, 74, 86, 99, 99, 100];
    ok $db->closed, 'connessione chiusa';
    for my $case ('empty', 'allzero', 'fail', 'invalid', 'cancel') {
        $db = HeightDatabase->new;
        $ctx = HeightContext->new;
        $db->tracks([]) if $case eq 'empty';
        $db->hits(hits(0, 0, 0)) if $case eq 'allzero';
        $db->fail(1) if $case eq 'fail';
        $db->hits->[1][3] = undef if $case eq 'invalid';
        $ctx->cancel(1) if $case eq 'cancel';
        my $result = eval { $run->($db, $ctx) };
        my $error = $@;
        if ($case eq 'empty' || $case eq 'allzero') {
            ok $result->{success}, "$case: termina con conteggio esplicito";
            is scalar @{$db->writes}, 0, 'nessuna scrittura su tracce non rettificabili';
            is $result->{data}{skipped_tracks}, $case eq 'allzero' ? 1 : 0;
            ok grep({ $_->[1] =~ /non rettificata/ } @{$ctx->events}), 'avviso esplicito' if $case eq 'allzero';
        }
        else {
            ok $error, "$case: errore propagato";
            ok !grep({ $_->[0] == 100 } @{$ctx->steps}), 'non dichiara completamento';
        }
        ok $db->closed, "$case: connessione chiusa";
    }
};

done_testing;
