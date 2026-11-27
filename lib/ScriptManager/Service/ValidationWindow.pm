package ScriptManager::Service::ValidationWindow;
use Mojo::Base -base, -signatures;

use Mojo::JSON 'false';
use Time::Piece;
use ScriptManager::Exception;

has [qw(db ctx params stage target)];
has days => sub { [] };
has skipped => sub { [] };

my %CODES = (3 => 'valida_tracce', 4 => 'valida_battute',
    5 => 'trova_pista_atterraggi', 6 => 'trova_pista_decolli', 7 => 'assegna_sid',
    8 => 'rettifica_quote', 10 => 'correggi_quote');

sub date_column ($self) { return $self->stage == 7 || $self->stage == 10 ? 'data_ora_arr' : 'data_ora_italy' }

sub configure_schema ($class, $schema) {
    for my $field (['date_from', 'Dal giorno (incluso)', 10], ['date_to', 'Al giorno (incluso)', 11]) {
        $schema->{properties}{$field->[0]} = {
            type => 'string', format => 'date', title => $field->[1], 'x-order' => $field->[2],
            pattern => '^[1-9][0-9]{3}-[0-9]{2}-[0-9]{2}$',
        };
    }
    $schema->{dependencies}{date_from} = ['date_to'];
    $schema->{dependencies}{date_to} = ['date_from'];
    $schema->{properties}{overwrite} = {
        type => 'boolean', default => false, 'x-order' => 12,
        title => 'Sovrascrivi e azzera i risultati dipendenti',
    };
}

sub validate_params ($class, $params) {
    my @dates = @{$params}{qw(date_from date_to)};
    ScriptManager::Exception->throw('invalid_date_range', 'Specificare entrambe le date oppure nessuna')
        if defined $dates[0] != defined $dates[1];
    for my $date (grep { defined } @dates) {
        my $valid = eval {
            $date =~ /\A[1-9]\d{3}-\d\d-\d\d\z/
                && Time::Piece->strptime($date, '%Y-%m-%d')->strftime('%Y-%m-%d') eq $date;
        };
        ScriptManager::Exception->throw('invalid_date_range', 'Data non valida: usare YYYY-MM-DD')
            unless $valid;
    }
    ScriptManager::Exception->throw('invalid_date_range', 'La data iniziale deve precedere o coincidere con quella finale')
        if defined $dates[0] && $dates[0] gt $dates[1];
}

sub overwrite ($self) { return $self->params->{overwrite} ? 1 : 0 }

