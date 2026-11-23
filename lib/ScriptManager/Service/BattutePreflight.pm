package ScriptManager::Service::BattutePreflight;
use Mojo::Base -base, -signatures;

use List::Util qw(max);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use ScriptManager::Exception;

has 'seconds_per_operation';
has stage_label => '04';

sub saving_rate ($class, $events, $operation = 'validation_saving') {
    my (%previous, @rates);
    for my $event (@$events) {
        my $meta = $event->{metadata} // {};
        if (($meta->{operation} // '') eq $operation) {
            push @rates, $meta->{seconds} / $meta->{units}
                if ($meta->{units} // 0) >= 10 && ($meta->{seconds} // 0) > 0;
            next;
        }
        my $message = $event->{message} // '';
        my ($units) = $message =~ /(?:\(|Salvataggio: )(\d+) di \d+ operazioni/;
        $units = 0 if $message =~ /\ASalvataggio: classificazioni delle battute e delle tracce/;
        $units = 0 if $message =~ /\ASalvataggio: quote Z_m, hmod e stati tracce/;
        next unless defined $units;
        my $prior = $previous{$event->{execution_id}};
        if ($prior && $units - $prior->[0] >= 10 && $event->{time} > $prior->[1]) {
            push @rates, ($event->{time} - $prior->[1]) / ($units - $prior->[0]);
        }
        $previous{$event->{execution_id}} = [$units, $event->{time}];
    }
    return @rates ? max(@rates) : undef;
}

sub ensure_budget ($self, $ctx, $analysis, $operations) {
    my $estimate = $ctx->elapsed_seconds + 2 * ($analysis + $operations * $self->seconds_per_operation);
    $ctx->log(info => sprintf(
        'Stima preventiva %s: %.1f secondi totali, timeout %d; margine 2x, non garanzia di durata',
        $self->stage_label, $estimate, $ctx->timeout_seconds), operation => 'duration_estimate',
        estimated_seconds => $estimate, timeout_seconds => $ctx->timeout_seconds,
        timeout_bypassed => $ctx->timeout_bypassed ? 1 : 0);
    ScriptManager::Exception->throw('timeout_estimate', sprintf(
        'Durata stimata %s %.0f secondi superiore al timeout di %d secondi. Nessuna scrittura radar eseguita; '
        . 'confermare la riesecuzione senza timeout nella pagina di dettaglio oppure ridurre l intervallo di date.',
        $self->stage_label, $estimate, $ctx->timeout_seconds)) if $estimate > $ctx->timeout_seconds && !$ctx->timeout_bypassed;
    $ctx->log(warning => 'Stima oltre il limite configurato: prosecuzione senza timeout con conferma utente')
        if $estimate > $ctx->timeout_seconds && $ctx->timeout_bypassed;
    return $estimate;
}

sub check ($self, $db, $ctx, $window, $tracks, $selection, $bind, $plan_track) {
    return unless @{$window->days};
    my $rate = __PACKAGE__->saving_rate($ctx->repo->battute_timing_events($window->target, $ctx->execution_id));
    ScriptManager::Exception->throw('timeout_estimate_unavailable',
        'Stima 04 non attendibile: manca uno storico misurabile di salvataggio per questo database negli ultimi 90 giorni. '
        . 'Nessuna scrittura radar eseguita; occorre una calibrazione verificata prima di procedere.')
        unless defined $rate;
    $self->seconds_per_operation($rate);
    $ctx->progress(0, 'Preflight 04: conteggio battute e campionamento in sola lettura');
    my $counts = $db->selectall_arrayref(
        "SELECT flay_id, COUNT(*) FROM battute WHERE flay_id IN (SELECT row_id FROM flay WHERE $selection) GROUP BY flay_id",
        undef, @$bind);
    my %counts = map { $_->[0] => $_->[1] } @$counts;
    my %groups;
    for my $track (@$tracks) {
        my $n = $counts{$track->[0]} // 0;
        my $bucket = $n <= 32 ? 0 : $n <= 128 ? 1 : $n <= 512 ? 2 : int(log($n) / log(2));
        push @{$groups{"$track->[1]:$bucket"}}, $track;
    }
    my ($analysis, $operations, $samples) = (0, 2, 0);
    for my $key (sort keys %groups) {
        my @group = sort { ($counts{$a->[0]} // 0) <=> ($counts{$b->[0]} // 0) || $a->[0] <=> $b->[0] } @{$groups{$key}};
        my %indices = map { $_ => 1 } (0, int($#group / 2), $#group);
        my ($slowest, $most_operations) = (0, 0);
        for my $index (sort {$a <=> $b} keys %indices) {
            my $start = clock_gettime(CLOCK_MONOTONIC);
            $ctx->check_cancel;
            my $plan = $plan_track->($group[$index]);
            $ctx->progress(0, "Preflight 04: campione della traccia $group[$index][0]");
            my $seconds = clock_gettime(CLOCK_MONOTONIC) - $start;
            my $units = 1;
            $units += int((@$_ + 499) / 500) for values %{$plan->{updates}};
            $slowest = max($slowest, $seconds);
            $most_operations = max($most_operations, $units);
            $samples++;
        }
        $analysis += @group * $slowest;
        $operations += @group * $most_operations;
    }
    $ctx->log(info => "$samples tracce campionate per operazione e numerosita battute; "
        . scalar(@$tracks) . ' tracce previste; velocita di scrittura ricavata dallo storico del database');
    return $self->ensure_budget($ctx, $analysis, $operations);
}

sub check_saving ($self, $ctx, $operations) {
    return unless defined $self->seconds_per_operation;
    return $self->ensure_budget($ctx, 0, $operations);
}

1;
