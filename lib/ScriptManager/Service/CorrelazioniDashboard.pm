package ScriptManager::Service::CorrelazioniDashboard;
use Mojo::Base -base, -signatures;

use ScriptManager::Exception;
use ScriptManager::Service::CorrelazioneSetup;
use ScriptManager::Service::EventiCMP;

has 'repo';
has eventi => sub { ScriptManager::Service::EventiCMP->new };
has setup => sub { ScriptManager::Service::CorrelazioneSetup->new };

sub load ($self, $airport = undef, $year = undef) {
    my $data = {airport => $airport, year => $year, database => undef, years => [], months => [], stations => []};
    ScriptManager::Exception->throw('invalid_dashboard_filter', 'Selezionare prima un aeroporto')
        if defined $year && length $year && (!defined $airport || !length $airport);
    return $data unless defined $airport && length $airport;
    ScriptManager::Exception->throw('invalid_dashboard_filter', 'Aeroporto non valido')
        unless $airport =~ /\A(?:LIMC|LIML|LIME|LIPO)\z/;

    my $databases = $self->setup->databases($airport);
    my %by_year;
    for my $database (@$databases) {
        my ($y) = $database =~ /_(\d{4})_bruma\z/i;
        next if $y eq '0000';
        ScriptManager::Exception->throw('invalid_dashboard_filter', "Database ambiguo per l anno $y")
            if exists $by_year{$y};
        $by_year{$y} = $database;
    }
    $data->{years} = [sort {$b <=> $a} keys %by_year];
    return $data unless defined $year && length $year;
    ScriptManager::Exception->throw('invalid_dashboard_filter', 'Anno non disponibile per l aeroporto selezionato')
        unless $year =~ /\A[1-9]\d{3}\z/ && exists $by_year{$year};

    my $database = $by_year{$year};
    my $db = $self->eventi->connect($database);
    my $stations = $self->eventi->stations($db, $airport);
    my @stations = grep { defined $_->{aeroporto} && $_->{aeroporto} eq $airport } @$stations;
    my $ambiguous = $db->selectall_arrayref(
        'SELECT c_cab FROM anagrafica.stazioni WHERE c_cab IS NOT NULL GROUP BY c_cab HAVING COUNT(*) > 1');
    my %ambiguous = map { $_->[0] => 1 } @$ambiguous;
    for my $station (@stations) {
        my $code = $station->{c_cab};
        ScriptManager::Exception->throw('invalid_stations', "Codice stazione $code ambiguo in anagrafica")
            if defined $code && $ambiguous{$code};
    }
    my $rows = $db->selectall_arrayref(
        'SELECT id_stazione, data_lva, correlato, valore FROM st_lva '
        . 'WHERE attuale = 1 AND data_lva BETWEEN ? AND ?',
        {Slice => {}}, "$year-01-01", "$year-12-31");
    $db->disconnect;

    my %station_by_code = map { defined $_->{c_cab} ? ($_->{c_cab} => $_) : () } @stations;
    my (%values, %days);
    for my $row (@$rows) {
        my $station = $station_by_code{$row->{id_stazione}} or next;
        ScriptManager::Exception->throw('invalid_lva', 'Valore LVA attuale non valido')
            unless defined $row->{data_lva} && $row->{data_lva} =~ /\A\Q$year\E-\d\d-\d\d\z/
            && defined $row->{correlato} && $row->{correlato} =~ /\A[01]\z/ && defined $row->{valore};
        $days{$row->{data_lva}} = 1;
        $values{$station->{row_id}}{$row->{data_lva}}{$row->{correlato}}++;
    }

    my $target = join ':', lc($ENV{MYSQL_HOST}), 0 + ($ENV{MYSQL_PORT} // 3306), $database;
    my $executions = $self->repo->correlation_dashboard_executions($target, $airport, $year);
    my %latest;
    for my $execution (@$executions) {
        for my $item (@{$execution->{stations}}) {
            my ($id, $code) = $item =~ /\A([1-9]\d*):(\d+):/;
            next unless defined $id && $station_by_code{$code}
                && $station_by_code{$code}{row_id} == $id;
            for my $day (keys %days) {
                next if $day lt $execution->{date_from} || $day gt $execution->{date_to};
                $latest{$id}{$day} //= $execution;
            }
        }
    }

    my @days = sort keys %days;
    for my $station (@stations) {
        for my $day (@days) {
            my $value = $values{$station->{row_id}}{$day} // {};
            my $execution = $latest{$station->{row_id}}{$day};
            my ($tone, $label) = !exists $value->{0}
                ? ('empty', exists $value->{1} ? 'Manca LVAnc' : 'Nessun dato LVA attuale')
                : exists $value->{1} ? ('success', 'LVAc e LVAnc presenti') : ('timeout', 'Solo LVAnc presente');
            if ($execution && ($execution->{status} eq 'failed' || $execution->{status} eq 'timed_out')) {
                ($tone, $label) = ('failure', 'Ultima correlazione fallita o in timeout per questo intervallo');
            }
            $station->{cells}{$day} = {tone => $tone, label => $label,
                can_delete => exists $value->{0} || exists $value->{1},
                execution_id => $tone eq 'failure' ? $execution->{id} : undef};
        }
    }
    my %months;
    push @{$months{substr($_, 5, 2)}}, $_ for @days;
    $data->{months} = [map { +{number => $_, days => $months{$_}} } sort keys %months];
    $data->{stations} = \@stations;
    $data->{database} = $database;
    return $data;
}

1;
