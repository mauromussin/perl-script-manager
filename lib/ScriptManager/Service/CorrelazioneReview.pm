package ScriptManager::Service::CorrelazioneReview;
use Mojo::Base -base, -signatures;

use ScriptManager::Exception;
use ScriptManager::Service::CorrelazioneSetup;
use ScriptManager::Service::EventiCMP;
use POSIX 'strftime';
use Time::Local 'timegm';

has 'repo';
has eventi => sub { ScriptManager::Service::EventiCMP->new };

my %RESULTS = (
    lva => ['st_lva', 'data_lva'],
    lvan => ['st_lvan', 'data_lvan'],
);

sub source ($self, $id) {
    my $execution = $self->repo->get_execution($id);
    ScriptManager::Exception->throw('correlation_source', 'Esecuzione di correlazione completata non trovata')
        unless $execution && $execution->{procedure_code} eq 'correla_eventi_cmp'
        && $execution->{status} eq 'completed';
    my %references;
    for my $event (@{$self->repo->list_events($id)}) {
        my $meta = $event->{metadata} // {};
        next unless ($meta->{operation} // '') eq 'correlation_station_complete';
        my ($station, $log) = @$meta{qw(station_code log_id)};
        ScriptManager::Exception->throw('correlation_source', 'Riferimento ai risultati di correlazione non valido')
            unless defined $station && $station =~ /\A\d+\z/ && defined $log && $log =~ /\A[1-9]\d*\z/;
        $references{"$log:$station"} = 1;
    }
    ScriptManager::Exception->throw('correlation_source', 'Riferimenti ai risultati non disponibili') unless %references;
    return ($execution, \%references);
}

sub _assert_server ($execution) {
    my $target = join ':', lc($ENV{MYSQL_HOST} // ''), 0 + ($ENV{MYSQL_PORT} // 3306),
        $execution->{parameters}{database};
    ScriptManager::Exception->throw('correlation_source', 'Server MySQL diverso dalla correlazione originale')
        unless defined $execution->{queue_target} && $execution->{queue_target} eq $target;
}

sub results ($self, $execution, $references) {
    _assert_server($execution);
    my $params = $execution->{parameters};
    ScriptManager::Service::CorrelazioneSetup->new->validate_target(@$params{qw(airport database)});
    my $db = $self->eventi->connect($params->{database});
    my @results;
    my %counts;
    for my $event (@{$self->repo->list_events($execution->{id})}) {
        my $meta = $event->{metadata} // {};
        next unless ($meta->{operation} // '') eq 'correlation_daily_counts';
        my $key = ($meta->{log_id} // '') . ':' . ($meta->{station_code} // '');
        next unless $references->{$key} && ref $meta->{days} eq 'ARRAY';
        $counts{$key} = {map { $_->{giorno} => $_ } @{$meta->{days}}};
    }
    my ($y, $m, $d) = split /-/, $params->{date_from};
    my $first = timegm(0, 0, 0, $d, $m - 1, $y);
    ($y, $m, $d) = split /-/, $params->{date_to};
    my $last = timegm(0, 0, 0, $d, $m - 1, $y);
    for my $key (sort keys %$references) {
        my ($log, $station) = split /:/, $key;
        my %days;
        for my $type (qw(lva lvan)) {
            my ($table, $date) = @{$RESULTS{$type}};
            my $rows = $db->selectall_arrayref(
                "SELECT $date AS giorno, correlato, valore, attuale FROM $table "
                . "WHERE id_log = ? AND id_stazione = ? AND $date BETWEEN ? AND ? ORDER BY $date, correlato",
                {Slice => {}}, $log, $station, @$params{qw(date_from date_to)});
            for my $row (@$rows) {
                ScriptManager::Exception->throw('correlation_source', 'Risultati giornalieri duplicati')
                    if exists $days{$row->{giorno}}{$type}{$row->{correlato}};
                $days{$row->{giorno}}{$type}{$row->{correlato}} = $row;
            }
        }
        my @rows;
        for (my $epoch = $first; $epoch <= $last; $epoch += 86400) {
            my $day = strftime('%Y-%m-%d', gmtime($epoch));
            my $row = $days{$day} // {};
            $row->{giorno} = $day;
            $row->{counts} = $counts{$key}{$day}
                // {eventi => 0, correlati => 0, eventi_notturni => 0, non_correlati_notturni => 0}
                if exists $counts{$key};
            push @rows, $row;
        }
        push @results, {log_id => $log, station_code => $station, rows => \@rows};
    }
    $db->disconnect;
    return \@results;
}

sub activate ($self, $ctx, $params) {
    my ($execution, $references) = $self->source($params->{source_execution_id});
    my $source = $execution->{parameters};
    ScriptManager::Exception->throw('correlation_source', 'Database o aeroporto diversi dalla correlazione originale')
        unless $params->{database} eq $source->{database} && $params->{airport} eq $source->{airport};
    _assert_server($execution);

    my @selected;
    my (%seen, %seen_type);
    for my $selection (@{$params->{activations} // []}) {
        my ($log, $station, $type) = $selection =~ /\A([1-9]\d*):(\d+)(?::(lva|lvan))?\z/;
        ScriptManager::Exception->throw('invalid_activation', 'Selezione dei risultati non valida')
            unless defined $log && $references->{"$log:$station"} && !$seen{$selection}++;
        for my $selected_type (defined $type ? ($type) : qw(lva lvan)) {
            ScriptManager::Exception->throw('invalid_activation', 'Selezione dei risultati duplicata')
                if $seen_type{"$log:$station:$selected_type"}++;
            push @selected, [$log, $station, $selected_type, defined $type];
        }
    }
    ScriptManager::Exception->throw('invalid_activation', 'Selezionare almeno un risultato') unless @selected;
    my $db = $self->eventi->connect($params->{database});
    for my $item (@selected) {
        my ($log, $station, $type, $required) = @$item;
        my ($table, $date) = @{$RESULTS{$type}};
        my $days = $db->selectcol_arrayref(
            "SELECT DISTINCT $date FROM $table WHERE id_log = ? AND id_stazione = ? AND $date BETWEEN ? AND ?",
            undef, $log, $station, @$source{qw(date_from date_to)});
        ScriptManager::Exception->throw('invalid_activation', "Risultati $type non disponibili per la stazione $station")
            if $required && !@$days;
        $item->[3] = $days;
    }
    @selected = grep { @{$_->[3]} } @selected;
    ScriptManager::Exception->throw('invalid_activation', 'Nessun risultato disponibile per le stazioni selezionate')
        unless @selected;
    $ctx->log(warning => 'Attualizzazione MyISAM: errori o annullamenti possono lasciare modifiche parziali',
        operation => 'correlation_activation');
    for my $item (@selected) {
        $ctx->check_cancel;
        my ($log, $station, $type, $days) = @$item;
        my ($table, $date) = @{$RESULTS{$type}};
        for my $day (@$days) {
            $ctx->check_cancel;
            $db->do("UPDATE $table SET attuale = 0 WHERE id_stazione = ? AND $date = ? AND attuale = 1",
                undef, $station, $day);
            $db->do("UPDATE $table SET attuale = 1 WHERE id_stazione = ? AND id_log = ? AND $date = ?",
                undef, $station, $log, $day);
        }
        $ctx->log(info => "Attualizzati $type per la stazione $station", operation => 'correlation_activated',
            station_code => $station, log_id => $log, result_type => $type);
    }
    $db->disconnect;
    return {success => 1, message => 'Risultati selezionati attualizzati'};
}

1;
