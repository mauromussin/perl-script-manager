package ScriptManager::Command::CorreggiQuote;
use Mojo::Base -base, -signatures;

use DBI;
use POSIX 'isfinite';
use Scalar::Util 'looks_like_number';
use ScriptManager::Exception;
use ScriptManager::Service::CorreggiQuotePreflight;
use ScriptManager::Service::OpenMeteo;
use ScriptManager::Service::ValidationWindow;

has [qw(logger process_runner)];
has connect_db => sub { sub (@args) { DBI->connect(@args) } };
has window_class => 'ScriptManager::Service::ValidationWindow';
has preflight_class => 'ScriptManager::Service::CorreggiQuotePreflight';

use constant TRACK_BATCH_SIZE => 100;
use constant WRITE_BATCH_SIZE => 500;

sub batch_update_statement ($db, $cache, $size) {
    return $cache->{$size} if $cache->{$size};

    my $cases = join ' ', map { 'WHEN ? THEN ?' } 1 .. $size;
    my $row_ids = join ', ', ('?') x $size;
    my $sql = 'UPDATE battute SET A_m = CASE row_id ' . $cases
        . ' ELSE A_m END WHERE flay_id = ? AND row_id IN (' . $row_ids . ')';
    return $cache->{$size} = $db->prepare($sql);
}

sub configure_schema ($class, $schema, $directory) {
    ScriptManager::Service::ValidationWindow->configure_schema($schema);
    $schema->{properties}{overwrite}{title} = 'Ricalcola A_m anche per le tracce gia normalizzate (stato 3)';
}

sub normalize ($class, $z, $pressure, $temperature, $elevation) {
    for my $value ($z, $pressure, $temperature, $elevation) {
        ScriptManager::Exception->throw('invalid_height', 'Quota o dato atmosferico mancante, non numerico o non finito')
            unless defined $value && looks_like_number($value) && isfinite($value);
    }
    ScriptManager::Exception->throw('invalid_height', 'Pressione, temperatura o quota fuori dal dominio della formula legacy')
        unless $pressure > 0 && $temperature > -273.15 && 1 - $z * 0.0065 / 288.15 > 0;
    my $aircraft_pressure = 1013.25 * (1 - $z * 0.0065 / 288.15) ** 5.2525;
    my $height = $elevation + (($temperature + 273.15) / 0.0065)
        * (1 - ($aircraft_pressure / $pressure) ** (1 / 5.2525));
    ScriptManager::Exception->throw('invalid_height', 'Quota normalizzata non finita o non memorizzabile')
        unless isfinite($height) && abs($height) <= 999999999.99;
    return $height;
}

