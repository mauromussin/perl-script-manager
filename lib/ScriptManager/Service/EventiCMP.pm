package ScriptManager::Service::EventiCMP;
use Mojo::Base -base, -signatures;

use DBI;
use Digest::SHA 'sha256_hex';
use Encode qw(decode FB_CROAK);
use File::Find;
use File::Spec;
use Mojo::File 'path';
use ScriptManager::Exception;
use Time::Local qw(timegm timelocal);
use POSIX qw(strftime tzset);

has connect_db => sub { sub (@args) { DBI->connect(@args) } };

sub connect ($self, $database) {
    ScriptManager::Exception->throw('invalid_database', 'Nome database MySQL non valido')
        unless ($database // '') =~ /\A[A-Za-z0-9_]{1,64}\z/;
    for my $key (qw(MYSQL_HOST MYSQL_USER MYSQL_PASSWORD)) {
        ScriptManager::Exception->throw('mysql_config', "Configurazione $key mancante")
            unless defined $ENV{$key} && length $ENV{$key};
    }
    my $port = $ENV{MYSQL_PORT} // 3306;
    ScriptManager::Exception->throw('mysql_config', 'Host o porta MySQL non validi')
        unless $ENV{MYSQL_HOST} =~ /\A[A-Za-z0-9.:-]+\z/ && $port =~ /\A\d+\z/ && $port > 0 && $port <= 65535;
    my $db = eval {
        $self->connect_db->(
            "DBI:MariaDB:database=$database;host=$ENV{MYSQL_HOST};port=$port",
            $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD},
            {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_auto_reconnect => 0});
    };
    my $error = $@;
    die $error if ScriptManager::Exception->caught($error);
    ScriptManager::Exception->throw('mysql_connect',
        'Connessione MySQL fallita: verificare host, porta, credenziali e database')
        unless $db;
    return $db;
}

