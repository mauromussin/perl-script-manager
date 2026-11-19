package ScriptManager::Service::OpenMeteo;
use Mojo::Base -base, -signatures;

use Mojo::URL;
use Mojo::UserAgent;
use POSIX qw(isfinite strftime tzset);
use Scalar::Util 'looks_like_number';
use Time::Piece ();
use Digest::SHA 'sha256_hex';
use Mojo::JSON 'encode_json';
use ScriptManager::Exception;

has ua => sub { Mojo::UserAgent->new->connect_timeout(10)->request_timeout(60)->max_redirects(0) };

my %ARP = (
    LIMC => [45 + 37/60 + 48/3600, 8 + 43/60 + 23/3600, 'https://milanairports.com/en/group/technical-data'],
    LIML => [45 + 26/60 + 58/3600, 9 + 16/60 + 42/3600, 'https://milanairports.com/en/group/technical-data'],
    LIME => [45 + 40/60 + 8/3600, 9 + 42/60 + 1/3600, 'https://www.nextdigital.it/apps/aip/browse/ad/ADPME1-1'],
    LIPO => [45 + 25/60 + 44/3600, 10 + 19/60 + 50/3600, 'https://www.nextdigital.it/apps/aip/browse/ad/ADPPO1-1'],
);
my @VARIABLES = qw(temperature_2m relative_humidity_2m precipitation wind_speed_10m
    wind_direction_10m shortwave_radiation surface_pressure);
my %UNITS = (
    time => 'unixtime', temperature_2m => chr(176) . 'C', relative_humidity_2m => '%',
    precipitation => 'mm', wind_speed_10m => 'm/s', wind_direction_10m => chr(176),
    shortwave_radiation => 'W/m' . chr(178), surface_pressure => 'hPa',
);

sub attribution ($class) { return 'Weather data by Open-Meteo.com (CC BY 4.0); historical weather, best_match' }
sub max_local_days ($class) { return 13 }

sub fingerprint ($class, $rows) {
    return sha256_hex(encode_json([map {
        [$_->[0], map { defined $_ ? sprintf('%.1f', $_) : undef } @$_[1, 2]]
    } @$rows]));
}

sub location ($class, $airport, $elevation) {
    ScriptManager::Exception->throw('invalid_airport', 'Meteo ARP supporta LIMC, LIML, LIME e LIPO')
        unless exists $ARP{$airport};
    ScriptManager::Exception->throw('weather_location', 'Quota ARP mancante o non valida in anagrafica.aeroporti')
        unless defined $elevation && looks_like_number($elevation) && isfinite($elevation)
            && $elevation >= -500 && $elevation <= 9000;
    return {airport => $airport, latitude => $ARP{$airport}[0], longitude => $ARP{$airport}[1],
        elevation => 0 + $elevation, source => $ARP{$airport}[2], elevation_source => 'anagrafica.aeroporti.QUOTA_aerop'};
}

sub epoch ($class, $date) { return Time::Piece->strptime($date, '%Y-%m-%d')->epoch }
sub day ($class, $epoch) { return Time::Piece->gmtime($epoch)->strftime('%Y-%m-%d') }

sub local_times ($class, $epochs) {
    my ($result, $error);
    {
        local $ENV{TZ} = 'Europe/Rome';
        tzset();
        $result = eval { [map { strftime('%Y-%m-%d %H:%M:%S', CORE::localtime($_)) } @$epochs] };
        $error = $@;
    }
    tzset();
    die $error if $error;
    return $result;
}

sub fetch ($self, $location, $from, $to) {
    ScriptManager::Exception->throw('weather_request_size', 'Ogni richiesta deve restare entro 14 giorni UTC e 10 variabili')
        if (__PACKAGE__->epoch($to) - __PACKAGE__->epoch($from)) / 86400 + 1 > __PACKAGE__->max_local_days
            || @VARIABLES > 10;
    # Fetch the previous UTC day too, to cover Italian midnight without using a fixed DST offset.
    my $url = Mojo::URL->new('https://archive-api.open-meteo.com/v1/archive')->query(
        latitude => $location->{latitude}, longitude => $location->{longitude}, elevation => $location->{elevation},
        start_date => __PACKAGE__->day(__PACKAGE__->epoch($from) - 86400), end_date => $to,
        hourly => join(',', @VARIABLES), temperature_unit => 'celsius', wind_speed_unit => 'ms',
        precipitation_unit => 'mm', timezone => 'UTC', timeformat => 'unixtime', models => 'best_match');
    my $tx = $self->ua->get($url);
    my $response = $tx->res;
    my $code = $response->code // 0;
    if ($tx->error || $code != 200) {
        my $body = $response->json;
        my $reason = ref $body eq 'HASH' && defined $body->{reason} && !ref $body->{reason}
            ? ': ' . substr($body->{reason}, 0, 500) : '';
        ScriptManager::Exception->throw('weather_http',
            "Open-Meteo non disponibile (HTTP $code)$reason; verificare rete, disponibilita delle date e limiti API; nessun fallback");
    }
    my $data = $response->json;
    my $parsed = __PACKAGE__->parse($data, $location, $from, $to);
    return {%$parsed, request => "$url", response => $data};
}

