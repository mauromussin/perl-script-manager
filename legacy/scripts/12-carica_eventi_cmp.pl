#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use DBI;
use Getopt::Long qw(GetOptions);
use Time::Local qw(timelocal);
use POSIX qw(strftime);
use File::Spec;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my %opt = (
    host     => 'localhost',
    port     => 3306,
    table    => 'st_eventi_cmp',
    check_table => 'anagrafica.centraline_cmp',
    dry_run  => 0,
);

GetOptions(
    'host=s'          => \$opt{host},
    'port=i'          => \$opt{port},
    'database=s'      => \$opt{database},
    'user=s'          => \$opt{user},
    'file=s'          => \$opt{file},
    'centralina=i'    => \$opt{centralina},
    'table=s'         => \$opt{table},
    'check-table=s'   => \$opt{check_table},
    'dry-run!'        => \$opt{dry_run},
    'help'            => \$opt{help},
) or usage(1);

usage(0) if $opt{help};

$opt{database}   //= prompt('Nome del database: ');
$opt{user}       //= prompt('Nome utente MySQL: ');
$opt{file}       //= prompt('Percorso completo del file da caricare: ');
$opt{centralina} //= prompt('ID della centralina: ');

$opt{file} =~ s/^\s+|\s+$//g;
die "File non trovato: $opt{file}\n" unless -f $opt{file};
die "ID centralina non valido\n" unless $opt{centralina} =~ /^\d+$/;
die "Nome database non valido\n" unless $opt{database} =~ /^\w+$/;
die "Nome tabella non valido\n" unless $opt{table} =~ /^\w+$/;
die "Nome tabella di controllo non valido\n"
    unless $opt{check_table} =~ /^\w+(?:\.\w+)?$/;

my $password = read_password('Password MySQL: ');

my $dsn = sprintf(
    'DBI:mysql:database=%s;host=%s;port=%d',
    $opt{database}, $opt{host}, $opt{port}
);

my $dbh = DBI->connect(
    $dsn,
    $opt{user},
    $password,
    {
        RaiseError           => 1,
        PrintError           => 0,
        AutoCommit           => 1,
        mysql_enable_utf8mb4 => 1,
    }
) or die "Connessione MySQL non riuscita: $DBI::errstr\n";

$password = undef;

my ($centralina_esistente) = $dbh->selectrow_array(
    "SELECT row_id FROM $opt{check_table} WHERE row_id = ?",
    undef,
    $opt{centralina}
);

die "La centralina $opt{centralina} non esiste in $opt{check_table}\n"
    unless defined $centralina_esistente;

my ($data_base, $secondi_base, $eventi) = leggi_file_eventi($opt{file});

print "\nFile: $opt{file}\n";
print "Data di riferimento: $data_base\n";
print "Eventi validi letti: " . scalar(@$eventi) . "\n";
print "Modalità: " . ($opt{dry_run} ? 'VERIFICA, nessun inserimento' : 'INSERIMENTO') . "\n\n";

my $sql = qq{
    INSERT IGNORE INTO $opt{table}
        (id_centralina_cmp, Data_ora, Durata, Leq, Leq_10, Sel, Sel_10, LMax)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
};
my $sth = $dbh->prepare($sql);

my ($inseriti, $duplicati, $errori) = (0, 0, 0);

for my $evento (@$eventi) {
    my $data_ora = data_ora_da_secondi(
        $data_base,
        $secondi_base + $evento->{time_s}
    );

    if ($opt{dry_run}) {
        printf "%s | durata=%d | Leq=%.1f | Leq_10=%.1f | SEL=%.1f | SEL_10=%.1f | LMax=%.1f\n",
            $data_ora,
            $evento->{durata},
            $evento->{leq},
            $evento->{leq_10},
            $evento->{sel},
            $evento->{sel_10},
            $evento->{lmax};
        next;
    }

    my $rv;
    eval {
        $rv = $sth->execute(
            $opt{centralina},
            $data_ora,
            $evento->{durata},
            $evento->{leq},
            $evento->{leq_10},
            $evento->{sel},
            $evento->{sel_10},
            $evento->{lmax},
        );
        1;
    } or do {
        my $errore = $@ || $sth->errstr || 'errore sconosciuto';
        warn "Errore alla riga $evento->{numero_riga}: $errore\n";
        $errori++;
        next;
    };

    if (defined $rv && $rv > 0) {
        $inseriti++;
    } else {
        $duplicati++;
    }
}

print "\nRIEPILOGO\n";
print "Eventi validi: " . scalar(@$eventi) . "\n";
if ($opt{dry_run}) {
    print "Nessun dato inserito perché è stata usata l'opzione --dry-run.\n";
} else {
    print "Inseriti: $inseriti\n";
    print "Duplicati ignorati: $duplicati\n";
    print "Errori: $errori\n";
}

$sth->finish;
$dbh->disconnect;
exit($errori ? 2 : 0);

