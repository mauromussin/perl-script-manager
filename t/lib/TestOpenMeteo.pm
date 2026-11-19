package TestOpenMeteo;
use Mojo::Base 'ScriptManager::Service::OpenMeteo', -signatures;
use ScriptManager::Exception;

has requests => sub { [] };
has null_pressure => 0;
has fail_request => 0;

sub response ($class, $from, $to, $elevation = 233.782) {
    my $first = $class->epoch($from) - 86400;
    my $count = int(($class->epoch($to) + 86400 - $first) / 3600);
    return {
        latitude => 45.58875, longitude => 8.773584, elevation => $elevation,
        utc_offset_seconds => 0, timezone => 'GMT',
        hourly_units => {
            time => 'unixtime', temperature_2m => chr(176) . 'C', relative_humidity_2m => '%',
            precipitation => 'mm', wind_speed_10m => 'm/s', wind_direction_10m => chr(176),
            shortwave_radiation => 'W/m' . chr(178), surface_pressure => 'hPa',
        },
        hourly => {
            time => [map { $first + 3600 * $_ } 0 .. $count - 1],
            temperature_2m => [map { $_ / 10 } 0 .. $count - 1],
            relative_humidity_2m => [(80) x $count], precipitation => [(0) x $count],
            wind_speed_10m => [(3) x $count], wind_direction_10m => [(270) x $count],
            shortwave_radiation => [(0) x $count], surface_pressure => [(990) x $count],
        },
    };
}

sub fetch ($self, $location, $from, $to) {
    push @{$self->requests}, [$location, $from, $to];
    ScriptManager::Exception->throw('weather_http', 'API non disponibile') if $self->fail_request;
    my $data = __PACKAGE__->response($from, $to, $location->{elevation});
    $data->{hourly}{surface_pressure}[24] = undef if $self->null_pressure;
    return {%{__PACKAGE__->parse($data, $location, $from, $to)}, response => $data, request => 'synthetic'};
}

1;