sub stations ($self, $db, $airport) {
    ScriptManager::Exception->throw('invalid_airport', 'Aeroporto non valido')
        unless ($airport // '') =~ /\A(?:LIMC|LIML|LIME|LIPO)\z/;
    return $db->selectall_arrayref(
        'SELECT s.row_id, s.c_cab, s.name AS nome, a.nome_aerop AS aeroporto '
        . 'FROM anagrafica.stazioni s '
        . 'LEFT JOIN anagrafica.aeroporti a ON a.row_id = s.aeroporti_id '
        . 'WHERE a.nome_aerop = ? OR a.row_id IS NULL ORDER BY a.nome_aerop IS NULL, s.name, s.row_id',
        {Slice => {}}, $airport);
}

sub files ($self) {
    my $root = path($ENV{SCRIPT_MANAGER_TXT_ROOT} // '/app/var/input-txt')->realpath;
    ScriptManager::Exception->throw('txt_root_unavailable',
        'Cartella TXT non disponibile: verificare il mount FILE_TXT_ROOT e i permessi')
        unless defined $root && -d $root && -r $root;
    my @files;
    find({no_chdir => 1, wanted => sub {
        my $file = $File::Find::name;
        if (-d $file) {
            ScriptManager::Exception->throw('invalid_txt_file', "Cartella simbolica non ammessa: $file") if -l $file;
            ScriptManager::Exception->throw('txt_read', "Cartella TXT non accessibile: $file")
                unless -r $file && -x $file;
            return;
        }
        return unless /\.txt\z/i;
        ScriptManager::Exception->throw('invalid_txt_file', "Collegamento simbolico non ammesso: $file") if -l $file;
        return unless -f $file;
        my $real = path($file)->realpath;
        my $relative = defined $real ? File::Spec->abs2rel("$real", "$root") : '..';
        ScriptManager::Exception->throw('invalid_txt_file', 'File TXT fuori dalla cartella consentita')
            if $relative =~ m{\A\.\.(?:/|\z)} || File::Spec->file_name_is_absolute($relative);
        open my $fh, '<:raw', $real or ScriptManager::Exception->throw('txt_read', "Impossibile leggere $relative: $!");
        my $sha = Digest::SHA->new(256)->addfile($fh)->hexdigest;
        close $fh or ScriptManager::Exception->throw('txt_read', "Impossibile chiudere $relative: $!");
        push @files, {name => $relative, sha256 => $sha};
    }}, "$root");
    ScriptManager::Exception->throw('txt_files_missing', 'Nessun file TXT nella cartella configurata')
        unless @files;
    return [sort { $a->{name} cmp $b->{name} } @files];
}

sub preview ($self, $database, $airport) {
    my $files = $self->files;
    my $db = $self->connect($database);
    my $stations = $self->stations($db, $airport);
    $db->disconnect;
    ScriptManager::Exception->throw('stations_missing', 'Nessuna stazione disponibile per questo aeroporto')
        unless @$stations;
    return {files => $files, stations => $stations};
}

sub read_events ($self, $name, $expected_sha) {
    my $root = path($ENV{SCRIPT_MANAGER_TXT_ROOT} // '/app/var/input-txt')->realpath;
    ScriptManager::Exception->throw('invalid_txt_file', 'Percorso TXT non valido')
        unless defined $root && defined $name && $name =~ /\.txt\z/i
        && !File::Spec->file_name_is_absolute($name) && $name !~ /\\/
        && $name !~ m{(?:\A|/)\.{1,2}(?:/|\z)};
    my $file = $root->child(split m{/}, $name);
    my $real = $file->realpath;
    my $rel = defined $real ? File::Spec->abs2rel("$real", "$root") : '..';
    ScriptManager::Exception->throw('invalid_txt_file', "File TXT non disponibile o fuori dalla cartella: $name")
        if !defined $real || !-f $real || !-r $real || -l $file || $rel =~ m{\A\.\.(?:/|\z)};
    open my $fh, '<:raw', $real or ScriptManager::Exception->throw('txt_read', "Impossibile leggere $name: $!");
    local $/;
    my $bytes = <$fh>;
    close $fh or ScriptManager::Exception->throw('txt_read', "Impossibile chiudere $name: $!");
    $bytes //= '';
    ScriptManager::Exception->throw('txt_changed', "Il file $name e cambiato: ripetere l'associazione")
        unless defined $expected_sha && sha256_hex($bytes) eq $expected_sha;
    my $text = eval { decode('UTF-8', $bytes, FB_CROAK) };
    ScriptManager::Exception->throw('txt_format', "Codifica UTF-8 non valida in $name") if $@;
    my @lines = split /\n/, $text, -1;
    s/\r\z// for @lines;
    s/^\x{FEFF}// for @lines;
    my $header = $lines[1] // '';
    my $offset;
    if ($header =~ m{\A(\d{2})/(\d{2})/(\d{4})\z}) {
        my ($day, $month, $year) = ($1, $2, $3);
        my $time = $lines[2] // '';
        ScriptManager::Exception->throw('txt_format', "Ora iniziale non valida in $name")
            unless $time =~ /\A(\d{2}):(\d{2}):(\d{2})\z/ && $1 < 24 && $2 < 60 && $3 < 60;
        my ($h, $m, $s) = ($1, $2, $3);
        $self->_datetime(sprintf('%04d-%02d-%02d %02d:%02d:%02d', $year, $month, $day, $h, $m, $s), $name, 2);
        local $ENV{TZ} = 'Europe/Rome';
        tzset();
        $offset = timelocal(0, 0, 0, $day, $month - 1, $year) + $h * 3600 + $m * 60 + $s;
        $header = $lines[3] // '';
        splice @lines, 0, 4;
    } else {
        splice @lines, 0, 2;
    }
    tzset() if defined $offset;
    my @header = map { my $v = lc $_; $v =~ s/\s+//g; $v } split /;/, $header, -1;
    my @expected = ('time(s)', 'duration(s)', 'durata(-10)(s)', 'contatore(n)', 'leq(db)',
        'leq(-10)(db)', 'sel(db)', 'sel(-10)(db)', 'lmax(db)', 'simmetria(%)');
    ScriptManager::Exception->throw('txt_format', "Intestazione non riconosciuta in $name")
        unless @header == @expected && !grep { $header[$_] ne $expected[$_] } 0 .. $#expected;
    my @events;
    my $line_number = defined $offset ? 4 : 2;
    for my $line (@lines) {
        $line_number++;
        next if $line =~ /^\s*$/;
        my @v = split /;/, $line, -1;
        ScriptManager::Exception->throw('txt_format', "$name riga $line_number: attese 10 colonne")
            unless @v == 10;
        s/^\s+|\s+$//g for @v;
        my $date;
        if (defined $offset) {
            ScriptManager::Exception->throw('txt_format', "$name riga $line_number: tempo non valido")
                unless $v[0] =~ /\A\d+(?:[.,]\d+)?\z/;
            $v[0] =~ tr/,/./;
            local $ENV{TZ} = 'Europe/Rome';
            tzset();
            $date = strftime('%Y-%m-%d %H:%M:%S', localtime($offset + int($v[0] + 0.5)));
        } else {
            $date = $self->_datetime($v[0], $name, $line_number);
        }
        tzset() if defined $offset;
        for my $i (1, 4, 5, 6, 7, 8) {
            $v[$i] =~ tr/,/./;
            ScriptManager::Exception->throw('txt_format', "$name riga $line_number: valore non valido nella colonna " . ($i + 1))
                unless $v[$i] =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/;
        }
        ScriptManager::Exception->throw('txt_format', "$name riga $line_number: durata fuori intervallo")
            if $v[1] < 0 || $v[1] > 2147483647;
        push @events, [$date, int($v[1] + 0.5), map { 0 + $v[$_] } (4, 5, 6, 7, 8)];
    }
    ScriptManager::Exception->throw('txt_format', "Nessun evento valido in $name") unless @events;
    return \@events;
}

sub _datetime ($self, $value, $name, $line) {
    ScriptManager::Exception->throw('txt_format', "$name riga $line: data e ora non valide")
        unless $value =~ /\A([1-9]\d{3})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\z/;
    my ($year, $month, $day, $hour, $minute, $second) = ($1, $2, $3, $4, $5, $6);
    my $epoch = eval { timegm($second, $minute, $hour, $day, $month - 1, $year) };
    ScriptManager::Exception->throw('txt_format', "$name riga $line: data e ora non valide")
        if $@ || !defined $epoch || strftime('%Y-%m-%d %H:%M:%S', gmtime($epoch)) ne $value;
    return $value;
}

1;
