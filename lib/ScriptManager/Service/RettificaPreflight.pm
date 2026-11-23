package ScriptManager::Service::RettificaPreflight;
use Mojo::Base 'ScriptManager::Service::BattutePreflight', -signatures;

use List::Util 'max';
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use ScriptManager::Exception;

has stage_label => '08';

sub check ($self, $db, $ctx, $window, $tracks, $plan_track) {
    $self->seconds_per_operation(undef);
    return unless @$tracks;
    my $events = $ctx->repo->validation_timing_events(
        $window->target, $ctx->execution_id, 'rettifica_quote', 'rettifica_saving');
    my $rate = $self->saving_rate($events, 'rettifica_saving');
    unless (defined $rate) {
        ScriptManager::Exception->throw('timeout_estimate_unavailable',
            'Stima 08 non disponibile: manca uno storico misurabile per questo database. '
            . 'Nessuna scrittura radar eseguita; confermare nel dettaglio se si vuole procedere senza timeout.')
            unless $ctx->timeout_bypassed;
        $ctx->log(warning => 'Stima 08 non disponibile: prosecuzione senza timeout confermata, durata sconosciuta');
        return;
    }
    $self->seconds_per_operation($rate);
    $ctx->progress(0, 'Preflight 08: conteggio e campionamento delle tracce');
    my %counts;
    for (my $offset = 0; $offset < @$tracks; $offset += 500) {
        $ctx->check_cancel;
        my $last = $offset + 499 < $#$tracks ? $offset + 499 : $#$tracks;
        my @ids = @$tracks[$offset .. $last];
        my $rows = $db->selectall_arrayref('SELECT flay_id, COUNT(*) FROM battute WHERE flay_id IN ('
            . join(',', ('?') x @ids) . ') AND validation NOT IN (?, ?, ?) GROUP BY flay_id',
            undef, @ids, 'N', 'A', 'S');
        $counts{$_->[0]} = $_->[1] for @$rows;
    }
    my %groups;
    for my $id (@$tracks) {
        my $n = $counts{$id} // 0;
        my $bucket = $n <= 32 ? 0 : $n <= 128 ? 1 : $n <= 512 ? 2 : int(log($n) / log(2));
        push @{$groups{$bucket}}, $id;
    }
    my ($analysis, $operations, $samples) = (0, 0, 0);
    for my $key (sort {$a <=> $b} keys %groups) {
        my @group = sort { ($counts{$a} // 0) <=> ($counts{$b} // 0) || $a <=> $b } @{$groups{$key}};
        my %indices = map { $_ => 1 } (0, int($#group / 2), $#group);
        my $slowest = 0;
        for my $index (sort {$a <=> $b} keys %indices) {
            $ctx->check_cancel;
            my $start = clock_gettime(CLOCK_MONOTONIC);
            $plan_track->($group[$index]);
            $ctx->progress(0, "Preflight 08: campione della traccia $group[$index]");
            $slowest = max($slowest, clock_gettime(CLOCK_MONOTONIC) - $start);
            $samples++;
        }
        $analysis += @group * $slowest;
        $operations += @group * (($counts{$group[-1]} // 0) + 1);
    }
    $ctx->log(info => "$samples tracce campionate per numerosita battute; "
        . scalar(@$tracks) . ' tracce previste; velocita di scrittura ricavata dallo storico 08');
    return $self->ensure_budget($ctx, $analysis, $operations);
}

1;