sub prepare ($self) {
    __PACKAGE__->validate_params($self->params);
    die "Fase di validazione non valida\n" unless $CODES{$self->stage};
    $self->target(join ':', lc($ENV{MYSQL_HOST}), $ENV{MYSQL_PORT} // 3306, $self->params->{database});
    my $repo = $self->ctx->repo;
    my $date = $self->date_column;
    $self->ctx->validation_guard($repo->lock_validation_target($self->target));
    my ($where, @bind) = ("(validation_fl IS NULL OR validation_fl <> 'M')");
    if ($self->stage >= 5 && $self->stage <= 7) {
        $where .= ' AND flay_operation = ?';
        push @bind, $self->stage == 5 ? 'A' : 'D';
    }
    my ($missing) = $self->db->selectrow_array(
        "SELECT COUNT(*) FROM flay WHERE $where AND $date IS NULL", undef, @bind);
    $self->ctx->log(warning => "$missing tracce senza $date escluse") if $missing;
    if (defined $self->params->{date_from}) {
        $where .= " AND $date >= ? AND $date < DATE_ADD(?, INTERVAL 1 DAY)";
        push @bind, @{$self->params}{qw(date_from date_to)};
    }
    my $days = $self->db->selectcol_arrayref(
        "SELECT DISTINCT DATE($date) FROM flay WHERE $where AND $date IS NOT NULL ORDER BY 1",
        undef, @bind);
    my %completed = map { $_ => 1 } @{$repo->completed_validation_days($self->target, $CODES{$self->stage})};
    for my $day (@$days) {
        __PACKAGE__->validate_params({date_from => $day, date_to => $day});
        if (!$self->overwrite && $completed{$day}) {
            push @{$self->skipped}, $day;
            $self->ctx->log(info => "Skip $day: $CODES{$self->stage} gia completato con successo");
        }
        else { push @{$self->days}, $day }
    }
    $self->ctx->log(info => scalar(@{$self->days}) . ' giorni da elaborare; '
        . scalar(@{$self->skipped}) . ' giorni saltati'
        . ($self->overwrite ? '; sovrascrittura e azzeramento risultati dipendenti richiesti' : ''));
    if ($self->overwrite && ($self->stage == 5 || $self->stage == 6) && @{$self->days}) {
        my ($filter, @values) = $self->filter('f');
        my $bad = $self->db->selectcol_arrayref(
            'SELECT f.row_id FROM flay f LEFT JOIN battute b ON b.flay_id = f.row_id '
            . 'AND b.validation IN (?, ?) WHERE f.validation_fl = ? AND f.validation_bt = ? '
            . "AND f.pista LIKE ? $filter GROUP BY f.row_id HAVING COUNT(b.row_id) < 4",
            undef, 'Y', $self->stage == 5 ? 'X' : 'Y', 'P', 0, 'N%', @values);
        ScriptManager::Exception->throw('validation_state',
            'Impossibile ricostruire la validazione 04 per tracce invalidate dalle piste: meno di 4 battute valide')
            if @$bad;
    }
    return $self;
}

sub filter ($self, $alias = '', $include_non_operations = 0) {
    die "Alias SQL non valido\n" unless $alias =~ /\A(?:f)?\z/;
    return (' AND 1 = 0') unless @{$self->days};
    my $prefix = length $alias ? "$alias." : '';
    my $date = $self->date_column;
    my $sql = " AND (${prefix}validation_fl IS NULL OR ${prefix}validation_fl <> 'M')"
        . " AND DATE($prefix$date) IN (" . join(',', ('?') x @{$self->days}) . ')';
    my @bind = @{$self->days};
    if ($self->stage == 4 && !$include_non_operations) {
        $sql .= " AND (${prefix}flay_operation IS NULL OR BINARY ${prefix}flay_operation <> BINARY 'N')";
    }
    if ($self->stage >= 5 && $self->stage <= 7) {
        $sql .= " AND ${prefix}flay_operation = ?";
        push @bind, $self->stage == 5 ? 'A' : 'D';
    }
    return ($sql, @bind);
}

sub runway_candidates ($self, $alias = '') {
    die "Alias SQL non valido\n" unless $alias =~ /\A(?:f)?\z/;
    my $p = length $alias ? "$alias." : '';
    return "(${p}validation_bt IN (1, 2, 3) OR (${p}validation_fl = 'P' AND ${p}validation_bt = 0 AND ${p}pista LIKE 'N%'))";
}

sub start_saving ($self, $selected_tracks = undef) {
    return unless @{$self->days};
    $self->ctx->check_cancel;
    my @stages = $self->stage == 3 ? (3, 4, 5, 6) : $self->stage == 4 ? (4, 5, 6) : ($self->stage);
    $self->ctx->repo->invalidate_validation_days($self->target, [map { $CODES{$_} } @stages], $self->days);
    if ($self->stage <= 6) {
        $self->ctx->repo->invalidate_validation_days($self->target, [$CODES{8}], $self->days);
    }
    if ($self->stage == 3 || $self->stage == 4 || $self->stage == 6) {
        my ($filter, @bind) = $self->filter('f');
        my $sql = 'SELECT DISTINCT DATE(f.data_ora_arr) AS day FROM flay f '
            . "WHERE f.flay_operation = ? AND f.data_ora_arr IS NOT NULL $filter";
        my @values = ('D', @bind);
        if ($self->stage <= 4) {
            # 04 can move the departure date to any retained hit, even across midnight.
            $sql .= ' UNION SELECT DISTINCT DATE(b.time_italy) AS day FROM battute b '
                . 'JOIN flay f ON f.row_id = b.flay_id '
                . "WHERE f.flay_operation = ? AND b.time_italy IS NOT NULL $filter";
            push @values, 'D', @bind;
        }
        my $sid_days = $self->db->selectcol_arrayref($sql, undef, @values);
        $self->ctx->repo->invalidate_validation_days($self->target, [$CODES{7}], $sid_days);
    }
    if ($self->stage <= 6 || $self->stage == 8) {
        my ($filter, @bind) = $self->filter('f');
        my $sql = "SELECT DISTINCT DATE(f.data_ora_arr) FROM flay f WHERE f.data_ora_arr IS NOT NULL $filter";
        my @values = @bind;
        if ($self->stage <= 4) {
            $sql .= ' UNION SELECT DISTINCT DATE(b.time_italy) FROM battute b JOIN flay f ON f.row_id = b.flay_id '
                . "WHERE b.time_italy IS NOT NULL $filter";
            push @values, @bind;
        }
        my $days = $self->db->selectcol_arrayref($sql, undef, @values);
        $self->ctx->repo->invalidate_validation_days($self->target, [$CODES{10}], $days);
    }
    return unless $self->overwrite;
    return if $self->stage == 10; # Reset only analyzed, usable tracks inside the command, not skipped tracks.
    my ($filter, @bind) = $self->filter('f');
    my $db = $self->db;
    $self->ctx->log(warning => 'Azzeramento dei risultati dipendenti nei soli giorni selezionati; AutoCommit senza rollback');
    if ($self->stage == 4) {
        my $ids = $db->selectcol_arrayref('SELECT f.row_id FROM flay f WHERE 1=1'
            . $filter . q{ AND f.validation_fl IN ('Y','L','D','P') ORDER BY f.row_id}, undef, @bind);
        for (my $offset = 0; $offset < @$ids; $offset += 500) {
            $self->ctx->check_cancel;
            my $last = $offset + 499 < $#$ids ? $offset + 499 : $#$ids;
            my @batch = @$ids[$offset .. $last];
            $self->ctx->progress(50, 'Salvataggio: azzeramento battute, tracce '
                . ($offset + 1) . '-' . ($last + 1) . ' di ' . scalar(@$ids));
            $db->do('UPDATE battute SET A_m = NULL, Z_m = NULL, hmod = NULL, validation = NULL '
                . 'WHERE flay_id IN (' . join(',', ('?') x @batch) . ') '
                . 'AND (A_m IS NOT NULL OR Z_m IS NOT NULL OR hmod IS NOT NULL OR validation IS NOT NULL)',
                undef, @batch);
        }
        $self->ctx->check_cancel;
        $self->ctx->progress(50, 'Salvataggio: azzeramento stati, date, pista e SID delle tracce');
    }
    elsif ($self->stage == 8) {
        my $ids = $selected_tracks // $db->selectcol_arrayref(
            'SELECT f.row_id FROM flay f WHERE f.validation_bt IN (1, 2, 3) AND f.pista IS NOT NULL'
            . $filter . ' ORDER BY f.row_id', undef, @bind);
        for (my $offset = 0; $offset < @$ids; $offset += 500) {
            $self->ctx->check_cancel;
            my $last = $offset + 499 < $#$ids ? $offset + 499 : $#$ids;
            my @batch = @$ids[$offset .. $last];
            $self->ctx->progress(50, 'Salvataggio: azzeramento quote, tracce '
                . ($offset + 1) . '-' . ($last + 1) . ' di ' . scalar(@$ids));
            $db->do('UPDATE battute SET A_m = NULL, '
                . q{Z_m = CASE WHEN validation NOT IN ('N','A','S') THEN NULL ELSE Z_m END, }
                . q{hmod = CASE WHEN validation NOT IN ('N','A','S') THEN NULL ELSE hmod END }
                . 'WHERE flay_id IN (' . join(',', ('?') x @batch) . ') '
                . q{AND (A_m IS NOT NULL OR (validation NOT IN ('N','A','S') AND (Z_m IS NOT NULL OR hmod IS NOT NULL)))},
                undef, @batch);
        }
        $self->ctx->check_cancel;
    }
    elsif ($self->stage <= 6) {
        my $eligible = $self->stage == 5 || $self->stage == 6 ? ' AND ' . $self->runway_candidates('f')
            : '';
        $db->do('UPDATE battute b JOIN flay f ON f.row_id = b.flay_id SET b.A_m = NULL '
            . "WHERE 1=1 $filter $eligible", undef, @bind);
        $self->ctx->check_cancel;
        $db->do('UPDATE battute b JOIN flay f ON f.row_id = b.flay_id SET b.Z_m = NULL, b.hmod = NULL '
            . "WHERE 1=1 $filter $eligible", undef, @bind);
        $self->ctx->check_cancel;
    }
    if ($self->stage <= 4) {
        $filter .= q{ AND f.validation_fl IN ('Y','L','D','P')} if $self->stage == 4;
        $db->do('UPDATE battute b JOIN flay f ON f.row_id = b.flay_id SET b.validation = NULL WHERE 1=1'
            . $filter, undef, @bind) if $self->stage == 3;
        $self->ctx->check_cancel;
        $db->do('UPDATE flay f SET f.validation_fl = ' . ($self->stage == 3 ? 'NULL' : "'Y'")
            . ', f.validation_bt = NULL, f.data_ora_arr = NULL, f.pista = NULL, f.sid = NULL WHERE 1=1'
            . $filter, undef, @bind);
    }
    elsif ($self->stage == 7) {
        $db->do('UPDATE flay f SET f.sid = NULL WHERE f.validation_bt > ? AND f.pista IS NOT NULL'
            . $filter, undef, 0, @bind);
    }
    elsif ($self->stage == 8) {
        $db->do('UPDATE flay f SET f.validation_bt = 1 WHERE f.validation_bt IN (2, 3) AND f.pista IS NOT NULL'
            . $filter, undef, @bind);
    }
    else {
        my $eligible = $self->runway_candidates('f');
        $db->do('UPDATE flay f LEFT JOIN (SELECT flay_id, COUNT(*) AS n FROM battute '
            . 'WHERE validation IN (?, ?) GROUP BY flay_id) b ON b.flay_id = f.row_id '
            . "SET f.validation_fl = CASE WHEN f.validation_fl = 'P' THEN IF(b.n < 8, 'L', 'Y') "
            . 'ELSE f.validation_fl END, f.validation_bt = 1, f.pista = NULL, f.sid = NULL '
            . "WHERE $eligible $filter", undef, 'Y', $self->stage == 5 ? 'X' : 'Y', @bind);
        if ($self->stage == 5) {
            $self->ctx->check_cancel;
            $db->do('UPDATE battute b JOIN flay f ON f.row_id = b.flay_id SET b.validation = ? '
                . "WHERE b.validation = ? AND f.validation_bt = 1 $filter", undef, 'Y', 'X', @bind);
        }
    }
}

sub finish ($self, $result) {
    $self->ctx->check_cancel;
    my %incomplete = $self->stage == 10 ? map { $_ => 1 } @{$result->{data}{incomplete_days} // []} : ();
    my @completed = grep { !$incomplete{$_} } @{$self->days};
    $self->ctx->repo->complete_validation_days(
        $self->target, $CODES{$self->stage}, \@completed, $self->ctx->execution_id);
    $result->{data}{days_processed} = $self->days;
    $result->{data}{days_skipped} = $self->skipped;
    $result->{message} .= '; ' . scalar(@{$self->skipped}) . ' giorni saltati' if @{$self->skipped};
    return $result;
}

1;
