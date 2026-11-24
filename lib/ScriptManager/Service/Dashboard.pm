package ScriptManager::Service::Dashboard;
use Mojo::Base -base, -signatures;

use Log::Any ();
use ScriptManager::Exception;
use ScriptManager::Service::ValidationWindow;

has 'repo';
has logger => sub { Log::Any->get_logger(category => 'ScriptManager::Dashboard') };

my %STATES = (
    completed        => ['success', 'Riuscita'],
    failed           => ['failure', 'Fallita'],
    cancelled        => ['failure', 'Annullata'],
    timed_out        => ['timeout', 'Timeout'],
    queued           => ['active', 'Accodata'],
    running          => ['active', 'In corso'],
    cancel_requested => ['active', 'Annullamento richiesto'],
);

sub load ($self, $procedures, $database = undef, $year = undef) {
    my $databases = $self->repo->dashboard_databases;
    ScriptManager::Exception->throw('invalid_dashboard_filter', 'Database non presente nello storico')
        if defined $database && !grep { $_ eq $database } @$databases;
    ScriptManager::Exception->throw('invalid_dashboard_filter', 'Anno non valido: usare quattro cifre')
        if defined $year && $year !~ /\A[1-9][0-9]{3}\z/;
    $database //= $databases->[0];
    my $executions = defined $database ? $self->repo->dashboard_executions($database) : [];
    my (%years, @dated, %unknown, %names);
    for my $p (@$procedures) {
        $names{$p->{code}} = $p->{name} if exists $p->{parameter_schema}{properties}{database};
    }
    my $unknown_count = 0;
    for my $e (@$executions) {
        $names{$e->{procedure_code}} //= $e->{procedure_name};
        my $state = $STATES{$e->{status}} // die "Stato di esecuzione non riconosciuto\n";
        $e = {%$e, tone => $state->[0], status_label => $state->[1]};
        my $valid = eval {
            ScriptManager::Service::ValidationWindow->validate_params(
                {date_from => $e->{date_from}, date_to => $e->{date_to}});
            defined $e->{date_from};
        };
        my $error = $@;
        die $error if $error && !ScriptManager::Exception->caught($error, 'invalid_date_range');
        unless ($valid) {
            $unknown_count++;
            my $entry = $unknown{$e->{procedure_code}} //= {execution => $e, count => 0};
            $entry->{count}++;
            next;
        }
        $years{$_} = 1 for substr($e->{date_from}, 0, 4) .. substr($e->{date_to}, 0, 4);
        push @dated, $e;
    }
    my @years = sort {$b <=> $a} keys %years;
    if (defined $year && @years && !$years{$year}) {
        ScriptManager::Exception->throw('invalid_dashboard_filter', 'Anno non presente negli intervalli dello storico');
    }
    $year //= $years[0] // (1900 + (localtime)[5]);
    @years = ($year) unless @years;
    my @warnings;
    if ($unknown_count) {
        my $warning = "$unknown_count esecuzioni senza intervallo di date valido o specificato: "
            . 'escluse dalla heatmap e mostrate separatamente, senza attribuzione a un anno o mese.';
        push @warnings, $warning;
        $self->logger->warn("Cruscotto database $database: $warning");
    }
    my %cells;
    for my $e (@dated) {
        next if substr($e->{date_from}, 0, 4) > $year || substr($e->{date_to}, 0, 4) < $year;
        my $first = substr($e->{date_from}, 0, 4) == $year ? 0 + substr($e->{date_from}, 5, 2) : 1;
        my $last = substr($e->{date_to}, 0, 4) == $year ? 0 + substr($e->{date_to}, 5, 2) : 12;
        $cells{$e->{procedure_code}}{$_} //= $e for $first .. $last;
    }
    my @codes = sort { $names{$a} cmp $names{$b} || $a cmp $b } keys %names;
    return {
        databases => $databases, database => $database, years => \@years, year => $year,
        warnings => \@warnings,
        unknown => [map { +{name => $names{$_}, %{$unknown{$_}}} } grep { $unknown{$_} } @codes],
        cells => \%cells, procedures => [map { +{code => $_, name => $names{$_}} } @codes],
    };
}

1;
