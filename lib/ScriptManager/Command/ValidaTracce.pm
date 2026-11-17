package ScriptManager::Command::ValidaTracce;
use Mojo::Base -base, -signatures;

use DBI;
use Mojo::File 'path';
use Mojo::JSON 'decode_json';
use Log::Any ();
use ScriptManager::Exception;

has 'logger' => sub { Log::Any->get_logger(category => 'ScriptManager::ValidaTracce') };
has 'connect_db' => sub { sub (@args) { DBI->connect(@args) } };

# Configurazione aeroporti con coordinate (X_aerop, Y_aerop) e offset Y specifico se necessario
# offset_y viene aggiunto a Y_aerop per compensare problemi storici di coordinate
our %AIRPORTS = (
    LIME => {
        name => 'Orio al Serio (Bergamo)',
        offset_y => -376,
    },
    LIPO => {
        name => 'Montichiari (Brescia)',
        offset_y => -2515,
    },
);

sub mrt ($class, $file) {
    my $config = decode_json(path($file)->slurp);
    die "MRT.json: airports obbligatorio\n"
        unless ref $config eq 'HASH' && ref $config->{airports} eq 'HASH';
    return $config;
}

sub configure_schema ($class, $schema, $directory) {
    my $file = $ENV{MRT_CONFIG_FILE} // $directory->child('local', 'MRT.json')->to_string;
    my $config = $class->mrt($file);
    my @airport_codes = sort keys %{$config->{airports}};
    my $field = $schema->{properties}{airport};
    $field->{enum} = \@airport_codes;
    $field->{'x-enum-labels'} = {
        map { $_ => $AIRPORTS{$_}{name} // $config->{airports}{$_} } @airport_codes
    };
    return;
}

sub run ($self, $ctx, $params) {
    $ctx->log(info => 'Inizio validazione tracce', operation => 'valida_tracce_start');
    
    # Validazione parametri
    ScriptManager::Exception->throw('invalid_database', 'Nome database MySQL non valido')
        unless ($params->{database} // '') =~ /\A[A-Za-z0-9_]{1,64}\z/;
    
    my $airport = $params->{airport} // '';
    ScriptManager::Exception->throw('invalid_airport', 'Aeroporto non valido')
        unless defined $AIRPORTS{$airport};
    
    $ctx->log(info => "Validazione per database '$params->{database}' e aeroporto '$airport'",
        operation => 'validate_parameters');
    
    # Verifica configurazione MySQL
    for my $key (qw(MYSQL_HOST MYSQL_USER MYSQL_PASSWORD)) {
        ScriptManager::Exception->throw('mysql_config', "Configurazione $key mancante")
            unless defined $ENV{$key} && length $ENV{$key};
    }
    
    my $port = $ENV{MYSQL_PORT} // 3306;
    ScriptManager::Exception->throw('mysql_config', 'Host o porta MySQL non validi')
        unless $ENV{MYSQL_HOST} =~ /\A[A-Za-z0-9.:-]+\z/ && $port =~ /\A\d+\z/ && $port > 0 && $port <= 65535;
    
    # Connessione al database
    $ctx->log(info => "Connessione MySQL: host $ENV{MYSQL_HOST}, porta $port, database $params->{database}",
        operation => 'mysql_connect');
    
    my $db;
    my $connected = eval {
        $db = $self->connect_db->(
            "DBI:MariaDB:database=$params->{database};host=$ENV{MYSQL_HOST};port=$port",
            $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD},
            {RaiseError => 1, PrintError => 0, AutoCommit => 1}
        );
        1;
    };
    
    my $connect_error = $@;
    my $mysql_error = $DBI::err;
    
    unless ($connected && $db) {
        die $connect_error if ScriptManager::Exception->caught($connect_error);
        my ($code, $message) = ('mysql_connect', 'Connessione MySQL fallita: verificare host, porta e configurazione');
        if (defined $mysql_error) {
            if ($mysql_error == 1045 || $mysql_error == 1698) {
                $code = 'mysql_authentication';
                $message = 'Autenticazione MySQL rifiutata';
            } elsif ($mysql_error == 1049) {
                $code = 'mysql_database_missing';
                $message = 'Database MySQL selezionato inesistente';
            }
            $message .= " (codice MySQL $mysql_error)";
        }
        ScriptManager::Exception->throw($code, $message);
    }
    
    $ctx->log(info => 'Connessione MySQL riuscita', operation => 'mysql_connected');
    
    # Verifica tabelle necessarie
    $ctx->log(info => 'Verifica tabelle flay, battute e anagrafica.aeroporti', operation => 'mysql_schema');
    my $tables = $db->selectall_arrayref(
        'SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME IN (?, ?)',
        undef, $params->{database}, 'flay', 'battute'
    );
    
    ScriptManager::Exception->throw('mysql_schema', 'Tabelle flay o battute mancanti')
        unless @$tables == 2;
    
    # Recupera coordinate aeroporto da anagrafica.aeroporti
    $ctx->log(info => "Recupero coordinate per aeroporto $airport", operation => 'load_airport_coords');
    
    my $airport_data = $db->selectrow_arrayref(
        'SELECT LONG_aerop, LAT_aerop, QUOTA_aerop FROM anagrafica.aeroporti WHERE nome_aerop = ?',
        undef, $airport
    );
    
    ScriptManager::Exception->throw('airport_not_found', "Aeroporto $airport non trovato in anagrafica.aeroporti")
        unless $airport_data;
    
    my ($x_aerop, $y_aerop, $h_aerop) = @$airport_data;
    
    # Applica offset Y specifico dell'aeroporto se configurato
    if (defined $AIRPORTS{$airport}{offset_y}) {
        my $offset = $AIRPORTS{$airport}{offset_y};
        $ctx->log(info => "Applica offset Y per $airport: $offset", operation => 'airport_offset');
        $y_aerop += $offset;
    }
    
    $ctx->log(info => "Coordinate aeroporto $airport: X=$x_aerop, Y=$y_aerop, H=$h_aerop",
        operation => 'airport_coords', x => $x_aerop, y => $y_aerop, h => $h_aerop);
    
    # Soglie di validazione
    my $MAX_DISTANCE_M = 10000;
    my $MAX_ALTITUDE_ABOVE_AIRPORT_M = 1000;
    my $MIN_HITS = 4;
    
    # Estrai tracce non ancora validate
    $ctx->log(info => 'Ricerca tracce non ancora validate', operation => 'load_unvalidated_tracks');
    
    my $unvalidated_tracks = $db->selectcol_arrayref(
        'SELECT row_id FROM flay WHERE validation_fl IS NULL ORDER BY row_id'
    );
    
    if (!@$unvalidated_tracks) {
        $ctx->log(info => 'Nessuna traccia da validare', operation => 'no_tracks');
        return {success => 1, message => 'Nessuna traccia da validare', data => {
            valid_count => 0, invalid_count => 0, total_count => 0
        }};
    }
    
    $ctx->log(info => scalar(@$unvalidated_tracks) . ' tracce da validare', operation => 'tracks_found',
        track_count => scalar(@$unvalidated_tracks));
    
    my (@valid_tracks, @invalid_tracks);
    my $total = @$unvalidated_tracks;
    my $processed = 0;
    
    for my $track_id (@$unvalidated_tracks) {
        $ctx->check_cancel;
        
        $processed++;
        my $percent = int(100 * $processed / $total);
        $ctx->progress($percent, "Elaborazione traccia $processed di $total");
        
        # Recupera battute della traccia
        my $hits = $db->selectall_arrayref(
            'SELECT X_m, Y_M, H_m FROM battute WHERE flay_id = ? ORDER BY row_id',
            undef, $track_id
        );
        
        # Verifica numero minimo di battute
        if (@$hits < $MIN_HITS) {
            $ctx->log(info => "Traccia $track_id: soli " . scalar(@$hits) . " hit (minimo $MIN_HITS)",
                operation => 'track_validation', track_id => $track_id, result => 'invalid_insufficient_hits');
            push @invalid_tracks, $track_id;
            next;
        }
        
        # Cerca una battuta nell'intorno dell'aeroporto a quota accettabile
        my $valid_hit_found = 0;
        for my $hit (@$hits) {
            my ($x, $y, $h) = @$hit;
            my $distance = sqrt(($y - $y_aerop)**2 + ($x - $x_aerop)**2);
            
            if ($distance <= $MAX_DISTANCE_M && $h <= ($h_aerop + $MAX_ALTITUDE_ABOVE_AIRPORT_M)) {
                $valid_hit_found = 1;
                $ctx->log(info => "Traccia $track_id: hit valido trovato (distanza=" . int($distance) . "m, quota=" . int($h) . "m)",
                    operation => 'track_validation', track_id => $track_id, result => 'valid',
                    hit_distance_m => int($distance), hit_altitude_m => int($h));
                last;
            }
        }
        
        if ($valid_hit_found) {
            push @valid_tracks, $track_id;
        } else {
            $ctx->log(info => "Traccia $track_id: nessun hit valido nell'intorno dell'aeroporto",
                operation => 'track_validation', track_id => $track_id, result => 'invalid_no_valid_hit');
            push @invalid_tracks, $track_id;
        }
    }
    
    # Aggiorna database: tracce valide
    $ctx->log(info => 'Aggiornamento database per tracce valide', operation => 'update_valid_tracks',
        valid_count => scalar(@valid_tracks));
    
    for my $track_id (@valid_tracks) {
        $ctx->check_cancel;
        $db->do('UPDATE flay SET validation_fl = ? WHERE row_id = ?', undef, 'Y', $track_id);
    }
    
    # Aggiorna database: tracce non valide e relative battute
    $ctx->log(info => 'Aggiornamento database per tracce non valide', operation => 'update_invalid_tracks',
        invalid_count => scalar(@invalid_tracks));
    
    for my $track_id (@invalid_tracks) {
        $ctx->check_cancel;
        $db->do('UPDATE flay SET validation_fl = ? WHERE row_id = ?', undef, 'N', $track_id);
        $db->do('UPDATE battute SET validation = ? WHERE flay_id = ?', undef, 'A', $track_id);
    }
    
    # Report finale
    my $report_data = $db->selectall_arrayref(
        'SELECT validation_fl, COUNT(*) as count FROM flay WHERE validation_fl IS NOT NULL GROUP BY validation_fl'
    );
    
    my %counts = map { $_->[0] => $_->[1] } @$report_data;
    
    $ctx->log(info => "Validazione completata: "
        . ($counts{Y} // 0) . " valide, " . ($counts{N} // 0) . " non valide",
        operation => 'valida_tracce_complete',
        valid_count => ($counts{Y} // 0),
        invalid_count => ($counts{N} // 0),
        total_count => scalar(@$unvalidated_tracks)
    );
    
    $db->disconnect;
    
    return {
        success => 1,
        message => 'Validazione completata',
        data => {
            valid_count => ($counts{Y} // 0),
            invalid_count => ($counts{N} // 0),
            total_count => scalar(@$unvalidated_tracks),
        }
    };
}

1;
