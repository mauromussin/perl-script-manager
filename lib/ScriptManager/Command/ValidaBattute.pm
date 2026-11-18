package ScriptManager::Command::ValidaBattute;
use Mojo::Base -base, -signatures;

use DBI;
use Scalar::Util 'looks_like_number';
use POSIX 'isfinite';
use ScriptManager::Exception;
use ScriptManager::Service::ValidationWindow;

has [qw(logger process_runner)];
has connect_db => sub { sub (@args) { DBI->connect(@args) } };
has window_class => 'ScriptManager::Service::ValidationWindow';

sub configure_schema ($class, $schema, $directory) {
    ScriptManager::Service::ValidationWindow->configure_schema($schema);
}

sub _distance ($a, $b, $three_d = 0) {
    return sqrt(($a->[2] - $b->[2])**2 + ($a->[3] - $b->[3])**2
        + ($three_d ? ($a->[4] - $b->[4])**2 : 0));
}

# Rows: row_id, UNIX_TIMESTAMP(time_italy), X_m, Y_m, H_m, validation.
sub analyze_track ($class, $hits, $operation, $ctx = undef) {
    ScriptManager::Exception->throw('invalid_operation', 'Validazione battute: operazione diversa da A/D')
        unless defined $operation && $operation =~ /\A[AD]\z/;
    my %flags;
    for my $hit (@$hits) {
        ScriptManager::Exception->throw('invalid_hit', 'Battuta con identificatore, tempo, coordinate o quota non validi')
            unless @$hit == 6 && !grep {
                !defined $_ || ref $_ || !looks_like_number($_) || !isfinite(0 + $_)
            } @$hit[0 .. 4];
        ScriptManager::Exception->throw('invalid_hit', 'Battuta con identificatore duplicato o quota negativa')
            if exists $flags{$hit->[0]} || $hit->[4] < 0;
        $flags{$hit->[0]} = $hit->[5];
    }

    for my $i (1 .. $#$hits) {
        $ctx->check_cancel if $ctx;
        my $dt = abs($hits->[$i][1] - $hits->[$i - 1][1]);
        if ($dt == 0 || _distance($hits->[$i], $hits->[$i - 1]) / $dt < 28) {
            $flags{$hits->[$i][0]} = 'T';
            $flags{$hits->[0][0]} = 'T' if $i == 1;
        }
    }

    my @ordered = sort {
        $a->[1] <=> $b->[1] || $a->[0] <=> $b->[0]
    } grep { !defined $flags{$_->[0]} } @$hits;
    @ordered = reverse @ordered if $operation eq 'A';
    for my $i (1 .. $#ordered) {
        if (abs($ordered[$i][1] - $ordered[$i - 1][1]) > 60) {
            $flags{$ordered[$_][0]} = 'S' for $i .. $#ordered;
            last;
        }
    }

    my @candidates = grep { !defined $flags{$_->[0]} } @$hits;
    my (@valid, @invalid);
    my $first;
    SEED: for my $m (0 .. $#candidates - 4) {
        for my $i ($m + 1 .. $#candidates - 3) {
            $ctx->check_cancel if $ctx;
            my ($a, $b) = @candidates[$m, $i];
            if ($i == $m + 1 && $a->[2] == $b->[2] && $a->[3] == $b->[3] && $a->[4] == $b->[4]) {
                push @invalid, $m;
                next SEED;
            }
            my @dt = ($b->[1] - $a->[1], map {
                $candidates[$_ + 1][1] - $candidates[$_][1]
            } $i .. $i + 2);
            next unless $dt[0] * $dt[1] * $dt[2] * $dt[3] > 0;
            next if grep {
                _distance($candidates[$i + $_], $candidates[$i + $_ + 1]) / $dt[$_ + 1] >= 500
            } 0 .. 2;
            if (_distance($a, $b) / $dt[0] > 500) {
                push @invalid, $m;
                next SEED;
            }
            $first = $m;
            push @valid, $m;
            last SEED;
        }
    }

    if (defined $first) {
        for my $i ($first + 1 .. $#candidates) {
            $ctx->check_cancel if $ctx;
            my ($a, $b) = @candidates[$valid[-1], $i];
            my $dt = $b->[1] - $a->[1];
            my $distance = _distance($a, $b);
            my $reject = $dt == 0 || $distance == 0;
            $reject ||= _distance($a, $b, $b->[4] > 0) / $dt > 500 unless $reject;
            if (!$reject && @valid >= 2) {
                my $previous = $candidates[$valid[-2]];
                my $cosine = (($a->[2] - $previous->[2]) * ($b->[2] - $a->[2])
                    + ($a->[3] - $previous->[3]) * ($b->[3] - $a->[3]))
                    / (_distance($a, $previous) * $distance);
                $reject = $cosine < 0.5;
            }
            push @{$reject ? \@invalid : \@valid}, $i;
        }
    }
    else {
        @invalid = (0 .. $#candidates);
    }
    $flags{$candidates[$_][0]} = 'N' for @invalid;
    my $valid_flag = @valid < 4 ? 'D' : 'Y';
    $flags{$candidates[$_][0]} = $valid_flag for @valid;
    return {
        flags => \%flags,
        validation_fl => @valid < 4 ? 'D' : @valid < 8 ? 'L' : 'Y',
        validation_bt => @valid >= 4 ? 1 : 0,
    };
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
    $ctx->progress(0, 'Analisi: connessione e lettura delle tracce');
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
            'Connessione MySQL fallita: verificare MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD e database');
    }
    my $result;
    my $window;
    my $ok = eval {
        $window = $self->window_class->new(db => $db, ctx => $ctx, params => $params, stage => 4)->prepare;
        my ($filter, @scope_bind) = $window->filter;
        my $tracks = $db->selectall_arrayref(
            'SELECT row_id, flay_operation FROM flay WHERE '
            . ($window->overwrite ? q{validation_fl IN ('Y','L','D','P')} : 'validation_bt IS NULL AND validation_fl = ?')
            . $filter . ' ORDER BY row_id', undef, ($window->overwrite ? () : ('Y')), @scope_bind);
        ScriptManager::Exception->throw('invalid_operation',
            'Sono presenti tracce da validare con operazione diversa da A/D; nessuna modifica eseguita')
            if grep { !defined $_->[1] || $_->[1] !~ /\A[AD]\z/ } @$tracks;
        $ctx->log(info => scalar(@$tracks) . ' tracce da analizzare; salvataggio in AutoCommit, senza rollback');
        my (@plans, $analyzed);
        $analyzed = 0;
        for my $track (@$tracks) {
            $ctx->check_cancel;
            my $hits = $db->selectall_arrayref(
                'SELECT row_id, UNIX_TIMESTAMP(time_italy), X_m, Y_m, H_m, validation FROM battute WHERE flay_id = ? ORDER BY row_id',
                undef, $track->[0]);
            my $input = $window->overwrite ? [map { [@$_[0 .. 4], undef] } @$hits] : $hits;
            my $plan = __PACKAGE__->analyze_track($input, $track->[1], $ctx);
            my %updates;
            for my $hit (@$hits) {
                my $flag = $plan->{flags}{$hit->[0]};
                push @{$updates{$flag}}, $hit->[0]
                    if defined $flag && ($window->overwrite || !defined $hit->[5] || $flag ne $hit->[5]);
            }
            delete $plan->{flags};
            $plan->{id} = $track->[0];
            $plan->{updates} = \%updates;
            push @plans, $plan;
            $analyzed++;
            $ctx->progress(int(50 * $analyzed / (@$tracks || 1)),
                "Analisi: $analyzed di " . scalar(@$tracks) . ' tracce');
        }

        my ($saved, $last_percent) = (0, 50);
        my $units = 2;
        for my $plan (@plans) {
            $units++;
            $units += int((@$_ + 499) / 500) for values %{$plan->{updates}};
        }
        my $advance = sub ($step) {
            my $percent = 50 + int(49 * $saved / $units);
            $ctx->progress($percent, $step) if $percent != $last_percent || $saved == 0;
            $last_percent = $percent;
        };
        $advance->('Salvataggio: classificazioni delle battute e delle tracce');
        $window->start_saving;
        for my $plan (@plans) {
            for my $flag (sort keys %{$plan->{updates}}) {
                my @ids = @{$plan->{updates}{$flag}};
                while (@ids) {
                    $ctx->check_cancel;
                    my @batch = splice @ids, 0, 500;
                    $db->do('UPDATE battute SET validation = ? WHERE row_id IN ('
                        . join(',', ('?') x @batch) . ')', undef, $flag, @batch);
                    $saved++;
                    $advance->("Salvataggio: traccia $plan->{id}, battute $flag ($saved di $units operazioni)");
                }
            }
            $ctx->check_cancel;
            $db->do('UPDATE flay SET validation_fl = ?, validation_bt = ? WHERE row_id = ?',
                undef, @{$plan}{qw(validation_fl validation_bt id)});
            $saved++;
            $advance->("Salvataggio: traccia $plan->{id} ($saved di $units operazioni)");
        }
        for my $operation ('D', 'A') {
            $ctx->check_cancel;
            my $aggregate = $operation eq 'D' ? 'MIN' : 'MAX';
            $ctx->progress(50 + int(49 * $saved / $units),
                "Salvataggio: data_ora_arr per " . ($operation eq 'D' ? 'decolli' : 'atterraggi'));
            my ($date_filter, @date_bind) = $window->filter('f');
            $db->do("UPDATE flay f JOIN (SELECT flay_id, $aggregate(time_italy) AS data_ora "
                . 'FROM battute WHERE validation IN (?, ?) GROUP BY flay_id) t ON f.row_id = t.flay_id '
                . 'SET f.data_ora_arr = t.data_ora WHERE f.flay_operation = ? AND f.validation_bt = ? '
                . 'AND f.data_ora_arr IS NULL' . $date_filter, undef, 'Y', 'L', $operation, 1, @date_bind);
            $saved++;
            $advance->("Salvataggio: $saved di $units operazioni");
        }
        $ctx->check_cancel;
        $ctx->progress(99, 'Riepilogo finale della validazione battute');
        my ($report_filter, @report_bind) = $window->filter('f');
        my $report = $db->selectall_arrayref(
            'SELECT validation, COUNT(*) FROM battute b JOIN flay f ON f.row_id = b.flay_id WHERE 1=1'
            . $report_filter . ' GROUP BY validation', undef, @report_bind);
        for my $row (@$report) {
            $ctx->log(info => 'Stato complessivo battute ' . ($row->[0] // 'NULL') . ": $row->[1]");
        }
        $result = {
            success => 1,
            message => 'Validazione battute completata: ' . scalar(@plans) . ' tracce elaborate',
            data => {tracks => scalar(@plans), report => $report},
        };
        1;
    };
    $error = $@;
    if (!$ok) {
        $ctx->log(error => 'Validazione battute interrotta; eventuali scritture gia eseguite non sono annullate');
        my $closed = eval { $db->disconnect; 1 };
        $ctx->log(error => 'Chiusura della connessione MySQL fallita') unless $closed;
        die $error;
    }
    $db->disconnect;
    $window->finish($result);
    $ctx->progress(100, 'Validazione battute conclusa');
    return $result;
}

1;
