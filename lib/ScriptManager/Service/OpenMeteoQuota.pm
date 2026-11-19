package ScriptManager::Service::OpenMeteoQuota;
use Mojo::Base -base, -signatures;
use ScriptManager::Exception;

has [qw(repo execution_id)];

sub limits ($self) { return {minute => 600, hour => 5000, day => 10000, month => 300000} }

sub snapshot ($self) {
    my $used = $self->repo->weather_usage($self->execution_id);
    my $limits = $self->limits;
    my %remaining = map { $_ => $used->{$_} >= $limits->{$_} ? 0 : $limits->{$_} - $used->{$_} } keys %$limits;
    return {used => $used, limits => $limits, remaining => \%remaining,
        scope => 'Stima locale; finestre mobili 1 minuto, 1 ora, 24 ore, 31 giorni. '
            . 'Esclusi utilizzi esterni sullo stesso IP e chiamate precedenti al contatore. '
            . 'Tentativi falliti o interrotti conteggiati prudenzialmente.'};
}

sub check ($self, $requests, $snapshot) {
    for my $window (qw(minute hour day month)) {
        ScriptManager::Exception->throw('weather_quota',
            "Open-Meteo: servono $requests chiamate; residue locali $window: $snapshot->{remaining}{$window}. Riprovare dopo il ripristino del budget")
            if $requests > $snapshot->{remaining}{$window};
    }
}

sub reserve ($self) { return $self->repo->reserve_weather_call($self->execution_id, $self->limits) }
sub finish ($self, $id, $success) { $self->repo->finish_weather_call($id, $success) }

sub describe ($self, $snapshot) {
    return "Open-Meteo: usate 24h $snapshot->{used}{day}/$snapshot->{limits}{day}; "
        . "residue locali minuto $snapshot->{remaining}{minute}, ora $snapshot->{remaining}{hour}, "
        . "24h $snapshot->{remaining}{day}, 31 giorni $snapshot->{remaining}{month}; stima non ufficiale";
}

1;
