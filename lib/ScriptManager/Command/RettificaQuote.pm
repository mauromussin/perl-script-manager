package ScriptManager::Command::RettificaQuote;
use Mojo::Base -base, -signatures;

use DBI;
use POSIX 'isfinite';
use Scalar::Util 'looks_like_number';
use ScriptManager::Exception;
use ScriptManager::Service::ValidationWindow;

has [qw(logger process_runner)];
has connect_db => sub { sub (@args) { DBI->connect(@args) } };
has window_class => 'ScriptManager::Service::ValidationWindow';

sub configure_schema ($class, $schema, $directory) {
    ScriptManager::Service::ValidationWindow->configure_schema($schema);
    $schema->{properties}{overwrite}{title} = 'Ricalcola Z_m e hmod dalle quote originali';
}

sub analyze ($class, $hits, $ctx = undef) {
    return {updates => [], reason => 'meno di tre battute ammesse'} if @$hits < 3;
    my @anchors;
    for my $i (0 .. $#$hits) {
        $ctx->check_cancel if $ctx;
        for my $value (@{$hits->[$i]}[1 .. 3]) {
            ScriptManager::Exception->throw('invalid_hit', 'Coordinate o quota mancanti, non numeriche o non finite')
                unless defined $value && looks_like_number($value) && isfinite($value);
        }
        push @anchors, $i if $hits->[$i][3] != 0;
    }
    return {updates => [], reason => 'tutte le quote H_m sono zero'} unless @anchors;
    my (@updates, @warnings, $interpolated, $copied, $cursor);
    ($interpolated, $copied, $cursor) = (0, 0, 0);
    for my $i (0 .. $#$hits) {
        $ctx->check_cancel if $ctx;
        my $hit = $hits->[$i];
        next if ($hit->[5] // '') eq 'M';
        if ($hit->[3] != 0) {
            push @updates, [$hit->[0], $hit->[3], undef];
            $copied++;
            next;
        }
        $cursor++ while $cursor < @anchors && $anchors[$cursor] < $i;
        my $z;
        if (@anchors == 1) {
            $z = $hits->[$anchors[0]][3];
            push @warnings, "battuta $hit->[0]: una sola quota disponibile, usata costante";
        }
        else {
            my ($a, $b, $exterior) = $cursor == 0 ? ($anchors[0], $anchors[1], -1)
                : $cursor == @anchors ? ($anchors[-1], $anchors[-2], 1)
                : ($anchors[$cursor - 1], $anchors[$cursor], 0);
            my ($first, $second) = @$hits[$a, $b];
            my $s = _distance($hit, $first);
            my $denominator = $exterior ? _distance($first, $second) : $s + _distance($hit, $second);
            if ($denominator == 0) {
                $z = $first->[3];
                push @warnings, "battuta $hit->[0]: distanza nulla, usata quota dell'ancora";
            }
            elsif ($exterior) {
                $z = $first->[3] + $s / $denominator * ($first->[3] - $second->[3]);
            }
            else {
                $z = $first->[3] + $s / $denominator * ($second->[3] - $first->[3]);
            }
        }
        ScriptManager::Exception->throw('invalid_hit', 'Quota interpolata non finita') unless isfinite($z);
        $z = 0 if $z < 0;
        push @updates, [$hit->[0], $z, 'M'];
        $interpolated++;
    }
    return {updates => \@updates, interpolated => $interpolated, copied => $copied, warnings => \@warnings};
}

sub _distance ($a, $b) {
    return sqrt(($a->[1] - $b->[1]) ** 2 + ($a->[2] - $b->[2]) ** 2);
}

sub run ($self, $ctx, $params) {
    ScriptManager::Service::ValidationWindow->validate_params($params);
    ScriptManager::Exception->throw('invalid_database', 'Nome database MySQL non valido')
        unless ($params->{database} // '') =~ /\A[A-Za-z0-9_]{1,64}\z/;
    for my $key (qw(MYSQL_HOST MYSQL_USER MYSQL_PASSWORD)) {
        ScriptManager::Exception->throw('mysql_config', "Configurazione $key mancante")
            unless defined $ENV{$key} && length $ENV{$key};
    }
    my $port = $ENV{MYSQL_PORT} // 3306;
    ScriptManager::Exception->throw('mysql_config', 'Host o porta MySQL non validi')
        unless $ENV{MYSQL_HOST} =~ /\A[A-Za-z0-9.:-]+\z/ && $port =~ /\A\d+\z/ && $port > 0 && $port <= 65535;
    $ctx->progress(0, 'Analisi: lettura tracce per rettifica quote');
    my $db;
    my $connected = eval {
        $db = $self->connect_db->(
            "DBI:MariaDB:database=$params->{database};host=$ENV{MYSQL_HOST};port=$port",
            $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD},
            {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_auto_reconnect => 0});
        1;
    };
    my $error = $@;
    unless ($connected && $db) {
        die $error if ScriptManager::Exception->caught($error);
        die $error if !$connected && !defined $DBI::err;
        ScriptManager::Exception->throw('mysql_connect',
            'Connessione MySQL fallita: verificare host, porta, credenziali e database');
    }
    my ($result, $window);
    my $ok = eval {
        $window = $self->window_class->new(db => $db, ctx => $ctx, params => $params, stage => 8)->prepare;
        my ($filter, @bind) = $window->filter;
        $ctx->log(info => 'Rettifica quote 1.1 con correzioni approvate; arrivi e decolli; '
            . 'date su data_ora_italy; AutoCommit senza rollback');
        my $tracks = $db->selectcol_arrayref(
            'SELECT row_id FROM flay WHERE ' . ($window->overwrite ? 'validation_bt IN (1, 2, 3)' : 'validation_bt = 1')
            . ' AND pista IS NOT NULL' . $filter . ' ORDER BY row_id', undef, @bind);
        my (@plans, $analyzed, $skipped, $operations, $interpolated, $copied, $last_analysis);
        ($analyzed, $skipped, $operations, $interpolated, $copied, $last_analysis) = (0, 0, 0, 0, 0, 0);
        for my $id (@$tracks) {
            $ctx->check_cancel;
            my $hits = $db->selectall_arrayref(
                'SELECT row_id, X_m, Y_m, H_m, validation, hmod FROM battute WHERE flay_id = ? '
                . 'AND validation NOT IN (?, ?, ?) ORDER BY time_italy, row_id', undef, $id, 'N', 'A', 'S');
            if ($window->overwrite) { $_->[5] = undef for @$hits }
            my $plan = __PACKAGE__->analyze($hits, $ctx);
            if ($plan->{reason}) {
                $skipped++;
                $ctx->log(warning => "Traccia $id non rettificata: $plan->{reason}");
            }
            else {
                push @plans, {id => $id, %$plan};
                $operations += @{$plan->{updates}} + 1;
                $interpolated += $plan->{interpolated};
                $copied += $plan->{copied};
                $ctx->log(warning => "Traccia $id: $_") for @{$plan->{warnings}};
            }
            $analyzed++;
            my $percent = int(50 * $analyzed / @$tracks);
            $ctx->progress($percent, "Analisi: $analyzed di " . scalar(@$tracks) . ' tracce')
                if $percent != $last_analysis;
            $last_analysis = $percent;
        }
        $ctx->progress(50, 'Salvataggio: quote Z_m, hmod e stati tracce');
        $window->start_saving;
        my ($saved, $last_percent) = (0, 50);
        my $advance = sub {
            my $percent = 50 + int(49 * $saved / $operations);
            $ctx->progress($percent, "Salvataggio: $saved di $operations operazioni") if $percent != $last_percent;
            $last_percent = $percent;
        };
        for my $plan (@plans) {
            for my $update (@{$plan->{updates}}) {
                $ctx->check_cancel;
                $db->do('UPDATE battute SET Z_m = ?, hmod = ? WHERE row_id = ? AND flay_id = ?',
                    undef, $update->[1], $update->[2], $update->[0], $plan->{id});
                $saved++;
                $advance->();
            }
            $ctx->check_cancel;
            $db->do('UPDATE flay SET validation_bt = ? WHERE row_id = ?', undef, 2, $plan->{id});
            $saved++;
            $advance->();
        }
        $ctx->check_cancel;
        $ctx->progress(99, 'Riepilogo finale delle quote');
        my $report = $db->selectall_arrayref(
            'SELECT validation_bt, COUNT(*) FROM flay WHERE pista IS NOT NULL'
            . $filter . ' GROUP BY validation_bt', undef, @bind);
        $ctx->log(info => 'Riepilogo validation_bt ' . ($_->[0] // 'NULL') . ": $_->[1]") for @$report;
        $result = {
            success => 1,
            message => scalar(@plans) . " tracce rettificate, $interpolated quote interpolate, "
                . "$copied quote copiate, $skipped tracce non rettificabili",
            data => {tracks => scalar(@plans), interpolated => $interpolated,
                copied => $copied, skipped_tracks => $skipped, report => $report},
        };
        1;
    };
    $error = $@;
    unless ($ok) {
        $ctx->log(error => 'Rettifica quote interrotta; eventuali scritture gia eseguite non sono annullate');
        my $closed = eval { $db->disconnect; 1 };
        $ctx->log(error => 'Chiusura della connessione MySQL fallita') unless $closed;
        die $error;
    }
    $db->disconnect;
    $window->finish($result);
    $ctx->progress(100, 'Rettifica quote conclusa');
    return $result;
}

1;
