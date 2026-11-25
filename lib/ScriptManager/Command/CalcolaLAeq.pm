package ScriptManager::Command::CalcolaLAeq;
use Mojo::Base -base, -signatures;

use Mojo::JSON 'encode_json';
use POSIX 'strftime';
use Time::Local 'timegm';
use ScriptManager::Exception;
use ScriptManager::Service::CorrelazioneSetup;
use ScriptManager::Service::EventiCMP;
use ScriptManager::Service::LAeqSetup;
use ScriptManager::Service::ValidationWindow;

has [qw(logger process_runner)];
has eventi => sub { ScriptManager::Service::EventiCMP->new };

sub run ($self, $ctx, $params) {
    my ($database, $airport, $from, $to) = @$params{qw(database airport date_from date_to)};
    ScriptManager::Service::CorrelazioneSetup->new->validate_target($airport, $database);
    ScriptManager::Exception->throw('invalid_date_range', 'Le date sono obbligatorie')
        unless defined $from && defined $to;
    ScriptManager::Service::ValidationWindow->validate_params($params);
    my ($year) = $database =~ /_(\d{4})_bruma\z/i;
    ScriptManager::Exception->throw('invalid_date_range', 'Le date devono appartenere all anno del database')
        unless substr($from, 0, 4) eq $year && substr($to, 0, 4) eq $year;
    my $stations = $params->{stations};
    ScriptManager::Exception->throw('invalid_stations', 'Selezionare almeno una stazione')
        unless ref $stations eq 'ARRAY' && @$stations;
    my (@selected, %ids, %codes);
    for my $item (@$stations) {
        my ($id, $code) = ($item // '') =~ /\A([1-9]\d{0,9}):(\d{1,10})\z/;
        ScriptManager::Exception->throw('invalid_stations', 'Stazione non valida o duplicata')
            unless defined $id && $id <= 2147483647 && $code <= 2147483647
            && !$ids{0 + $id}++ && !$codes{0 + $code}++;
        push @selected, {id => 0 + $id, code => 0 + $code};
    }
    my ($y, $m, $d) = split /-/, $to;
    my $next_day = strftime('%Y-%m-%d', gmtime(timegm(0, 0, 0, $d, $m - 1, $y) + 86400));
    my $cross_year = substr($to, 5) eq '12-31';
    ScriptManager::Exception->throw('invalid_date_range', 'Anno successivo non rappresentabile')
        if $cross_year && $year == 9999;
    my $next_database = $database;
    $next_database =~ s/_\Q$year\E(_bruma)\z/'_' . ($year + 1) . $1/ie if $cross_year;

    $ctx->progress(0, 'Verifica stazioni e tabelle LAeq');
    $ctx->check_cancel;
    my $db = $self->eventi->connect($database);
    my ($next_db, $next_guard);
    if ($cross_year) {
        my $target = join ':', lc($ENV{MYSQL_HOST}), 0 + ($ENV{MYSQL_PORT} // 3306), $next_database;
        $next_guard = $ctx->repo->lock_database_for_schema($target);
        ScriptManager::Exception->throw('database_busy', 'Database dell anno successivo occupato o con esecuzioni in coda')
            unless $next_guard;
        my $ok = eval { $next_db = $self->eventi->connect($next_database); 1 };
        unless ($ok) {
            my $error = $@;
            ScriptManager::Exception->throw('mysql_connect',
                "Database dell anno successivo $next_database non disponibile o non accessibile")
                if ScriptManager::Exception->caught($error, 'mysql_connect');
            die $error;
        }
    }
    my $schema = ScriptManager::Service::LAeqSetup->new->schema($db, $database);
    ScriptManager::Exception->throw('mysql_schema', join('; ', @{$schema->{errors}})) if @{$schema->{errors}};
    ScriptManager::Exception->throw('mysql_schema', 'Tabella st_laeq mancante: confermare prima la creazione')
        if $schema->{missing};
    for my $source ([$db, $database], $next_db ? ([$next_db, $next_database]) : ()) {
        my ($handle, $name) = @$source;
        my $columns = $handle->selectall_arrayref(
            'SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS '
            . 'WHERE TABLE_SCHEMA=? AND TABLE_NAME IN (?,?)',
            {Slice => {}}, $name, 'st_eventi_cmp', 'battute_eventi_cmp');
        my %columns = map { lc($_->{TABLE_NAME}) . '.' . lc($_->{COLUMN_NAME}) => 1 } @$columns;
        for my $column (qw(st_eventi_cmp.row_id st_eventi_cmp.id_centralina_cmp st_eventi_cmp.data_ora
            st_eventi_cmp.sel battute_eventi_cmp.evento_cmp_id)) {
            ScriptManager::Exception->throw('mysql_schema', "Colonna $name.$column mancante o non accessibile")
                unless $columns{$column};
        }
        $handle->selectall_arrayref('SELECT row_id, id_centralina_cmp, data_ora, Sel FROM st_eventi_cmp WHERE 1=0');
        $handle->selectall_arrayref('SELECT evento_cmp_id FROM battute_eventi_cmp WHERE 1=0');
    }
    for my $station (@selected) {
        my $rows = $db->selectall_arrayref(
            'SELECT s.row_id, a.nome_aerop FROM anagrafica.stazioni s '
            . 'LEFT JOIN anagrafica.aeroporti a ON a.row_id=s.aeroporti_id WHERE s.c_cab=?',
            undef, $station->{code});
        ScriptManager::Exception->throw('invalid_stations', 'Stazione non appartenente all aeroporto o codice ambiguo')
            unless @$rows == 1 && $rows->[0][0] == $station->{id}
            && defined $rows->[0][1] && uc($rows->[0][1]) eq $airport;
    }
    $db->do(q{SET SESSION sql_mode = CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), 'STRICT_ALL_TABLES')});
    my $sql = 'SELECT CASE WHEN HOUR(st.data_ora) BETWEEN 6 AND 21 THEN DATE(st.data_ora) '
        . 'ELSE DATE(DATE_SUB(st.data_ora, INTERVAL 6 HOUR)) END AS giorno, '
        . "CASE WHEN HOUR(st.data_ora) BETWEEN 6 AND 21 THEN 'D' ELSE 'N' END AS periodo, "
        . 'COUNT(*) AS eventi, SUM(st.Sel IS NULL) AS sel_mancanti, SUM(POW(10,st.Sel/10)) AS energia '
        . 'FROM st_eventi_cmp st WHERE st.id_centralina_cmp=? AND st.data_ora>=? AND st.data_ora<? '
        . 'AND EXISTS (SELECT 1 FROM battute_eventi_cmp c WHERE c.evento_cmp_id=st.row_id) '
        . 'GROUP BY giorno, periodo ORDER BY giorno, periodo';
    my @report;
    for my $station (@selected) {
        $ctx->check_cancel;
        my %values;
        my @sources = ([$db, "$from 06:00:00",
            $cross_year ? "$next_day 00:00:00" : "$next_day 06:00:00"]);
        push @sources, [$next_db, "$next_day 00:00:00", "$next_day 06:00:00"] if $cross_year;
        for my $source (@sources) {
            my $rows = $source->[0]->selectall_arrayref($sql, {Slice => {}},
                $station->{code}, $source->[1], $source->[2]);
            for my $row (@$rows) {
                next if $row->{giorno} lt $from || $row->{giorno} gt $to;
                ScriptManager::Exception->throw('invalid_events',
                    "Evento correlato senza SEL per la stazione $station->{code} il $row->{giorno}")
                    if $row->{sel_mancanti} || !defined $row->{energia};
                my $value = $values{$row->{giorno}}{$row->{periodo}} //= {energy => 0, events => 0};
                $value->{energy} += $row->{energia};
                $value->{events} += $row->{eventi};
            }
        }
        for my $day (sort keys %values) {
            for my $period (sort keys %{$values{$day}}) {
                my $value = $values{$day}{$period};
                ScriptManager::Exception->throw('invalid_events', 'Energia acustica non valida')
                    unless $value->{energy} > 0;
                my $level = 10 * log($value->{energy} / ($period eq 'D' ? 57600 : 28800)) / log(10);
                my ($existing, $first_id) = $db->selectrow_array(
                    'SELECT COUNT(*), MIN(row_id) FROM st_laeq WHERE id_stazione=? AND data_LAeq=? AND TR=?',
                    undef, $station->{code}, $day, $period);
                push @report, {station_code => $station->{code}, day => $day, period => $period,
                    events => 0 + $value->{events}, value => 0 + $level, existing => 0 + $existing,
                    first_id => $first_id,
                    action => $existing && !$params->{overwrite} ? 'skipped' : $existing ? 'replaced' : 'inserted'};
            }
        }
        $ctx->log(warning => "Nessun evento correlato per la stazione $station->{code} nel periodo")
            unless keys %values;
    }
    $ctx->log(warning => 'AutoCommit e possibili tabelle MyISAM: interruzioni possono lasciare risultati parziali; nessun rollback',
        operation => 'laeq_partial_effects');
    $ctx->log(warning => 'Durate fisse 16 e 8 ore; la disponibilita completa delle misure non e verificabile dagli eventi');
    $ctx->progress(50, 'Salvataggio LAeq');
    my $insert = $db->prepare('INSERT INTO st_laeq (id_stazione,data_LAeq,TR,valore_LAeq) VALUES (?,?,?,?)');
    for my $row (@report) {
        $ctx->check_cancel;
        my ($current_count, $current_first) = $db->selectrow_array(
            'SELECT COUNT(*), MIN(row_id) FROM st_laeq WHERE id_stazione=? AND data_LAeq=? AND TR=?',
            undef, @$row{qw(station_code day period)});
        ScriptManager::Exception->throw('mysql_data_changed',
            "Risultati LAeq cambiati per la stazione $row->{station_code} il $row->{day} $row->{period}; verificare i dati")
            if $current_count != $row->{existing}
            || ($current_count && $current_first != $row->{first_id});
        if ($row->{action} eq 'skipped') {
            $ctx->log(info => "LAeq $row->{station_code} $row->{day} $row->{period}: gia presente, saltato",
                operation => 'laeq_skipped', %$row);
            next;
        }
        if ($row->{action} eq 'replaced') {
            $db->do('UPDATE st_laeq SET valore_LAeq=? WHERE id_stazione=? AND data_LAeq=? AND TR=?',
                undef, @$row{qw(value station_code day period)});
            if ($row->{existing} > 1) {
                $ctx->check_cancel;
                $db->do('DELETE FROM st_laeq WHERE id_stazione=? AND data_LAeq=? AND TR=? AND row_id<>?',
                    undef, @$row{qw(station_code day period first_id)});
            }
        } else {
            $insert->execute(@$row{qw(station_code day period value)});
        }
        $ctx->log(info => "LAeq $row->{station_code} $row->{day} $row->{period}: "
            . sprintf('%.2f dB (%d eventi)', $row->{value}, $row->{events}),
            operation => 'laeq_saved', %$row);
    }
    $ctx->check_cancel;
    $ctx->write_artifact('laeq.json', encode_json({database => $database, airport => $airport,
        date_from => $from, date_to => $to, next_database => $cross_year ? $next_database : undef,
        results => \@report}), media_type => 'application/json');
    $next_db->disconnect if $next_db;
    $db->disconnect;
    $ctx->progress(100, 'Calcolo LAeq completato');
    return {success => 1, message => scalar(@report) . ' risultati LAeq calcolati'};
}

1;