sub leggi_file_eventi {
    my ($file) = @_;

    open my $fh, '<:encoding(UTF-8)', $file
        or die "Impossibile aprire $file: $!\n";

    my $titolo       = <$fh>;
    my $riga_data    = <$fh>;
    my $riga_ora     = <$fh>;
    my $intestazione = <$fh>;

    die "Il file non contiene le quattro righe iniziali previste\n"
        unless defined $intestazione;

    for ($riga_data, $riga_ora, $intestazione) {
        s/^\x{FEFF}// if defined;
        s/[\r\n]+$// if defined;
        s/^\s+|\s+$//g if defined;
    }

    die "Data non valida nella seconda riga: $riga_data\n"
        unless $riga_data =~ m{^(\d{2})/(\d{2})/(\d{4})$};
    my ($giorno, $mese, $anno) = ($1, $2, $3);
    my $data_base = sprintf('%04d-%02d-%02d', $anno, $mese, $giorno);

    die "Ora iniziale non valida nella terza riga: $riga_ora\n"
        unless $riga_ora =~ /^(\d{2}):(\d{2}):(\d{2})$/;
    my ($ora, $minuto, $secondo) = ($1, $2, $3);
    die "Ora iniziale fuori intervallo: $riga_ora\n"
        if $ora > 23 || $minuto > 59 || $secondo > 59;
    my $secondi_base = $ora * 3600 + $minuto * 60 + $secondo;

    my @colonne = split /;/, $intestazione, -1;
    die "Intestazione non riconosciuta: previste almeno 10 colonne\n"
        unless @colonne >= 10;
    die "La prima colonna non è Time (s)\n"
        unless normalizza($colonne[0]) eq 'time(s)';
    die "La seconda colonna non è Duration (s)\n"
        unless normalizza($colonne[1]) eq 'duration(s)';

    my @eventi;
    my $numero_riga = 4;

    while (my $riga = <$fh>) {
        $numero_riga++;
        $riga =~ s/[\r\n]+$//;
        next if $riga =~ /^\s*$/;

        my @v = split /;/, $riga, -1;
        if (@v < 10) {
            warn "Riga $numero_riga scartata: trovate " . scalar(@v) . " colonne, attese almeno 10\n";
            next;
        }

        for (@v) {
            s/^\s+|\s+$//g;
            tr/,/./;
        }

        my @indici_numerici = (0, 1, 4, 5, 6, 7, 8);
        my $valida = 1;
        for my $i (@indici_numerici) {
            if ($v[$i] !~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/) {
                warn "Riga $numero_riga scartata: valore numerico non valido nella colonna " . ($i + 1) . ": '$v[$i]'\n";
                $valida = 0;
                last;
            }
        }
        next unless $valida;

        my $durata = int($v[1] + 0.5);
        if ($durata < 0) {
            warn "Riga $numero_riga scartata: durata negativa\n";
            next;
        }

        push @eventi, {
            numero_riga => $numero_riga,
            time_s      => int($v[0] + 0.5),
            durata      => $durata,
            leq         => 0 + $v[4],
            leq_10      => 0 + $v[5],
            sel         => 0 + $v[6],
            sel_10      => 0 + $v[7],
            lmax        => 0 + $v[8],
        };
    }

    close $fh;
    die "Nessun evento valido trovato nel file\n" unless @eventi;
    return ($data_base, $secondi_base, \@eventi);
}

sub data_ora_da_secondi {
    my ($data_base, $secondi_da_aggiungere) = @_;
    my ($anno, $mese, $giorno) = split /-/, $data_base;
    my $epoch = timelocal(0, 0, 0, $giorno, $mese - 1, $anno) + $secondi_da_aggiungere;
    return strftime('%Y-%m-%d %H:%M:%S', localtime($epoch));
}

sub normalizza {
    my ($valore) = @_;
    $valore = lc($valore // '');
    $valore =~ s/\s+//g;
    return $valore;
}

sub prompt {
    my ($testo) = @_;
    print $testo;
    my $valore = <STDIN>;
    die "Input terminato in modo inatteso\n" unless defined $valore;
    chomp $valore;
    return $valore;
}

sub read_password {
    my ($testo) = @_;
    print $testo;

    my $password;
    my $term_readkey_ok = eval {
        require Term::ReadKey;
        Term::ReadKey->import();
        1;
    };

    if ($term_readkey_ok) {
        Term::ReadKey::ReadMode('noecho');
        $password = <STDIN>;
        Term::ReadKey::ReadMode('restore');
        print "\n";
    } else {
        warn "Modulo Term::ReadKey non disponibile: la password sarà visibile durante la digitazione.\n";
        $password = <STDIN>;
    }

    die "Password non letta\n" unless defined $password;
    chomp $password;
    return $password;
}

sub usage {
    my ($exit_code) = @_;
    print <<'USAGE';
Uso:
  perl carica_eventi_cmp.pl --host HOST --database DB --user UTENTE \
       --file FILE --centralina ID [--port 3306] [--dry-run]

Esempio di verifica senza inserimento:
  perl carica_eventi_cmp.pl --host 127.0.0.1 --database bgy_2025_bruma \
       --user root --file "E:\\dati\\eventi.txt" --centralina 12 --dry-run

Esempio di inserimento:
  perl carica_eventi_cmp.pl --host 127.0.0.1 --database bgy_2025_bruma \
       --user root --file "E:\\dati\\eventi.txt" --centralina 12

Il programma legge:
  riga 1: descrizione
  riga 2: data nel formato GG/MM/AAAA
  riga 3: ora iniziale nel formato HH:MM:SS
  riga 4: intestazione separata da punto e virgola
  righe successive: eventi
USAGE
    exit $exit_code;
}
