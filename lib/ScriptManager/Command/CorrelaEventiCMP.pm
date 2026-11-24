package ScriptManager::Command::CorrelaEventiCMP;
use Mojo::Base -base, -signatures;

use POSIX 'strftime';
use Time::Local 'timegm';
use ScriptManager::Exception;
use ScriptManager::Service::EventiCMP;

has [qw(logger process_runner)];
has eventi => sub { ScriptManager::Service::EventiCMP->new };

sub _date ($value) {
    return 0 unless defined $value && !ref $value
        && $value =~ /\A([1-9]\d{3})-(\d\d)-(\d\d)\z/;
    my ($y, $m, $d) = ($1, $2, $3);
    my $epoch = eval { timegm(0, 0, 0, $d, $m - 1, $y) };
    return !$@ && defined $epoch && strftime('%Y-%m-%d', gmtime($epoch)) eq $value;
}

sub run ($self, $ctx, $params) {
    ScriptManager::Exception->throw('invalid_parameters', 'Parametri non validi')
        unless ref $params eq 'HASH' && !exists $params->{cond};
    my %iata = (LIMC => 'mxp', LIML => 'lin', LIME => 'bgy', LIPO => 'vbs');
    my $airport = $params->{airport} // '';
    ScriptManager::Exception->throw('invalid_airport', 'Aeroporto non valido')
        unless !ref $airport && exists $iata{$airport};
    my $database = $params->{database} // '';
    ScriptManager::Exception->throw('invalid_database', 'Database non coerente con aeroporto')
        unless !ref $database && $database =~ /\A\Q$iata{$airport}\E_\d{4}_bruma\z/i;
    my ($from, $to) = @{$params}{qw(date_from date_to)};
    ScriptManager::Exception->throw('invalid_dates', 'Periodo non valido')
        unless _date($from) && _date($to) && $from le $to;
    my $input = $params->{stations};
    ScriptManager::Exception->throw('invalid_stations', 'Selezionare almeno una stazione')
        unless ref $input eq 'ARRAY' && @$input;
    my (@stations, %ids, %codes);
    for my $value (@$input) {
        ScriptManager::Exception->throw('invalid_stations', 'Parametri stazione non validi')
            unless defined $value && !ref $value
            && $value =~ /\A([1-9]\d*):(\d+):([+-]?\d+):([+-]?\d+):([+-]?\d+):((?:\d+(?:\.\d*)?|\.\d+))\z/;
        my ($id, $code, $shift, $mti, $mta, $mdi) = ($1, $2, $3, $4, $5, $6);
        ScriptManager::Exception->throw('invalid_stations', 'Valori stazione fuori intervallo o duplicati')
            if length($id) > 10 || $id > 2147483647 || length($code) > 10 || $code > 2147483647
            || grep { length($_) > 11 || $_ < -2147483648 || $_ > 2147483647 } ($shift, $mti, $mta);
        ScriptManager::Exception->throw('invalid_stations', 'Valori stazione fuori intervallo o duplicati')
            if length($mdi) > 15 || $mdi <= 0 || $mdi > 999999999.99
            || $shift < -32768 || $shift > 32767 || $mti > $mta
            || $ids{0 + $id}++ || $codes{0 + $code}++;
        push @stations, {id => 0 + $id, code => 0 + $code, shift => 0 + $shift,
            mti => 0 + $mti, mta => 0 + $mta, mdi => 0 + $mdi};
    }

    $ctx->progress(0, 'Verifica parametri e tabelle');
    $ctx->check_cancel;
    my $db = $self->eventi->connect($database);
    my ($result, $ok);
    $ok = eval {
        # Verify every table and every column used before deleting anything.
        for my $query (
            'SELECT row_id, aeroporti_id, c_cab, X_m, Y_m, H_m FROM anagrafica.stazioni WHERE 1=0',
            'SELECT row_id, nome_aerop FROM anagrafica.aeroporti WHERE 1=0',
            'SELECT sid, stazioni_id FROM anagrafica.stazioni_sid WHERE 1=0',
            'SELECT IdLog, DataCorr, DatabaseCorr, IdStazione, DataInizio, DataFine, CorrNumber, MaxTimeIn, MaxTimeAdv, MaxDistance FROM anagrafica.correla_log WHERE 1=0',
            'SELECT row_id, id_centralina_cmp, data_ora, Sel FROM st_eventi_cmp WHERE 1=0',
            'SELECT row_id, sid, validation_bt FROM flay WHERE 1=0',
            'SELECT row_id, flay_id, X_m, Y_m, A_m, validation, time_italy FROM battute WHERE 1=0',
            'SELECT flay_id, battuta_id, evento_cmp_id, distance, shift FROM battute_eventi_cmp WHERE 1=0',
            'SELECT data_calc, id_stazione, data_lva, correlato, valore, id_log FROM st_lva WHERE 1=0',
            'SELECT data_calc, id_stazione, data_lvan, correlato, valore, id_log FROM st_lvan WHERE 1=0',
        ) { $db->selectall_arrayref($query) }
        for my $station (@stations) {
            $ctx->check_cancel;
            my $rows = $db->selectall_arrayref(
                'SELECT s.row_id, s.X_m, s.Y_m, s.H_m, a.nome_aerop '
                . 'FROM anagrafica.stazioni s LEFT JOIN anagrafica.aeroporti a ON a.row_id=s.aeroporti_id '
                . 'WHERE s.c_cab = ?', undef, $station->{code});
            ScriptManager::Exception->throw('invalid_stations', 'Stazione non appartenente all aeroporto o codice ambiguo')
                unless @$rows == 1 && $rows->[0][0] == $station->{id}
                && defined $rows->[0][4] && uc($rows->[0][4]) eq $airport
                && !grep { !defined $_ || $_ !~ /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/ } @{$rows->[0]}[1..3];
            @{$station}{qw(x y h)} = @{$rows->[0]}[1..3];
            my $missing_sel = $db->selectrow_array('SELECT COUNT(*) FROM st_eventi_cmp '
                . 'WHERE id_centralina_cmp=? AND data_ora>=? AND DATE(data_ora)<=? AND Sel IS NULL',
                undef, $station->{code}, "$from 00:00:00", $to);
            ScriptManager::Exception->throw('invalid_events', 'Evento senza SEL: impossibile calcolare LVA e LVAn')
                if $missing_sel;
            my $events = $db->selectrow_array('SELECT COUNT(*) FROM st_eventi_cmp '
                . 'WHERE id_centralina_cmp=? AND data_ora>=? AND DATE(data_ora)<=?',
                undef, $station->{code}, "$from 00:00:00", $to);
            ScriptManager::Exception->throw('invalid_events', "Nessun evento nel periodo per la stazione $station->{code}")
                unless $events;
        }
        $db->do(q{SET SESSION sql_mode = CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), 'STRICT_ALL_TABLES')});
        $ctx->log(warning => 'AutoCommit e possibili tabelle MyISAM: errori, timeout o annullamento possono lasciare cancellazioni e scritture parziali, senza rollback',
            operation => 'correlation_partial_effects');
        my @results;
        my $start = "$from 00:00:00";
        for my $s (@stations) {
            $ctx->check_cancel;
            $ctx->log(info => "Correlazione stazione $s->{code}", operation => 'correlation_station_start',
                database => $database, airport => $airport, date_from => $from, date_to => $to,
                station_id => $s->{id}, station_code => $s->{code}, shift => $s->{shift},
                mti => $s->{mti}, mta => $s->{mta}, mdi => $s->{mdi});
            my $deleted = $db->do('DELETE corr FROM battute_eventi_cmp corr JOIN st_eventi_cmp st '
                . 'ON corr.evento_cmp_id=st.row_id WHERE st.id_centralina_cmp=? AND st.data_ora>=? AND DATE(st.data_ora)<=?',
                undef, $s->{code}, $start, $to);
            die "Cancellazione correlazioni fallita\n" unless defined $deleted;
            my $order = $s->{shift} ? 'Sel DESC' : 'data_ora';
            my $events = $db->selectall_arrayref('SELECT row_id, DATE_ADD(data_ora, INTERVAL ? SECOND), Sel '
                . "FROM st_eventi_cmp WHERE id_centralina_cmp=? AND data_ora>=? AND DATE(data_ora)<=? ORDER BY $order, row_id",
                undef, $s->{shift}, $s->{code}, $start, $to);
            my $candidates = $db->prepare('SELECT fl.row_id, bt.row_id, '
                . 'SQRT(POW(?-bt.X_m,2)+POW(?-bt.Y_m,2)+POW(?-bt.A_m,2)) AS distance '
                . 'FROM battute bt JOIN flay fl ON bt.flay_id=fl.row_id '
                . 'JOIN anagrafica.stazioni_sid sid ON sid.sid=fl.sid '
                . 'WHERE fl.validation_bt=3 AND bt.validation=? AND sid.stazioni_id=? '
                . 'AND bt.time_italy BETWEEN DATE_ADD(?, INTERVAL ? SECOND) AND DATE_ADD(?, INTERVAL ? SECOND) '
                . 'HAVING distance < ? ORDER BY distance, fl.row_id, bt.row_id');
            my $used = $db->prepare('SELECT COUNT(*) FROM battute_eventi_cmp corr JOIN st_eventi_cmp ev '
                . 'ON corr.evento_cmp_id=ev.row_id WHERE (corr.flay_id=? OR corr.evento_cmp_id=?) '
                . 'AND corr.shift=? AND ev.id_centralina_cmp=?');
            my $insert = $db->prepare('INSERT INTO battute_eventi_cmp (flay_id,battuta_id,evento_cmp_id,distance,shift) VALUES (?,?,?,?,?)');
            my $count = 0;
            for my $event (@$events) {
                $ctx->check_cancel;
                $candidates->execute(@{$s}{qw(x y h)}, 'Y', $s->{code}, $event->[1], $s->{mti},
                    $event->[1], $s->{mta}, $s->{mdi});
                while (my $candidate = $candidates->fetchrow_arrayref) {
                    $ctx->check_cancel;
                    $used->execute($candidate->[0], $event->[0], $s->{shift}, $s->{code});
                    next if $used->fetchrow_array;
                    $insert->execute($candidate->[0], $candidate->[1], $event->[0], $candidate->[2], $s->{shift});
                    $count++;
                    last;
                }
            }
            $ctx->check_cancel;
            $db->do('INSERT INTO anagrafica.correla_log '
                . '(DataCorr,DatabaseCorr,IdStazione,DataInizio,DataFine,CorrNumber,MaxTimeIn,MaxTimeAdv,MaxDistance) '
                . 'VALUES (NOW(),?,?,?,?,?,?,?,?)', undef, $database, $s->{code}, $from, $to, $count,
                @{$s}{qw(mti mta mdi)});
            my $log_id = $db->last_insert_id(undef, 'anagrafica', 'correla_log', undef);
            die "Impossibile ottenere IdLog inserito\n" unless defined $log_id && $log_id =~ /\A[1-9]\d*\z/;
            $log_id = 0 + $log_id;
            my %days = (st_lva => {0 => 0, 1 => 0}, st_lvan => {0 => 0, 1 => 0});
            for my $metric (
                ['st_lva', 'data_lva', '10*LOG10(SUM(POW(10,IF(HOUR(st.data_ora) BETWEEN 6 AND 22,st.Sel/10,(st.Sel+10)/10)))/86400.0)', ''],
                ['st_lvan', 'data_lvan', '10*LOG10(SUM(POW(10,(st.Sel+10)/10))/25200.0)', ' AND (HOUR(st.data_ora) BETWEEN 0 AND 5 OR HOUR(st.data_ora)=23)'],
            ) {
                for my $correlated (0, 1) {
                    $ctx->check_cancel;
                    my $filter = $correlated ? ' AND EXISTS (SELECT 1 FROM battute_eventi_cmp c WHERE c.evento_cmp_id=st.row_id)' : '';
                    my $rows = $db->selectall_arrayref('SELECT DATE(st.data_ora), ' . $metric->[2]
                        . ' FROM st_eventi_cmp st WHERE st.id_centralina_cmp=? AND st.data_ora>=? AND DATE(st.data_ora)<=?'
                        . $metric->[3] . $filter . ' GROUP BY DATE(st.data_ora) ORDER BY DATE(st.data_ora)',
                        undef, $s->{code}, $start, $to);
                    my $save = $db->prepare("INSERT INTO $metric->[0] (data_calc,id_stazione,$metric->[1],correlato,valore,id_log) VALUES (NOW(),?,?,?,?,?)");
                    for my $row (@$rows) {
                        $ctx->check_cancel;
                        die "Calcolo $metric->[0] non valido\n" unless defined $row->[1];
                        $save->execute($s->{code}, $row->[0], $correlated, $row->[1], $log_id);
                        $days{$metric->[0]}{$correlated}++;
                    }
                }
            }
            my $summary = {station_id => $s->{id}, station_code => $s->{code}, shift => $s->{shift},
                log_id => $log_id, events => scalar(@$events), correlated => $count, days => \%days};
            push @results, $summary;
            $ctx->log(info => "Stazione $s->{code}: $count correlati su " . scalar(@$events) . " eventi",
                operation => 'correlation_station_summary', %$summary);
            $ctx->log(info => "Risultati salvati per la stazione $s->{code}",
                operation => 'correlation_station_complete', station_code => 0 + $s->{code}, log_id => 0 + $log_id);
        }
        $result = {success => 1, message => scalar(@results) . ' stazioni elaborate', data => {stations => \@results}};
        1;
    };
    my $error = $@;
    if (!$ok) {
        $ctx->log(error => 'Correlazione interrotta: cancellazioni e scritture gia eseguite possono essere parziali e non sono annullate',
            operation => 'correlation_failed');
        my $disconnected = eval { $db->disconnect; 1 };
        $ctx->log(critical => 'Chiusura della connessione MySQL fallita dopo l errore')
            unless $disconnected;
        die $error;
    }
    $db->disconnect;
    $ctx->progress(100, 'Correlazione completata');
    return $result;
}

1;