sub weather_for_day ($self, $db, $ctx, $window, $location, $day) {
    my $record = $ctx->repo->weather_day($window->target, $day);
    return {reason => 'provenienza Open-Meteo assente o importazione 09 non completata'}
        unless $record;
    my $source = $record->{location};
    return {reason => 'metadati ARP mancanti o non validi nella provenienza Open-Meteo'}
        unless ref $source eq 'HASH';
    for my $field (qw(latitude longitude elevation)) {
        return {reason => 'metadati ARP mancanti o non validi nella provenienza Open-Meteo'}
            unless defined $source->{$field} && looks_like_number($source->{$field}) && isfinite($source->{$field});
    }
    return {reason => 'aeroporto, coordinate o quota ARP diversi da quelli importati'}
        unless ($source->{airport} // '') eq $location->{airport}
            && abs($source->{latitude} - $location->{latitude}) < 0.00000001
            && abs($source->{longitude} - $location->{longitude}) < 0.00000001
            && abs($source->{elevation} - $location->{elevation}) < 0.0001;
    my $rows = $db->selectall_arrayref(
        'SELECT data_ora, temperatura_C, pressione_hpa FROM meteo '
            . 'WHERE data_ora >= ? AND data_ora < DATE_ADD(?, INTERVAL 1 DAY) ORDER BY data_ora, row_id',
        undef, $day, $day);
    return {reason => 'meteo modificato dopo 09: impronta pressione/temperatura non corrispondente'}
        unless ScriptManager::Service::OpenMeteo->fingerprint($rows) eq $record->{fingerprint};
    my %hours;
    for my $row (@$rows) {
        return {reason => 'ore meteo duplicate'} if exists $hours{$row->[0]};
        $hours{$row->[0]} = $row;
    }
    return {hours => \%hours};
}

sub run ($self, $ctx, $params) {
    ScriptManager::Service::ValidationWindow->validate_params($params);
    ScriptManager::Exception->throw('invalid_database', 'Nome database MySQL non valido')
        unless ($params->{database} // '') =~ /\A[A-Za-z0-9_]{1,64}\z/;
    ScriptManager::Exception->throw('invalid_airport', 'Normalizzazione ARP supporta LIMC, LIML, LIME e LIPO')
        unless ($params->{airport} // '') =~ /\A(?:LIMC|LIML|LIME|LIPO)\z/;
    for my $key (qw(MYSQL_HOST MYSQL_USER MYSQL_PASSWORD)) {
        ScriptManager::Exception->throw('mysql_config', "Configurazione $key mancante")
            unless defined $ENV{$key} && length $ENV{$key};
    }
    my $port = $ENV{MYSQL_PORT} // 3306;
    ScriptManager::Exception->throw('mysql_config', 'Host o porta MySQL non validi')
        unless $ENV{MYSQL_HOST} =~ /\A[A-Za-z0-9.:-]+\z/ && $port =~ /\A\d+\z/ && $port > 0 && $port <= 65535;
    $ctx->progress(0, 'Analisi: normalizzazione quote con meteo ARP');
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
        $window = $self->window_class->new(db => $db, ctx => $ctx, params => $params, stage => 10)->prepare;
        my $height = $db->selectrow_arrayref(
            'SELECT QUOTA_aerop FROM anagrafica.aeroporti WHERE nome_aerop = ?', undef, $params->{airport});
        my $location = ScriptManager::Service::OpenMeteo->location($params->{airport}, $height ? $height->[0] : undef);
        my ($filter, @bind) = $window->filter;
        my $tracks = $db->selectall_arrayref(
            'SELECT row_id, data_ora_arr FROM flay WHERE '
            . ($window->overwrite ? 'validation_bt IN (2, 3)' : 'validation_bt = 2')
            . $filter . ' ORDER BY row_id', undef, @bind);
        $ctx->log(info => "Normalizzazione alla quota ARP $location->{elevation} m; ora contenente data_ora_arr; "
            . 'solo Open-Meteo verificato; nessuna chiamata API; AutoCommit senza rollback');
        my (@plans, %weather, %incomplete, $analyzed, $skipped, $operations, $last_analysis);
        ($analyzed, $skipped, $operations, $last_analysis) = (0, 0, 0, 0);
        my %outcomes;
        for (my $offset = 0; $offset < @$tracks; $offset += TRACK_BATCH_SIZE) {
            $ctx->check_cancel;
            my $last = $offset + TRACK_BATCH_SIZE - 1 < $#$tracks
                ? $offset + TRACK_BATCH_SIZE - 1 : $#$tracks;
            my @track_batch = @$tracks[$offset .. $last];
            my @ready;
            for my $track (@track_batch) {
                my ($id, $time) = @$track;
                my $day = substr($time, 0, 10);
                my $hour = substr($time, 0, 13) . ':00:00';
                $weather{$day} //= $self->weather_for_day($db, $ctx, $window, $location, $day);
                my $meteo = $weather{$day}{hours}{$hour};
                my $reason = $weather{$day}{reason} // (!$meteo ? "meteo assente per $hour" : undef);
                if (!$reason) {
                    for my $value (@$meteo[1, 2]) {
                        $reason = 'pressione o temperatura mancanti/non valide'
                            unless defined $value && looks_like_number($value) && isfinite($value);
                    }
                    $reason = 'pressione o temperatura fuori dominio'
                        if !$reason && ($meteo->[2] <= 0 || $meteo->[1] <= -273.15);
                }
                if ($reason) { $outcomes{$id} = {reason => $reason} }
                else { push @ready, [$track, $meteo] }
            }

            if (@ready) {
                my @ids = map { $_->[0][0] } @ready;
                my $hits = $db->selectall_arrayref(
                'SELECT flay_id, row_id, Z_m FROM battute WHERE flay_id IN ('
                    . join(', ', ('?') x @ids) . ') AND validation NOT IN (?, ?) '
                    . 'AND Z_m IS NOT NULL ORDER BY flay_id, time_italy, row_id',
                undef, @ids, 'N', 'A');
                my %hits_by_track;
                push @{$hits_by_track{$_->[0]}}, [$_->[1], $_->[2]] for @$hits;
                for my $ready (@ready) {
                    my ($track, $meteo) = @$ready;
                    my $id = $track->[0];
                    my $track_hits = $hits_by_track{$id} // [];
                    my @updates;
                    for (my $hit_offset = 0; $hit_offset < @$track_hits; $hit_offset += WRITE_BATCH_SIZE) {
                        $ctx->check_cancel;
                        my $hit_last = $hit_offset + WRITE_BATCH_SIZE - 1 < $#$track_hits
                            ? $hit_offset + WRITE_BATCH_SIZE - 1 : $#$track_hits;
                        for my $hit (@$track_hits[$hit_offset .. $hit_last]) {
                            push @updates, [$hit->[0], __PACKAGE__->normalize(
                                $hit->[1], $meteo->[2], $meteo->[1], $location->{elevation})];
                        }
                    }
                    if (@updates) {
                        push @plans, {id => $id, updates => \@updates};
                        $operations += int((@updates + WRITE_BATCH_SIZE - 1) / WRITE_BATCH_SIZE)
                            + 1 + ($window->overwrite ? 1 : 0);
                        $outcomes{$id} = {};
                    }
                    else { $outcomes{$id} = {reason => 'nessuna battuta con Z_m utilizzabile'} }
                }
            }

            for my $track (@track_batch) {
                my ($id, $time) = @$track;
                my $reason = $outcomes{$id}{reason};
                if ($reason) {
                    $incomplete{substr($time, 0, 10)} = 1;
                    $skipped++;
                    $ctx->log(warning => "Traccia $id saltata: $reason; caricare/verificare 09 e rilanciare 10");
                }
                $analyzed++;
                my $percent = int(50 * $analyzed / @$tracks);
                $ctx->progress($percent, "Analisi: $analyzed di " . scalar(@$tracks) . ' tracce')
                    if $percent != $last_analysis;
                $last_analysis = $percent;
            }
        }
        $self->preflight_class->new->check_saving($ctx, $window->target, $operations);
        $ctx->progress(50, 'Salvataggio: quote A_m e stato 3');
        $window->start_saving;
        my ($saved, $last_percent, $hits_saved) = (0, 50, 0);
        my $saving_started = $ctx->elapsed_seconds;
        my $advance = sub {
            my $percent = 50 + int(49 * $saved / $operations);
            $ctx->progress($percent, "Salvataggio: $saved di $operations operazioni") if $percent != $last_percent;
            $last_percent = $percent;
        };
        my %batch_statements;
        for my $plan (@plans) {
            $ctx->check_cancel;
            if ($window->overwrite) {
                $db->do('UPDATE battute SET A_m = NULL WHERE flay_id = ?', undef, $plan->{id});
                $saved++;
                $advance->();
            }
            my $updates = $plan->{updates};
            for (my $offset = 0; $offset < @$updates; $offset += WRITE_BATCH_SIZE) {
                $ctx->check_cancel;
                my $last = $offset + WRITE_BATCH_SIZE - 1 < $#$updates
                    ? $offset + WRITE_BATCH_SIZE - 1 : $#$updates;
                my @batch = @$updates[$offset .. $last];
                my $statement = batch_update_statement($db, \%batch_statements, scalar @batch);
                my @values;
                push @values, @$_ for @batch;
                push @values, $plan->{id}, map { $_->[0] } @batch;
                $statement->execute(@values);
                $saved++;
                $hits_saved += @batch;
                $advance->();
            }
            $ctx->check_cancel;
            $db->do('UPDATE flay SET validation_bt = ? WHERE row_id = ?', undef, 3, $plan->{id});
            $saved++;
            $advance->();
        }
        $_->finish for values %batch_statements;
        my $saving_seconds = $ctx->elapsed_seconds - $saving_started;
        $ctx->log(info => 'Salvataggio 10 misurato: ' . "$saved operazioni SQL in "
                . sprintf('%.3f secondi', $saving_seconds),
            operation => ScriptManager::Service::CorreggiQuotePreflight::SAVING_METRIC(),
            units => $saved, seconds => $saving_seconds) if $saved;
        $ctx->check_cancel;
        $ctx->progress(99, 'Riepilogo finale della normalizzazione quote');
        $ctx->log(info => scalar(@plans) . " tracce normalizzate, $hits_saved quote salvate, $skipped tracce saltate");
        $result = {success => 1, message => scalar(@plans) . " tracce normalizzate, $hits_saved quote salvate, $skipped tracce saltate",
            data => {tracks => scalar(@plans), hits => $hits_saved, skipped_tracks => $skipped,
                incomplete_days => [sort keys %incomplete]}};
        1;
    };
    $error = $@;
    unless ($ok) {
        $ctx->log(error => 'Normalizzazione interrotta; eventuali scritture gia eseguite non sono annullate');
        my $closed = eval { $db->disconnect; 1 };
        $ctx->log(error => 'Chiusura della connessione MySQL fallita') unless $closed;
        die $error;
    }
    $db->disconnect;
    $window->finish($result);
    $ctx->progress(100, 'Normalizzazione quote conclusa');
    return $result;
}

1;
