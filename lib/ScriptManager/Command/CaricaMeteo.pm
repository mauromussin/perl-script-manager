package ScriptManager::Command::CaricaMeteo;
use Mojo::Base -base, -signatures;

use DBI;
use Mojo::JSON 'encode_json';
use ScriptManager::Exception;
use ScriptManager::Service::OpenMeteo;
use ScriptManager::Service::OpenMeteoQuota;
use ScriptManager::Service::ValidationWindow;

has [qw(logger process_runner)];
has connect_db => sub { sub (@args) { DBI->connect(@args) } };
has weather => sub { ScriptManager::Service::OpenMeteo->new };

sub configure_schema ($class, $schema, $directory) {
    ScriptManager::Service::ValidationWindow->configure_schema($schema);
    push @{$schema->{required}}, qw(date_from date_to);
    $schema->{properties}{overwrite}{title} = 'Sostituisci interi giorni meteo, anche dati di centraline';
}

sub run ($self, $ctx, $params) {
    ScriptManager::Exception->throw('invalid_date_range', 'Per il meteo sono obbligatorie entrambe le date')
        unless defined $params->{date_from} && defined $params->{date_to};
    ScriptManager::Service::ValidationWindow->validate_params($params);
    ScriptManager::Exception->throw('invalid_database', 'Nome database MySQL non valido')
        unless ($params->{database} // '') =~ /\A[A-Za-z0-9_]{1,64}\z/;
    ScriptManager::Exception->throw('invalid_airport', 'Meteo ARP supporta LIMC, LIML, LIME e LIPO')
        unless ($params->{airport} // '') =~ /\A(?:LIMC|LIML|LIME|LIPO)\z/;
    for my $key (qw(MYSQL_HOST MYSQL_USER MYSQL_PASSWORD)) {
        ScriptManager::Exception->throw('mysql_config', "Configurazione $key mancante")
            unless defined $ENV{$key} && length $ENV{$key};
    }
    my $port = $ENV{MYSQL_PORT} // 3306;
    ScriptManager::Exception->throw('mysql_config', 'Host o porta MySQL non validi')
        unless $ENV{MYSQL_HOST} =~ /\A[A-Za-z0-9.:-]+\z/ && $port =~ /\A\d+\z/ && $port > 0 && $port <= 65535;
    $ctx->progress(0, 'Analisi: dati meteo orari ARP');
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
    my ($result, $quota);
    my $ok = eval {
        my $target = join ':', lc($ENV{MYSQL_HOST}), $port, $params->{database};
        $ctx->validation_guard($ctx->repo->lock_validation_target($target));
        $quota = ScriptManager::Service::OpenMeteoQuota->new(repo => $ctx->repo, execution_id => $ctx->execution_id);
        $ctx->log(info => ScriptManager::Service::OpenMeteo->attribution);
        $ctx->log(warning => 'Dati modellistici all ARP, non misure di centralina; pressione alla quota ARP, vento in m/s');
        $ctx->log(info => 'La fase 10 integrata usa quota ARP; non usare il vecchio script con quote di centraline');
        $ctx->log(info => 'direzione_vento2 e radiazione_netta restano NULL: nessun equivalente Open-Meteo');
        my $height = $db->selectrow_arrayref(
            'SELECT QUOTA_aerop FROM anagrafica.aeroporti WHERE nome_aerop = ?', undef, $params->{airport});
        my $location = ScriptManager::Service::OpenMeteo->location($params->{airport}, $height ? $height->[0] : undef);
        $ctx->log(info => "ARP $location->{airport}: $location->{latitude}, $location->{longitude}; "
            . "quota $location->{elevation} m; $location->{source}");
        my $existing = $db->selectcol_arrayref(
            'SELECT DISTINCT DATE(data_ora) FROM meteo WHERE data_ora >= ? AND data_ora < DATE_ADD(?, INTERVAL 1 DAY)',
            undef, @{$params}{qw(date_from date_to)});
        my %existing = map { $_ => 1 } @$existing;
        my (@days, @skipped, @groups);
        my $last = ScriptManager::Service::OpenMeteo->epoch($params->{date_to});
        for (my $time = ScriptManager::Service::OpenMeteo->epoch($params->{date_from}); $time <= $last; $time += 86400) {
            $ctx->check_cancel;
            my $day = ScriptManager::Service::OpenMeteo->day($time);
            if ($existing{$day} && !$params->{overwrite}) {
                push @skipped, $day;
                $ctx->log(info => "Skip $day: dati meteo gia presenti (anche parziali o di centraline)");
                next;
            }
            push @days, $day;
            if (@groups && @{$groups[-1]} < ScriptManager::Service::OpenMeteo->max_local_days
                && ScriptManager::Service::OpenMeteo->epoch($groups[-1][-1]) + 86400 == $time) {
                push @{$groups[-1]}, $day;
            }
            else { push @groups, [$day] }
        }
        my (@batches, %by_day, $analyzed, $total);
        ($analyzed, $total) = (0, 0);
        my $budget = $quota->snapshot;
        $ctx->log(info => scalar(@groups) . ' chiamate previste (una per blocco, inclusa copertura UTC); ' . $quota->describe($budget));
        $ctx->log(warning => $budget->{scope});
        $quota->check(scalar @groups, $budget);
        for my $group (@groups) {
            $ctx->check_cancel;
            my $call = $quota->reserve;
            my $batch = eval { $self->weather->fetch($location, $group->[0], $group->[-1]) };
            my $request_error = $@;
            my $accounted = eval { $quota->finish($call, !$request_error); 1 };
            my $account_error = $@;
            unless ($accounted) {
                $ctx->log(error => "Aggiornamento del contatore Open-Meteo fallito: $account_error");
                die $request_error || $account_error;
            }
            die $request_error if $request_error;
            $budget = $quota->snapshot;
            $ctx->log(info => $quota->describe($budget));
            $ctx->check_cancel;
            push @batches, $batch;
            for my $discarded (@{$batch->{discarded}}) {
                $ctx->log(warning => "Ora ripetuta $discarded->{local}: conservata la seconda occorrenza (ora solare); "
                    . 'entrambe le ore UTC sono nel report');
            }
            for my $row (@{$batch->{rows}}) {
                push @{$by_day{substr($row->{local}, 0, 10)}}, $row->{values};
                $total++;
            }
            $analyzed++;
            $ctx->progress(int(50 * $analyzed / @groups), "Analisi: $analyzed di " . scalar(@groups) . ' richieste API');
        }
        for my $day (@days) {
            ScriptManager::Exception->throw('weather_data', "Nessuna ora ricevuta per $day")
                unless @{$by_day{$day} // []};
        }
        $ctx->check_cancel;
        $ctx->write_artifact('meteo-open-meteo.json', encode_json({
            attribution => ScriptManager::Service::OpenMeteo->attribution,
            location => $location, parameters => $params, days_processed => \@days, days_skipped => \@skipped,
            time_zone => 'Europe/Rome', repeated_hour => 'keep_second_standard_time', batches => \@batches,
            api_usage => $budget, planned_requests => scalar @groups,
        }), media_type => 'application/json');
        $ctx->progress(50, 'Salvataggio: dati orari nella tabella meteo');
        $ctx->log(warning => 'Sovrascrivi: sostituzione integrale dei giorni selezionati, anche misure di centraline; AutoCommit')
            if $params->{overwrite} && @days;
        $ctx->log(warning => 'Lo storico 10 dei giorni importati viene invalidato, ma A_m e stato 3 non vengono azzerati. '
            . 'Per aggiornare quote gia normalizzate eseguire 10 con Sovrascrivi')
            if @days;
        my ($saved, $last_percent) = (0, 50);
        my $units = $total + ($params->{overwrite} ? scalar @days : 0);
        my $advance = sub {
            my $percent = 50 + int(49 * $saved / $units);
            $ctx->progress($percent, "Salvataggio: $saved di $units operazioni") if $percent != $last_percent;
            $last_percent = $percent;
        };
        if (@days) {
            my $insert = $db->prepare('INSERT INTO meteo (data_ora, precipitazione_mm, temperatura_C, '
                . 'direzione_vento1, direzione_vento2, velocita_vento, umidita_relativa, radiazione_netta, '
                . 'radiazione_globale, pressione_hpa) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
            for my $day (@days) {
                $ctx->check_cancel;
                $ctx->repo->invalidate_weather_day($target, $day);
                if ($params->{overwrite}) {
                    $db->do('DELETE FROM meteo WHERE data_ora >= ? AND data_ora < DATE_ADD(?, INTERVAL 1 DAY)',
                        undef, $day, $day);
                    $saved++;
                    $advance->();
                }
                for my $values (@{$by_day{$day}}) {
                    $ctx->check_cancel;
                    $insert->execute(@$values);
                    $saved++;
                    $advance->();
                }
                my $persisted = $db->selectall_arrayref(
                    'SELECT data_ora, temperatura_C, pressione_hpa FROM meteo WHERE DATE(data_ora) = ? ORDER BY data_ora, row_id',
                    undef, $day);
                ScriptManager::Exception->throw('weather_write', "Conteggio meteo inatteso nel giorno $day")
                    unless @$persisted == @{$by_day{$day}};
                $ctx->repo->record_weather_day($target, $day, $location,
                    ScriptManager::Service::OpenMeteo->fingerprint($persisted), $ctx->execution_id);
            }
            $insert->finish;
        }
        $ctx->check_cancel;
        $ctx->progress(99, 'Riepilogo finale dei dati meteo');
        my $report = @days ? $db->selectall_arrayref(
            'SELECT DATE(data_ora), COUNT(*) FROM meteo WHERE DATE(data_ora) IN ('
            . join(',', ('?') x @days) . ') GROUP BY DATE(data_ora) ORDER BY 1', undef, @days) : [];
        my %counts = map { $_->[0] => $_->[1] } @$report;
        for my $day (@days) {
            ScriptManager::Exception->throw('weather_write', "Conteggio meteo inatteso nel giorno $day: verificare scritture concorrenti")
                unless ($counts{$day} // 0) == @{$by_day{$day}};
            $ctx->log(info => "Meteo $day: $counts{$day} ore salvate");
        }
        $result = {success => 1, message => "$total ore meteo caricate; " . scalar(@skipped) . ' giorni saltati; '
                . $quota->describe($budget),
            data => {rows => $total, days_processed => \@days, days_skipped => \@skipped,
                location => $location, report => $report, api_usage => $budget}};
        1;
    };
    $error = $@;
    unless ($ok) {
        if ($quota) {
            my $reported = eval { $ctx->log(info => $quota->describe($quota->snapshot)); 1 };
            $ctx->log(error => "Lettura del contatore Open-Meteo fallita: $@") unless $reported;
        }
        $ctx->log(error => 'Importazione meteo interrotta; eventuali scritture gia eseguite non sono annullate. '
            . 'Per ripristinare giorni parziali usare Sovrascrivi');
        my $closed = eval { $db->disconnect; 1 };
        $ctx->log(error => 'Chiusura della connessione MySQL fallita') unless $closed;
        die $error;
    }
    $db->disconnect;
    $ctx->progress(100, 'Caricamento meteo concluso');
    return $result;
}

1;
