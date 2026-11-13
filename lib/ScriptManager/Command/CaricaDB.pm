package ScriptManager::Command::CaricaDB;
use Mojo::Base -base, -signatures;

use DBI;
use File::Spec;
use File::Spec::Win32;
use File::Temp qw(tempdir);
use Mojo::File 'path';
use Mojo::JSON 'decode_json';
use POSIX qw(tzset);
use Scalar::Util qw(looks_like_number);
use ScriptManager::Exception;
use Time::Local qw(timegm);

has [qw(logger process_runner)];
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

sub merge_midnight ($self, $ctx, $db, $airports) {
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
    my $move = $db->prepare('UPDATE battute SET flay_id = ? WHERE flay_id = ?');
    my $mark = $db->prepare('UPDATE flay SET validation_fl = ?, validation_bt = ? WHERE row_id = ?');
    while (my $row = $early->fetchrow_arrayref) {
        $ctx->check_cancel;
        $ctx->debug_operation("Ricerca candidati mezzanotte per traccia $row->[0]");
        $previous->execute('23:00:00', @$row[1, 2, 3]);
        my $matches = $previous->fetchall_arrayref;
        if (@$matches == 1) {
            $move->execute($matches->[0][0], $row->[0]);
            $mark->execute('M', 0, $row->[0]);
            $ctx->log(info => "Traccia mezzanotte $row->[0] unita a $matches->[0][0]");
        } elsif (@$matches > 1) {
            $ctx->log(warning => "Traccia $row->[0]: piu candidati prima della mezzanotte, nessuna unione");
        }
        $ctx->log(info => 'Unione delle tracce a mezzanotte completata', operation => 'merge_midnight_complete');
    }
    return;
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
    my $db = $self->connect_db->(
        "DBI:MariaDB:database=$params->{database};host=$ENV{MYSQL_HOST};port=$port",
        $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD},
        {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_local_infile => 1, mariadb_server_prepare => 0}
    ) or ScriptManager::Exception->throw('mysql_connect', 'Connessione MySQL fallita');
    $ctx->log(info => 'Connessione MySQL riuscita; verifica tabelle flay e battute',
        operation => 'mysql_schema');
    my $engines = $db->selectall_arrayref(
        'SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME IN (?, ?)',
        undef, $params->{database}, 'flay', 'battute'
    );
    ScriptManager::Exception->throw('mysql_schema', 'Servono flay e battute con motore InnoDB per annullare caricamenti errati')
        unless @$engines == 2 && !grep { ($_->[1] // '') ne 'InnoDB' } @$engines;
    $ctx->log(info => 'Verifica abilitazione LOCAL INFILE sul server MySQL', operation => 'mysql_local_infile');
    my ($local_infile) = $db->selectrow_array('SELECT @@local_infile');
    ScriptManager::Exception->throw('mysql_local_infile', 'Abilitare local_infile sul server MySQL') unless $local_infile;
    my $temporary = tempdir(CLEANUP => 1);
    my $csv = path($temporary, 'battute.csv');
    $ctx->log(info => "Creazione file temporaneo battute: $csv", operation => 'create_csv');
    open my $output, '>', "$csv" or die "Creazione file battute fallita: $!\n";
    my ($tracks, $hits, $processed_files) = (0, 0, 0);
    my %loaded_airports;
    $ctx->log(info => "Radar $radar->{id}, revisione " . ($radar->{revision_date} // 'non documentata')
        . ", origine $radar->{x_m}/$radar->{y_m}; duplicati vietati");
    $ctx->log(info => 'Avvio transazione MySQL', operation => 'begin_transaction');
    $db->begin_work;
    my $ok = eval {
        $ctx->log(info => 'Preparazione inserimento tracce in flay', operation => 'prepare_tracks');
        my $insert = $db->prepare(
            'INSERT INTO flay (flay,data,ora,aircraft,airport_dep,airport_arr,flay_operation,data_ora_italy) VALUES (?,?,?,?,?,?,?,?)'
        );
        for my $entry (@$files) {
            $ctx->check_cancel;
            $loaded_airports{$entry->{icao}} = 1;
            $ctx->log(info => 'Apertura OUT: ' . $entry->{file} . ': ' . $config->{airports}{$entry->{icao}},
                operation => 'read_file');
            open my $input, '<', $entry->{file}->to_string or die "Lettura OUT fallita: $!\n";
            my ($file_tracks, $file_hits, $line_number) = (0, 0, 0);
            while (my $line = <$input>) {
                $line_number++;
                $ctx->check_cancel;
                next if $line =~ /\A\r?\n\z/;
                $line =~ s/\r\n\z/\n/;
                die "Record OUT incompleto: " . $entry->{file}->basename . "\n"
                    unless $line =~ /\n\z/ && length($line) >= 59 && (length($line) - 35) % 24 == 0;
                $ctx->debug_operation("Validazione e inserimento traccia: $entry->{file}, riga $line_number");
                my $track = __PACKAGE__->track($line, $entry->{icao});
                $insert->execute(@$track);
                my $track_id = $db->last_insert_id(undef, undef, 'flay', undef);
                die "Identificativo traccia MySQL mancante\n" unless defined $track_id;
                $tracks++;
                $file_tracks++;
                my %seen_hits;
                for (my $offset = 34; $offset + 24 < length($line); $offset += 24) {
                    $ctx->debug_operation("Conversione e scrittura battuta: traccia $track_id, offset $offset");
                    my $hit = __PACKAGE__->hit(substr($line, $offset, 24), $track->[1], $radar);
                    die "Battuta duplicata nella traccia $track->[0]\n"
                        if $seen_hits{join(',', @$hit[0 .. 3])}++;
                    my @fields = (undef, $hit->[0], $track_id, $hit->[1], $hit->[2],
                        $hit->[3] > 0 ? $hit->[3] : undef, $hit->[3],
                        (undef) x 5, $hit->[4]);
                    print {$output} join(',', map { defined $_ ? $_ : '\\N' } @fields), "\n"
                        or die "Scrittura battute fallita: $!\n";
                    $hits++;
                    $file_hits++;
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
        die "Nessuna traccia nei file OUT\n" unless $tracks;
        $ctx->check_cancel;
        $ctx->log(info => 'Caricamento CSV nella tabella battute (LOAD DATA LOCAL INFILE)', operation => 'load_hits');
        $db->do("LOAD DATA LOCAL INFILE ? INTO TABLE battute FIELDS TERMINATED BY ','", undef, "$csv");
        $ctx->log(info => 'Verifica warning MySQL dopo il caricamento', operation => 'check_mysql_warnings');
        my $warnings = $db->selectall_arrayref('SHOW WARNINGS');
        $ctx->log(warning => "Warning MySQL: codice $warnings->[0][1]; caricamento da annullare") if @$warnings;
        die "Caricamento battute rifiutato (duplicati o dati non validi), codice MySQL $warnings->[0][1]\n" if @$warnings;
        $self->merge_midnight($ctx, $db, \%loaded_airports) if $params->{merge_midnight};
        $ctx->log(info => 'Unione a mezzanotte disabilitata') unless $params->{merge_midnight};
        $ctx->check_cancel;
        $ctx->log(info => 'Conferma transazione MySQL (commit)', operation => 'commit');
        $db->commit;
        $ctx->log(info => 'Transazione MySQL confermata', operation => 'commit_complete');
        1;
    };
    if (!$ok) {
        my $error = $@;
        $ctx->log(error => 'Caricamento interrotto: annullamento transazione MySQL (rollback)', operation => 'rollback');
        my $rolled_back = eval { $db->rollback; 1 };
        if ($rolled_back) {
            $ctx->log(info => 'Rollback MySQL completato; caricamento non confermato', operation => 'rollback_complete');
        } else {
            $ctx->log(critical => 'Rollback MySQL fallito: verificare il database prima di riprovare',
                operation => 'rollback_failed');
        }
        die $error;
    }
    $ctx->log(info => 'Chiusura connessione MySQL', operation => 'mysql_disconnect');
    $db->disconnect;
    $ctx->progress(100, 'Caricamento MySQL completato');
    return {success => 1, message => "Caricate $tracks tracce e $hits battute", data => {tracks => $tracks, hits => $hits}};
}

1;
