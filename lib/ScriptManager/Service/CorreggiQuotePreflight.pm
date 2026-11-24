package ScriptManager::Service::CorreggiQuotePreflight;
use Mojo::Base 'ScriptManager::Service::BattutePreflight', -signatures;

use List::Util 'max';
use ScriptManager::Exception;

use constant SAVING_METRIC => 'correggi_quote_batch_saving_v1';

has stage_label => '10';

sub check_saving ($self, $ctx, $target, $operations) {
    return unless $operations;

    my $events = $ctx->repo->validation_timing_events(
        $target, $ctx->execution_id, 'correggi_quote', SAVING_METRIC);
    my @rates = map { $_->{metadata}{seconds} / $_->{metadata}{units} }
        grep {
            ($_->{metadata}{operation} // '') eq SAVING_METRIC
                && ($_->{metadata}{units} // 0) > 0
                && ($_->{metadata}{seconds} // 0) > 0
        } @$events;

    unless (@rates) {
        ScriptManager::Exception->throw('timeout_estimate_unavailable',
            'Stima 10 non disponibile: manca uno storico misurabile del salvataggio a lotti. '
            . 'Nessuna scrittura radar eseguita; confermare nel dettaglio se si vuole procedere senza timeout.')
            unless $ctx->timeout_bypassed;
        $ctx->log(warning => 'Stima 10 non disponibile: prosecuzione senza timeout confermata, durata sconosciuta');
        return;
    }

    $self->seconds_per_operation(max @rates);
    return $self->ensure_budget($ctx, 0, $operations);
}

1;
