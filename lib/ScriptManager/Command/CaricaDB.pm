package ScriptManager::Command::CaricaDB;
use Mojo::Base -base, -signatures;

use DBI;
use File::Spec;
use File::Spec::Win32;
use File::Temp qw(tempdir);
use Log::Any ();
use Mojo::File 'path';
use Mojo::JSON 'decode_json';
use POSIX qw(tzset);
use Scalar::Util qw(looks_like_number);
use ScriptManager::Exception;
use ScriptManager::Service::MyISAMImport;
use Time::Local qw(timegm);

has 'process_runner';
has logger => sub { Log::Any->get_logger(category => 'ScriptManager::CaricaDB') };
has connect_db => sub { sub (@args) { DBI->connect(@args) } };

sub mrt ($class, $file) {
    my $config = decode_json(path($file)->slurp);
    die "MRT.json: airports e radars obbligatori\n"
        unless ref $config eq 'HASH' && ref $config->{airports} eq 'HASH'
        && ref $config->{radars} eq 'ARRAY' && @{$config->{radars}};
    for my $icao (keys %{$config->{airports}}) {
        die "MRT.json: aeroporto non valido\n"
            unless $icao =~ /\A[A-Z]{4}\z/ && defined $config->{airports}{$icao}
            && !ref $config->{airports}{$icao} && length $config->{airports}{$icao};
    }
    die "MRT.json: nessun aeroporto configurato\n" unless keys %{$config->{airports}};
    my %seen;
    for my $radar (@{$config->{radars}}) {
        die "MRT.json: radar non valido o duplicato\n"
            unless ref $radar eq 'HASH' && ($radar->{id} // '') =~ /\A[a-z][a-z0-9_]{1,63}\z/
            && !$seen{$radar->{id}}++ && defined $radar->{description} && !ref $radar->{description}
            && length $radar->{description};
        die "MRT.json: coordinate non valide\n"
            unless defined $radar->{x_m} && defined $radar->{y_m}
            && looks_like_number($radar->{x_m}) && looks_like_number($radar->{y_m})
            && abs($radar->{x_m}) < 1e8 && abs($radar->{y_m}) < 1e8;
        die "MRT.json: data revisione non valida\n"
            if defined $radar->{revision_date} && $radar->{revision_date} !~ /\A\d{4}-\d{2}-\d{2}\z/;
    }
    return $config;
}

sub configure_schema ($class, $schema, $directory) {
    my $file = $ENV{MRT_CONFIG_FILE} // $directory->child('local', 'MRT.json')->to_string;
    my $config = $class->mrt($file);
    my $field = $schema->{properties}{radar};
    $field->{enum} = [map { $_->{id} } @{$config->{radars}}];
    $field->{'x-enum-labels'} = {
        map { $_->{id} => $_->{description} . ' - revisione '
            . ($_->{revision_date} // 'non documentata') } @{$config->{radars}}
    };
    return;
}

sub input_files ($class, $root, $folder, $airports, $ctx = undef) {
    ScriptManager::Exception->throw('invalid_out_folder', 'Cartella OUT non valida: usare un percorso relativo alla radice')
        unless defined $folder && length $folder && !File::Spec->file_name_is_absolute($folder)
        && $folder !~ /\\/ && $folder !~ m{(?:\A|/)\.\.(?:/|\z)};
    my $requested = path($root)->to_abs->child(split m{/}, $folder);
    my $host_root = $ENV{FILE_OUT_ROOT};
    my $host_spec = defined $host_root && $host_root =~ /(?:\A[A-Za-z]:|\\)/
        ? 'File::Spec::Win32' : 'File::Spec';
    my $host_directory = defined $host_root && length $host_root
        ? $host_spec->canonpath($host_spec->catdir($host_root, split m{/}, $folder)) : undef;
    if ($ctx) {
        $ctx->log(info => "Cartella OUT nel container: $requested",
            operation => 'input_directory', container_path => "$requested");
        $ctx->log(info => "Cartella OUT sull'host: $host_directory",
            operation => 'input_mount', host_path => $host_directory) if defined $host_directory;
    }
    my $base = path($root)->realpath;
    ScriptManager::Exception->throw('out_folder_unavailable',
        'Radice dei file OUT non disponibile: verificare il mount FILE_OUT_ROOT e i permessi di lettura')
        unless defined $base && -d $base;
    my $directory = $base->child(split m{/}, $folder)->realpath;
    ScriptManager::Exception->throw('out_folder_unavailable',
        'Cartella OUT non disponibile: verificare la sottocartella selezionata e i permessi di lettura')
        unless defined $directory && -d $directory;
    my $relative = File::Spec->abs2rel("$directory", "$base");
    ScriptManager::Exception->throw('invalid_out_folder', 'Cartella OUT fuori dalla radice consentita')
        if $relative =~ m{\A\.\.(?:/|\z)};
    $ctx->log(info => "Ricerca dei file .OUT in $directory (non ricorsiva)",
        operation => 'input_scan', container_path => "$directory") if $ctx;
    my @files;
    for my $file (sort { "$a" cmp "$b" } @{$directory->list->to_array}) {
        next unless $file->basename =~ /\.out\z/i && -f $file;
        my $resolved = $file->realpath;
        my $rel = File::Spec->abs2rel("$resolved", "$base");
        ScriptManager::Exception->throw('invalid_out_file', 'File OUT fuori dalla radice consentita')
            if $rel =~ m{\A\.\.(?:/|\z)};
        my %codes;
        my $name = uc $file->basename;
        for my $icao (keys %$airports) {
            $codes{$icao} = 1 if $name =~ /(?:\A|[^A-Z])\Q$icao\E(?:[^A-Z]|\z)/;
        }
        ScriptManager::Exception->throw('invalid_out_filename',
            'Nome OUT senza aeroporto ICAO univoco: ' . $file->basename
            . '. Il nome deve contenere un solo codice ICAO tra quelli configurati in MRT.json')
            unless keys(%codes) == 1;
        push @files, {file => $resolved, icao => (keys %codes)[0]};
        if ($ctx) {
            $ctx->log(info => "File OUT individuato: $resolved", operation => 'input_file');
            $ctx->log(info => 'File OUT sull\'host: ' . $host_spec->catfile($host_directory, $file->basename),
                operation => 'input_file_mount') if defined $host_directory;
        }
    }
    ScriptManager::Exception->throw('out_files_missing',
        'Nessun file .OUT nella cartella selezionata. Verificare FILE_OUT_ROOT e la sottocartella richiesta: '
        . 'i file devono essere direttamente nella cartella, non nelle sue sottocartelle')
        unless @files;
    $ctx->log(info => scalar(@files) . ' file OUT da elaborare', operation => 'input_scan_complete') if $ctx;
    return \@files;
}

sub local_datetime ($class, $date, $time) {
    die "Data o ora OUT non valida\n" unless $date =~ /\A\d{8}\z/ && $time =~ /\A\d{6}\z/;
    my ($year, $month, $day) = $date =~ /(\d{4})(\d{2})(\d{2})/;
    my ($hour, $minute, $second) = $time =~ /(\d{2})(\d{2})(\d{2})/;
    $second = 59 if $second == 60;
    my $epoch = timegm($second, $minute, $hour, $day, $month - 1, $year - 1900);
    local $ENV{TZ} = 'Europe/Rome';
    tzset();
    my @local = localtime $epoch;
    my $result = sprintf '%d-%d-%d %d:%d:%d', $local[5] + 1900, $local[4] + 1, @local[3, 2, 1, 0];
    return $result;
}

sub track ($class, $line, $icao) {
    die "Intestazione OUT incompleta\n" unless length($line) >= 34;
    my ($flight, $aircraft, $departure, $arrival) = map {
        my $value = substr($line, $_->[0], $_->[1]);
        $value =~ s/\W//g;
        $value;
    } ([14, 7], [22, 4], [26, 4], [30, 4]);
    my $date = substr($line, 0, 8);
    my $time = substr($line, 8, 6);
    return [$flight, $date, $time, $aircraft, $departure, $arrival,
        $departure eq $icao ? 'D' : $arrival eq $icao ? 'A' : 'N',
        $class->local_datetime($date, $time)];
}

sub hit ($class, $sample, $date, $radar) {
    die "Battuta OUT incompleta\n" unless length($sample) == 24;
    my ($x, $y, $altitude) = map { substr($sample, $_, 6) } (0, 6, 12);
    die "Coordinate o altezza OUT non numeriche\n"
        unless looks_like_number($x) && looks_like_number($y) && looks_like_number($altitude);
    my $time = substr($sample, 18, 6);
    return [$time, $x / 64 * 1852.2 + $radar->{x_m}, $y / 64 * 1852.2 + $radar->{y_m},
        $altitude * 30.48, $class->local_datetime($date, $time)];
}

sub _seconds ($time) {
    return substr($time, 0, 2) * 3600 + substr($time, 2, 2) * 60 + substr($time, 4, 2);
}

sub _next_date ($date) {
    my ($year, $month, $day) = $date =~ /(\d{4})(\d{2})(\d{2})/;
    my @next = gmtime(timegm(0, 0, 0, $day, $month - 1, $year - 1900) + 86400);
    return sprintf '%04d%02d%02d', $next[5] + 1900, $next[4] + 1, $next[3];
}

sub _hit_key ($time, $x, $y, $height) {
    return undef if grep { !defined $_ } ($time, $x, $y, $height);
    $time =~ s/://g;
    return join ',', $time, map { sprintf '%.2f', $_ } ($x, $y, $height);
}

sub merge_midnight ($self, $ctx, $db, $airports, $source_sample) {
    $ctx->log(info => 'Ricerca tracce da unire a mezzanotte', operation => 'merge_midnight');
    my @codes = sort keys %$airports;
    my $placeholders = join ',', ('?') x @codes;
    my $early = $db->prepare(
        "SELECT row_id, flay, data, flay_operation FROM flay WHERE ora < ? AND validation_fl IS NULL "
        . "AND (airport_dep IN ($placeholders) OR airport_arr IN ($placeholders))"
    );
    $early->execute('00:10:00', @codes, @codes);
    my $previous = $db->prepare(
        'SELECT row_id FROM flay WHERE ora > ? AND flay = ? AND data = date_add(?, INTERVAL -1 DAY) AND flay_operation = ?'
    );
    my $hits = $db->prepare('SELECT * FROM battute WHERE flay_id = ? FOR UPDATE');
    my $delete = $db->prepare('DELETE FROM battute WHERE row_id = ? AND flay_id = ?');
    my $move = $db->prepare('UPDATE battute SET flay_id = ? WHERE flay_id = ?');
    my $mark = $db->prepare('UPDATE flay SET validation_fl = ?, validation_bt = ? WHERE row_id = ?');
    my $result = {deduplicated => 0, skipped => 0};
    while (my $row = $early->fetchrow_arrayref) {
        $ctx->check_cancel;
        $ctx->debug_operation("Ricerca candidati mezzanotte per traccia $row->[0]");
        $previous->execute('23:00:00', @$row[1, 2, 3]);
        my $matches = $previous->fetchall_arrayref;
        if (@$matches == 1) {
            my $previous_id = $matches->[0][0];
            $hits->execute($previous_id);
            my %prior;
            while (my $hit = $hits->fetchrow_hashref) {
                my $key = _hit_key(@$hit{qw(ora X_m Y_m H_m)});
                $prior{$key} = $hit if defined $key;
            }
            $hits->execute($row->[0]);
            my (@duplicates, $ambiguous);
            while (my $hit = $hits->fetchrow_hashref) {
                my $key = _hit_key(@$hit{qw(ora X_m Y_m H_m)});
                next unless defined $key && exists $prior{$key};
                my $old = $prior{$key};
                my $old_sample = $source_sample->($previous_id, $key);
                my $new_sample = $source_sample->($row->[0], $key);
                my @fields = grep { $_ ne 'row_id' && $_ ne 'flay_id' } keys %$hit;
                if (!defined $old_sample || !defined $new_sample || $old_sample ne $new_sample
                    || grep { defined($hit->{$_}) != defined($old->{$_})
                        || (defined($hit->{$_}) && $hit->{$_} ne $old->{$_}) } @fields) {
                    $ambiguous = 1;
                    last;
                }
                push @duplicates, $hit->{row_id};
            }
            if ($ambiguous) {
                $result->{skipped}++;
                $ctx->log(warning => "Tracce mezzanotte $row->[0] e $previous_id "
                    . "(volo $row->[1], data $row->[2]) non unite: "
                    . 'battute sovrapposte non verificabili; controllare i dati prima delle elaborazioni successive',
                    operation => 'merge_midnight_conflict', track_id => $row->[0], previous_track_id => $previous_id);
                next;
            }
            for my $id (@duplicates) {
                $ctx->check_cancel;
                my $removed = $delete->execute($id, $row->[0]);
                die "Battuta sovrapposta $id non eliminata\n" unless $removed == 1;
            }
            $result->{deduplicated} += @duplicates;
            $ctx->log(warning => "Tracce mezzanotte $row->[0] e $previous_id "
                . "(volo $row->[1], data $row->[2]): "
                . scalar(@duplicates) . ' battute OUT identiche sovrapposte rimosse dalla seconda traccia',
                operation => 'merge_midnight_duplicates', track_id => $row->[0], previous_track_id => $previous_id,
                count => scalar(@duplicates)) if @duplicates;
            $move->execute($previous_id, $row->[0]);
            $mark->execute('M', 0, $row->[0]);
            $ctx->log(info => "Traccia mezzanotte $row->[0] unita a $previous_id");
        } elsif (@$matches > 1) {
            $ctx->log(warning => "Traccia $row->[0]: piu candidati prima della mezzanotte, nessuna unione");
        }
    }
    $ctx->log(info => 'Unione delle tracce a mezzanotte completata', operation => 'merge_midnight_complete');
    return $result;
}

sub _store_track ($self, $db, $insert, $find, $track) {
    my $ok = eval { $insert->execute(@$track); 1 };
    if ($ok) {
        my $id = $db->last_insert_id(undef, undef, 'flay', undef);
        die "Identificativo traccia MySQL mancante\n" unless defined $id;
        return ($id, 0);
    }
    my $error = $@;
    die $error if ScriptManager::Exception->caught($error) || ($insert->err // 0) != 1062;
    $find->execute(@$track[0 .. 2]);
    my $row = $find->fetchrow_arrayref;
    ScriptManager::Exception->throw('mysql_duplicate',
        'Traccia duplicata non individuabile tramite volo, data e ora; caricamento annullato')
        unless $row && defined $row->[0];
    return ($row->[0], 1);
}

sub _complete_track ($self, $ctx, $db, $id, $track) {
    my @fields = qw(aircraft airport_dep airport_arr flay_operation data_ora_italy);
    my @current = $db->selectrow_array(
        'SELECT ' . join(', ', @fields) . ' FROM flay WHERE row_id = ?', undef, $id);
    ScriptManager::Exception->throw('mysql_schema', "Traccia $id non piu disponibile durante il completamento")
        unless @current;
    my (@updates, @values, @changed);
    for my $i (0 .. $#fields) {
        next if defined $current[$i] && $current[$i] =~ /\S/;
        my $value = $track->[$i + 3];
        next unless defined $value && $value =~ /\S/;
        push @updates, $db->quote_identifier($fields[$i]) . ' = ?';
        push @values, $value;
        push @changed, $fields[$i];
    }
    if (@updates) {
        $db->do('UPDATE flay SET ' . join(', ', @updates) . ' WHERE row_id = ?', undef, @values, $id);
    }
    $ctx->log(info => "Traccia $id senza battute: "
        . (@changed ? 'completati i campi vuoti ' . join(', ', @changed) : 'metadati invariati')
        . '; battute destinate alla tabella principale',
        operation => 'complete_empty_track', track_id => $id);
}

sub run ($self, $ctx, $params) {
    my $config_file = $ENV{MRT_CONFIG_FILE} // 'config/local/MRT.json';
    $ctx->log(info => "Lettura configurazione radar: $config_file", operation => 'radar_config');
    my $config = __PACKAGE__->mrt($config_file);
    $ctx->log(info => 'Validazione radar e database richiesti', operation => 'validate_parameters');
    my ($radar) = grep { $_->{id} eq $params->{radar} } @{$config->{radars}};
    ScriptManager::Exception->throw('invalid_radar', 'Radar/revisione non disponibile') unless $radar;
    ScriptManager::Exception->throw('invalid_database', 'Nome database MySQL non valido')
        unless ($params->{database} // '') =~ /\A[A-Za-z0-9_]{1,64}\z/;
    my $files = __PACKAGE__->input_files($ENV{SCRIPT_MANAGER_OUT_ROOT} // 'var/input',
        $params->{folder}, $config->{airports}, $ctx);
    $ctx->log(info => 'Verifica configurazione di connessione MySQL (credenziali omesse)',
        operation => 'mysql_config');
    for my $key (qw(MYSQL_HOST MYSQL_USER MYSQL_PASSWORD)) {
        ScriptManager::Exception->throw('mysql_config', "Configurazione $key mancante")
            unless defined $ENV{$key} && length $ENV{$key};
    }
    my $port = $ENV{MYSQL_PORT} // 3306;
    ScriptManager::Exception->throw('mysql_config', 'Host o porta MySQL non validi')
        unless $ENV{MYSQL_HOST} =~ /\A[A-Za-z0-9.:-]+\z/ && $port =~ /\A\d+\z/ && $port > 0 && $port <= 65535;
    $ctx->log(info => "Connessione MySQL: host $ENV{MYSQL_HOST}, porta $port, database $params->{database}",
        operation => 'mysql_connect');
    my $db;
    my $connected = eval {
        $db = $self->connect_db->(
            "DBI:MariaDB:database=$params->{database};host=$ENV{MYSQL_HOST};port=$port",
            $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD},
            {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_local_infile => 1,
                mariadb_server_prepare => 0, mariadb_auto_reconnect => 0}
        );
        1;
    };
    my $connect_error = $@;
    my $mysql_error = $DBI::err;
    unless ($connected && $db) {
        die $connect_error if ScriptManager::Exception->caught($connect_error);
        die $connect_error if !$connected && !defined $mysql_error;
        my ($code, $message) = ('mysql_connect', 'Connessione MySQL fallita: verificare host, porta e configurazione del server');
        if (defined $mysql_error) {
            if ($mysql_error == 1045 || $mysql_error == 1698) {
                $code = 'mysql_authentication';
                $message = 'Autenticazione MySQL rifiutata: verificare MYSQL_USER e MYSQL_PASSWORD '
                    . 'e che l\'account sia autorizzato a collegarsi dal computer che esegue Docker';
            } elsif ($mysql_error == 1044) {
                $code = 'mysql_database_access';
                $message = 'Accesso al database MySQL negato: verificare i permessi dell\'account sul database selezionato';
            } elsif ($mysql_error == 1049) {
                $code = 'mysql_database_missing';
                $message = 'Database MySQL selezionato inesistente: verificare il nome e il server di destinazione';
            }
            $message .= " (codice MySQL $mysql_error)";
        }
        ScriptManager::Exception->throw($code, $message);
    }
    $ctx->log(info => 'Connessione MySQL riuscita; verifica tabelle flay, battute e battute_doppie',
        operation => 'mysql_schema');
    my $engines = $db->selectall_arrayref(
        'SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME IN (?, ?, ?)',
        undef, $params->{database}, 'flay', 'battute', 'battute_doppie'
    );
    my %engines = map { $_->[0] => $_->[1] // '' } @$engines;
    my $myisam = !grep { ($engines{$_} // '') ne 'MyISAM' } qw(flay battute battute_doppie);
    my $innodb = !grep { ($engines{$_} // '') ne 'InnoDB' } qw(flay battute battute_doppie);
    ScriptManager::Exception->throw('mysql_schema', 'Servono flay, battute e battute_doppie tutte MyISAM oppure tutte InnoDB; '
        . 'motori misti, tabelle mancanti o altri motori non sono supportati') unless $myisam || $innodb;
    my $session = $myisam ? ScriptManager::Service::MyISAMImport->new(db => $db, ctx => $ctx) : undef;
    $ctx->log(info => 'Verifica abilitazione LOCAL INFILE sul server MySQL', operation => 'mysql_local_infile');
    my ($local_infile) = $db->selectrow_array('SELECT @@local_infile');
    ScriptManager::Exception->throw('mysql_local_infile', 'Abilitare local_infile sul server MySQL') unless $local_infile;
    my $temporary = tempdir(CLEANUP => 1);
    my $csv = path($temporary, 'battute.csv');
    my $duplicates_csv = path($temporary, 'battute_doppie.csv');
    $ctx->log(info => "Creazione file temporaneo battute: $csv", operation => 'create_csv');
    open my $output, '>', "$csv" or die "Creazione file battute fallita: $!\n";
    open my $duplicates_output, '>', "$duplicates_csv" or die "Creazione file battute doppie fallita: $!\n";
    my ($tracks, $hits, $processed_files) = (0, 0, 0);
    my ($duplicate_tracks, $duplicate_hits) = (0, 0);
    my $repaired_tracks = 0;
    my $skipped_tracks = 0;
    my $skipped_hits = 0;
    my %new_tracks;
    my %midnight_samples;
    my $merge_result = {deduplicated => 0, skipped => 0};
    my %loaded_airports;
    $ctx->log(info => "Radar $radar->{id}, revisione " . ($radar->{revision_date} // 'non documentata')
        . ", origine $radar->{x_m}/$radar->{y_m}; record duplicati destinati a battute_doppie");
    my ($transaction_started, $committed) = (0, 0);
    my $ok = eval {
        if ($session) {
            $session->prepare;
        } else {
            $ctx->log(info => 'Avvio transazione MySQL', operation => 'begin_transaction');
            $db->begin_work;
            $transaction_started = 1;
        }
        my $flay_table = $session ? $session->table('flay') : 'flay';
        my $battute_table = $session ? $session->table('battute') : 'battute';
        my $duplicates_table = $session ? $session->table('battute_doppie') : 'battute_doppie';
        $ctx->log(info => 'Preparazione inserimento tracce in flay', operation => 'prepare_tracks');
        my $insert = $db->prepare(
            "INSERT INTO $flay_table (flay,data,ora,aircraft,airport_dep,airport_arr,flay_operation,data_ora_italy) VALUES (?,?,?,?,?,?,?,?)"
        );
        my $find = $db->prepare(
            "SELECT row_id FROM $flay_table WHERE flay = ? AND data = ? AND ora = ?"
            . ($session ? '' : ' FOR UPDATE')
        );
        my %seen_tracks;
        for my $entry (@$files) {
            $ctx->check_cancel;
            $ctx->log(info => 'Apertura OUT: ' . $entry->{file} . ': ' . $config->{airports}{$entry->{icao}},
                operation => 'read_file');
            open my $input, '<', $entry->{file}->to_string or die "Lettura OUT fallita: $!\n";
            my ($file_tracks, $file_hits, $line_number) = (0, 0, 0);
            while (my $line = <$input>) {
                $line_number++;
                $ctx->check_cancel;
                next if $line =~ /\A\r?\n\z/;
                $line =~ s/\r\n\z/\n/;
                if ($line =~ /\n\z/ && length($line) == 35) {
                    my $track = __PACKAGE__->track($line, $entry->{icao});
                    $skipped_tracks++;
                    $ctx->log(warning => "Traccia senza battute ignorata: $entry->{file}, riga $line_number; "
                        . "volo $track->[0], data $track->[1], ora $track->[2]; nessun dato inserito per questo record",
                        operation => 'skip_empty_track');
                    next;
                }
                die "Record OUT incompleto: " . $entry->{file}->basename . "\n"
                    unless $line =~ /\n\z/ && length($line) >= 59 && (length($line) - 35) % 24 == 0;
                $ctx->debug_operation("Validazione e inserimento traccia: $entry->{file}, riga $line_number");
                my $track = __PACKAGE__->track($line, $entry->{icao});
                $loaded_airports{$entry->{icao}} = 1;
                my ($track_id, $duplicate) = $self->_store_track($db, $insert, $find, $track);
                my $repaired = 0;
                if (!$session && $duplicate && !$seen_tracks{$track_id}) {
                    my ($hit_id) = $db->selectrow_array(
                        'SELECT row_id FROM battute WHERE flay_id = ? LIMIT 1 FOR UPDATE', undef, $track_id);
                    unless (defined $hit_id) {
                        $self->_complete_track($ctx, $db, $track_id, $track);
                        $repaired_tracks++;
                        $repaired = 1;
                        $duplicate = 0;
                    }
                }
                $seen_tracks{$track_id} = 1;
                if ($duplicate) {
                    $duplicate_tracks++;
                    $ctx->log(warning => "Record duplicato: $entry->{file}, riga $line_number; "
                        . "volo $track->[0], data $track->[1], ora $track->[2]; battute destinate a battute_doppie",
                        operation => 'duplicate_track', track_id => $track_id);
                } elsif (!$repaired) {
                    $tracks++;
                    $file_tracks++;
                    $new_tracks{$track_id} = 1;
                }
                my %seen_hits;
                my $hit_date = $track->[1];
                my $last_time = _seconds($track->[2]);
                my $crossed_midnight = 0;
                my $track_time = _seconds($track->[2]);
                my $remember_samples = !$duplicate && !$repaired
                    && ($track_time > 23 * 3600 || $track_time < 10 * 60);
                for (my $offset = 34; $offset + 24 < length($line); $offset += 24) {
                    $ctx->debug_operation("Conversione e scrittura battuta: traccia $track_id, offset $offset");
                    my $sample = substr($line, $offset, 24);
                    my $hit = __PACKAGE__->hit($sample, $hit_date, $radar);
                    my $seconds = _seconds($hit->[0]);
                    if ($seconds - $last_time < -12 * 3600) {
                        die "Attraversamenti multipli della mezzanotte: $entry->{file}, riga $line_number\n"
                            if $crossed_midnight;
                        $hit_date = _next_date($hit_date);
                        $hit->[4] = __PACKAGE__->local_datetime($hit_date, $hit->[0]);
                        $crossed_midnight = 1;
                    } elsif ($crossed_midnight && $seconds - $last_time > 12 * 3600) {
                        die "Orari OUT ambigui dopo la mezzanotte: $entry->{file}, riga $line_number\n";
                    }
                    $last_time = $seconds;
                    my $key = join(',', @$hit[0 .. 3]);
                    my $index = ($offset - 34) / 24 + 1;
                    if (my $previous = $seen_hits{$key}) {
                        die "Battuta duplicata con contenuto diverso nella traccia $track->[0]\n"
                            unless $sample eq $previous->{sample};
                        $skipped_hits++;
                        $ctx->log(warning => "Battuta identica ripetuta ignorata: $entry->{file}, riga $line_number; "
                            . "volo $track->[0], data $track->[1], ora battuta $hit->[0]; "
                            . "battuta $index, prima occorrenza $previous->{index}",
                            operation => 'skip_duplicate_hit', track_id => $track_id);
                        next;
                    }
                    $seen_hits{$key} = {sample => $sample, index => $index};
                    if ($remember_samples) {
                        my $stored_key = _hit_key(@$hit[0 .. 3]);
                        $midnight_samples{$track_id}{$stored_key} = $sample;
                    }
                    my @fields = (undef, $hit->[0], $track_id, $hit->[1], $hit->[2],
                        $hit->[3] > 0 ? $hit->[3] : undef, $hit->[3],
                        (undef) x 5, $hit->[4]);
                    my $destination = $duplicate ? $duplicates_output : $output;
                    print {$destination} join(',', map { defined $_ ? $_ : '\\N' } @fields), "\n"
                        or die "Scrittura battute fallita: $!\n";
                    $hits++;
                    $file_hits++;
                    $duplicate_hits++ if $duplicate;
                }
            }
            close $input or die "Chiusura OUT fallita: $!\n";
            $ctx->log(info => "OUT completato e chiuso: $entry->{file}; $file_tracks tracce, $file_hits battute",
                operation => 'read_file_complete');
            $processed_files++;
            $ctx->progress(int(80 * $processed_files / scalar(@$files)), 'Lettura file OUT');
        }
        $ctx->log(info => "Chiusura CSV: $tracks tracce e $hits battute preparate", operation => 'close_csv');
        close $output or die "Chiusura battute fallita: $!\n";
        close $duplicates_output or die "Chiusura battute doppie fallita: $!\n";
        die "Nessuna traccia nei file OUT\n" unless $tracks || $duplicate_tracks || $repaired_tracks || $skipped_tracks;
        $ctx->check_cancel;
        for my $load ([$battute_table, $csv, $hits - $duplicate_hits],
                      [$duplicates_table, $duplicates_csv, $duplicate_hits]) {
            next unless $load->[2];
            $ctx->log(info => "Caricamento CSV nella tabella $load->[0] (LOAD DATA LOCAL INFILE)", operation => 'load_hits');
            $db->do("LOAD DATA LOCAL INFILE ? INTO TABLE $load->[0] FIELDS TERMINATED BY ',' "
                . '(row_id,ora,flay_id,X_m,Y_m,Z_m,H_m,A_m,path,vel,hmod,validation,time_italy)', undef, "$load->[1]");
            $ctx->log(info => 'Verifica warning MySQL dopo il caricamento', operation => 'check_mysql_warnings');
            my $warnings = $db->selectall_arrayref('SHOW WARNINGS');
            $ctx->log(warning => "Warning MySQL: codice $warnings->[0][1]; caricamento da annullare") if @$warnings;
            die "Caricamento battute rifiutato (duplicati o dati non validi), codice MySQL $warnings->[0][1]\n" if @$warnings;
        }
        my $merge_midnight = $params->{merge_midnight} && ($tracks || $duplicate_tracks || $repaired_tracks);
        my $source_sample = sub ($id, $key) {
            if ($session) {
                my ($min, $max) = @{$session->bounds->{flay}};
                return undef unless $min && $id >= $min && $id <= $max;
                $id -= $min - 1;
            } else {
                return undef unless $new_tracks{$id};
            }
            return $midnight_samples{$id}{$key};
        };
        if ($session) {
            my $merge = $merge_midnight
                ? sub { $merge_result = $self->merge_midnight($ctx, $db, \%loaded_airports, $source_sample) } : undef;
            $session->publish(\%loaded_airports, $merge,
                sub ($id, $track) { $self->_complete_track($ctx, $db, $id, $track) });
            $tracks -= $session->reused_tracks;
            $repaired_tracks += $session->repaired_tracks;
            $duplicate_tracks += $session->reused_tracks - $session->repaired_tracks;
            $duplicate_hits += $session->diverted_hits;
        } else {
            $merge_result = $self->merge_midnight($ctx, $db, \%loaded_airports, $source_sample) if $merge_midnight;
            $ctx->check_cancel;
            $ctx->log(info => 'Conferma transazione MySQL (commit)', operation => 'commit');
            {
                local $SIG{ALRM} = 'IGNORE';
                alarm 0;
                $db->commit;
                $committed = 1;
            }
            $ctx->log(info => 'Transazione MySQL confermata', operation => 'commit_complete');
        }
        $ctx->log(info => 'Unione a mezzanotte disabilitata') unless $params->{merge_midnight};
        if ($session) {
            $ctx->log(info => 'Chiusura connessione MySQL', operation => 'mysql_disconnect');
            $db->disconnect;
            $ctx->progress(100, 'Caricamento MySQL completato');
        }
        1;
    };
    if (!$ok) {
        my $error = $@;
        my $mysql_error = $DBI::err;
        if ($session) {
            $self->logger->error('[ERROR] [exec=' . $ctx->execution_id . "] Caricamento MyISAM interrotto: $error");
            my $recovered = eval { $session->abort; 1 };
            $error = $@ unless $recovered;
            my $disconnected = eval { $db->disconnect; 1 };
            $ctx->log(critical => 'Chiusura connessione MySQL fallita dopo l\'errore') unless $disconnected;
            if ($recovered && !ScriptManager::Exception->caught($error)) {
                my $duplicate = defined $mysql_error && $mysql_error == 1062;
                $error = ScriptManager::Exception->new(
                    code => $duplicate ? 'mysql_duplicate' : 'mysql_load_failed',
                    message => ($duplicate ? 'Duplicati rilevati nei file OUT o nel database. ' : 'Caricamento MyISAM fallito. ')
                        . 'I nuovi dati non sono stati mantenuti; '
                        . "consultare i log app/worker per l'esecuzione " . $ctx->execution_id,
                );
            }
        } elsif ($committed) {
            $self->logger->error('[ERROR] [exec=' . $ctx->execution_id . "] Errore dopo il commit MySQL: $error");
            $error = ScriptManager::Exception->new(
                code => 'mysql_already_published',
                message => 'Caricamento MySQL gia confermato; verificare i dati prima di riprovare');
        } elsif ($transaction_started) {
            $ctx->log(error => 'Caricamento interrotto: annullamento transazione MySQL (rollback)', operation => 'rollback');
            my $rolled_back = eval { $db->rollback; 1 };
            if ($rolled_back) {
                $ctx->log(info => 'Rollback MySQL completato; caricamento non confermato', operation => 'rollback_complete');
            } else {
                $ctx->log(critical => 'Rollback MySQL fallito: verificare il database prima di riprovare',
                    operation => 'rollback_failed');
                $error = ScriptManager::Exception->new(
                    code => 'mysql_recovery_required',
                    message => 'Rollback MySQL non verificato dopo il timeout: verificare il database prima di riprovare')
                    if ScriptManager::Exception->caught($error, 'timed_out');
            }
        }
        die $error;
    }
    unless ($session) {
        $ctx->log(info => 'Chiusura connessione MySQL', operation => 'mysql_disconnect');
        $db->disconnect;
        $ctx->progress(100, 'Caricamento MySQL completato');
    }
    my $message = "Caricate $tracks tracce e $hits battute";
    $message .= "; $repaired_tracks tracce preesistenti senza battute completate" if $repaired_tracks;
    $message .= "; $duplicate_tracks record duplicati, $duplicate_hits battute in battute_doppie" if $duplicate_tracks;
    $message .= "; $skipped_tracks tracce senza battute ignorate" if $skipped_tracks;
    $message .= "; $skipped_hits battute identiche ripetute ignorate" if $skipped_hits;
    $message .= "; $merge_result->{deduplicated} battute sovrapposte rimosse durante l'unione a mezzanotte"
        if $merge_result->{deduplicated};
    $message .= "; $merge_result->{skipped} unioni a mezzanotte non eseguite: verificare le sovrapposizioni"
        if $merge_result->{skipped};
    return {success => 1, message => $message, data => {
        tracks => $tracks, hits => $hits, duplicate_tracks => $duplicate_tracks, duplicate_hits => $duplicate_hits,
        skipped_tracks => $skipped_tracks,
        repaired_tracks => $repaired_tracks,
        skipped_hits => $skipped_hits,
        ($merge_result->{deduplicated} ? (merged_duplicate_hits => $merge_result->{deduplicated}) : ()),
        ($merge_result->{skipped} ? (midnight_merge_conflicts => $merge_result->{skipped}) : ()),
    }};
}

1;