sub parse ($class, $data, $location, $from, $to) {
    my $invalid = sub ($detail) {
        ScriptManager::Exception->throw('weather_data', "Risposta Open-Meteo non valida o incompleta: $detail");
    };
    $invalid->('JSON o fuso orario inatteso')
        unless ref $data eq 'HASH' && !$data->{error} && defined $data->{utc_offset_seconds}
            && looks_like_number($data->{utc_offset_seconds}) && $data->{utc_offset_seconds} == 0
            && ref $data->{hourly} eq 'HASH' && ref $data->{hourly_units} eq 'HASH';
    for my $field (qw(latitude longitude elevation)) {
        $invalid->("metadato $field mancante") unless defined $data->{$field}
            && looks_like_number($data->{$field}) && isfinite($data->{$field});
    }
    $invalid->('quota diversa da quella ARP richiesta') if abs($data->{elevation} - $location->{elevation}) > 0.1;
    my $hourly = $data->{hourly};
    $invalid->('timestamp mancanti') unless ref $hourly->{time} eq 'ARRAY';
    my $first = $class->epoch($from) - 86400;
    my $until = $class->epoch($to) + 86400;
    my $count = int(($until - $first) / 3600);
    $invalid->('serie oraria troncata') unless @{$hourly->{time}} == $count;
    for my $variable ('time', @VARIABLES) {
        $invalid->("unita o lunghezza di $variable")
            unless ($data->{hourly_units}{$variable} // '') eq $UNITS{$variable}
                && ref $hourly->{$variable} eq 'ARRAY' && @{$hourly->{$variable}} == $count;
    }
    for my $i (0 .. $count - 1) {
        my $time = $hourly->{time}[$i];
        $invalid->('timestamp duplicati, disordinati o mancanti')
            unless defined $time && looks_like_number($time) && isfinite($time) && $time == $first + 3600 * $i;
    }
    my $local = $class->local_times($hourly->{time});
    my (%rows, @discarded);
    for my $i (0 .. $count - 1) {
        my $day = substr($local->[$i], 0, 10);
        next if $day lt $from || $day gt $to;
        my %v;
        for my $variable (@VARIABLES) {
            my $value = $hourly->{$variable}[$i];
            $invalid->("$variable assente o non numerico a $local->[$i]")
                unless defined $value && looks_like_number($value) && isfinite($value);
            $v{$variable} = 0 + $value;
        }
        $invalid->("valori fuori dominio o non memorizzabili a $local->[$i]")
            if $v{relative_humidity_2m} < 0 || $v{relative_humidity_2m} > 100
                || $v{precipitation} < 0 || $v{wind_speed_10m} < 0 || $v{shortwave_radiation} < 0
                || $v{wind_direction_10m} < 0 || $v{wind_direction_10m} > 360 || $v{surface_pressure} <= 0
                || $v{precipitation} > 99999.9 || abs($v{temperature_2m}) > 999.9
                || $v{wind_speed_10m} > 999.9 || $v{surface_pressure} > 9999.9
                || $v{shortwave_radiation} > 65535;
        if (my $previous = $rows{$local->[$i]}) {
            push @discarded, {local => $local->[$i], discarded_utc => $previous->{utc}, kept_utc => $hourly->{time}[$i]};
        }
        $rows{$local->[$i]} = {
            utc => $hourly->{time}[$i], local => $local->[$i],
            values => [$local->[$i], $v{precipitation}, $v{temperature_2m},
                int($v{wind_direction_10m} + 0.5), undef, $v{wind_speed_10m},
                int($v{relative_humidity_2m} + 0.5), undef, int($v{shortwave_radiation} + 0.5), $v{surface_pressure}],
        };
    }
    return {rows => [map { $rows{$_} } sort keys %rows], discarded => \@discarded};
}

1;
