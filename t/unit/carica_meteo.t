use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use Mojo::File 'path';
use lib "$FindBin::Bin/../lib";
use TestOpenMeteo;
use Mojo::JSON qw(encode_json);
use Mojo::Transaction::HTTP;
use Mojo::URL;
use ScriptManager::Command::CaricaMeteo;
use ScriptManager::Service::ProcedureRegistry;
use POSIX 'tzset';

my %legacy;
for my $version (qw(1.3 1.4 1.5 1.6)) {
    my $source = path($FindBin::Bin, '..', '..', 'legacy', 'scripts',
        "09-carica_dati_meteo_$version.pl")->slurp;
    $source =~ s/\r\n/\n/g;
    $source =~ /(sub convertiData.*)/s or die "Conversioni legacy $version non trovate";
    my $code = $1;
    my $package = 'LegacyWeather' . ($version =~ s/\.//gr);
    my $ok = eval "package $package; no strict; no warnings; $code\n1;";
    die $@ unless $ok;
    $legacy{$version} = $package;
}

sub convert_legacy ($version, $airport, $station, @values) {
    no strict 'refs';
    return [&{"$legacy{$version}::convertiStringa"}($airport, $station, @values)];
}

subtest 'caratterizzazione delle quattro varianti, senza accessi DB' => sub {
    my @raw = ('18/11/2025', '14:00:00', 1, 12, 270, 280, 3, 80, 40, 50, 1000);
    for my $version (qw(1.4 1.5 1.6)) {
        is_deeply convert_legacy($version, 'LIME', 0, @raw),
            ['2025-11-18 14:00:00', 1, 12, 270, 280, 3, 80, 40, 50, 1000], "$version: mappatura standard";
    }
    is_deeply convert_legacy('1.3', 'LIME', 0, @raw),
        ['2025-11-18 14:00:00', 270, 80, 1, 12, 50, 40, undef, 3, 280], '1.3: diverso tracciato LIME/Lonate';
    is_deeply convert_legacy('1.6', 'LIPO', 0, @raw),
        convert_legacy('1.5', 'LIPO', 0, @raw), 'ramo LIPO separato ma equivalente in 1.6';
    is_deeply convert_legacy('1.4', 'LIPO', 0, @raw), [(undef) x 10], 'LIPO non implementato in 1.4';
    my $cgp = convert_legacy('1.6', 'LIMC', 1, @raw);
    cmp_ok abs($cgp->[9] - 1.3332 * $raw[5]), '<', 0.00001, 'CGP applica il fattore 1.3332 alla pressione';
    is convert_legacy('1.6', 'LIMC', 3, @raw)->[9], undef, 'Somma non ha pressione';
    $raw[1] = '24:00:00';
    $raw[2] = '*';
    my $r = convert_legacy('1.6', 'LIML', 0, @raw);
    is $r->[0], '2025-11-18 23:59:59', 'ora 24 legacy portata a 23:59:59 dello stesso giorno';
    is $r->[1], undef, 'asterisco significa NULL, non zero';
};

subtest 'Open-Meteo: mappatura ARP, unita e campi non equivalenti NULL' => sub {
    my $loc = TestOpenMeteo->location('LIMC', 233.782);
    cmp_ok abs($loc->{latitude} - 45.63), '<', 0.000001;
    my $weather = TestOpenMeteo->new;
    my $r = $weather->fetch($loc, '2025-01-15', '2025-01-15');
    is scalar @{$r->{rows}}, 24;
    is $r->{rows}[0]{local}, '2025-01-15 00:00:00';
    is $r->{rows}[-1]{local}, '2025-01-15 23:00:00';
    is_deeply $r->{rows}[1]{values}, ['2025-01-15 01:00:00', 0, 2.4, 270, undef, 3, 80, undef, 0, 990],
        'pressione superficiale hPa, vento m/s, radiazione globale W/m2; nessuna conversione mmHg';
    for my $airport (qw(LIMC LIML LIME LIPO)) {
        ok(TestOpenMeteo->location($airport, 100)->{source}, "$airport: coordinate geografiche e fonte ARP");
    }
    eval { TestOpenMeteo->location('XXXX', 100) };
    ok(ScriptManager::Exception->caught($@, 'invalid_airport'));
    eval { TestOpenMeteo->location('LIMC', undef) };
    ok(ScriptManager::Exception->caught($@, 'weather_location'), 'nessuna quota di default inventata');
};

subtest 'ora italiana DST: 23 ore a marzo, seconda 02:00 a ottobre' => sub {
    local $ENV{TZ} = 'UTC';
    tzset();
    my $weather = TestOpenMeteo->new;
    my $loc = $weather->location('LIMC', 233.782);
    my $r = $weather->fetch($loc, '2025-03-30', '2025-03-30');
    is scalar @{$r->{rows}}, 23, 'nessuna ora 02:00 inventata';
    ok !grep({ $_->{local} eq '2025-03-30 02:00:00' } @{$r->{rows}});
    $r = $weather->fetch($loc, '2025-10-26', '2025-10-26');
    is scalar @{$r->{rows}}, 24, '25 ore fisiche diventano 24 righe legacy';
    is_deeply $r->{discarded}, [{
        local => '2025-10-26 02:00:00', discarded_utc => $weather->epoch('2025-10-26'),
        kept_utc => $weather->epoch('2025-10-26') + 3600,
    }];
    my ($repeated) = grep { $_->{local} eq '2025-10-26 02:00:00' } @{$r->{rows}};
    is $repeated->{values}[2], 2.5, 'conservata davvero la seconda temperatura';
    is CORE::localtime($weather->epoch('2025-10-26')) =~ /00:00:00/ ? 1 : 0, 1, 'fuso del processo ripristinato';
    is scalar @{$r->{response}{hourly}{time}}, 48, 'report conserva tutte le ore UTC originali';
};

subtest 'dati incompleti o unita errate non diventano zeri o successi' => sub {
    my $loc = TestOpenMeteo->location('LIMC', 233.782);
    for my $case (qw(null units truncated gap duplicate nonnumeric negative pressure elevation)) {
        my $data = TestOpenMeteo->response('2025-01-15', '2025-01-15');
        $data->{hourly}{surface_pressure}[24] = undef if $case eq 'null';
        $data->{hourly_units}{wind_speed_10m} = 'km/h' if $case eq 'units';
        pop @{$data->{hourly}{temperature_2m}} if $case eq 'truncated';
        $data->{hourly}{time}[24] += 3600 if $case eq 'gap';
        $data->{hourly}{time}[24] = $data->{hourly}{time}[23] if $case eq 'duplicate';
        $data->{hourly}{surface_pressure}[24] = 'NA' if $case eq 'nonnumeric';
        $data->{hourly}{precipitation}[24] = -1 if $case eq 'negative';
        $data->{hourly}{surface_pressure}[24] = 10000 if $case eq 'pressure';
        $data->{elevation} = 0 if $case eq 'elevation';
        eval { TestOpenMeteo->parse($data, $loc, '2025-01-15', '2025-01-15') };
        ok(ScriptManager::Exception->caught($@, 'weather_data'), "$case: errore esplicito");
    }
};

{
    package WeatherUA;
    use Mojo::Base -base, -signatures;
    has [qw(tx url)];
    sub get ($self, $url) { $self->url($url); return $self->tx }
}

subtest 'contratto HTTP: archivio, ARP, ora UTC, margine e nessun fallback' => sub {
    my $tx = Mojo::Transaction::HTTP->new;
    $tx->res->code(200)->body(encode_json(TestOpenMeteo->response('2025-01-15', '2025-01-15')));
    $tx->res->headers->content_type('application/json');
    my $ua = WeatherUA->new(tx => $tx);
    my $weather = ScriptManager::Service::OpenMeteo->new(ua => $ua);
    my $loc = $weather->location('LIMC', 233.782);
    my $r = $weather->fetch($loc, '2025-01-15', '2025-01-15');
    is scalar @{$r->{rows}}, 24;
    is $ua->url->host, 'archive-api.open-meteo.com';
    is $ua->url->query->param('latitude'), $loc->{latitude}, 'non invia coordinate proiettate';
    is $ua->url->query->param('elevation'), 233.782;
    is $ua->url->query->param('start_date'), '2025-01-14', 'margine per mezzanotte italiana';
    is $ua->url->query->param('timezone'), 'UTC';
    is $ua->url->query->param('timeformat'), 'unixtime';
    like $ua->url->query->param('hourly'), qr/surface_pressure/;
    $tx->res->code(429);
    eval { $weather->fetch($loc, '2025-01-15', '2025-01-15') };
    ok(ScriptManager::Exception->caught($@, 'weather_http'), 'rate limit non viene nascosto');
    $tx = Mojo::Transaction::HTTP->new;
    $tx->res->code(200)->body('not json');
    $tx->res->headers->content_type('application/json');
    $ua->tx($tx);
    eval { $weather->fetch($loc, '2025-01-15', '2025-01-15') };
    ok(ScriptManager::Exception->caught($@, 'weather_data'));
    eval { $weather->fetch($loc, '2025-01-01', '2025-01-14') };
    ok(ScriptManager::Exception->caught($@, 'weather_request_size'),
        '14 giorni locali piu margine superano il costo di una chiamata: blocco prima di HTTP');
};

subtest 'catalogo e contratto parametri: date obbligatorie anche in run' => sub {
    my $root = path($FindBin::Bin, '..', '..')->realpath;
    local $ENV{MRT_CONFIG_FILE} = $root->child('config', 'MRT.example.json')->to_string;
    my $registry = ScriptManager::Service::ProcedureRegistry->new(file => $root->child('config', 'procedures.yml'))->load;
    my $validator = $registry->validator($registry->get('carica_meteo'));
    my (undef, $errors) = $validator->validate({database => 'radar_test', airport => 'LIMC'});
    ok @$errors, 'date obbligatorie sul form/API/CLI';
    (undef, $errors) = $validator->validate({
        database => 'radar_test', airport => 'LIMC', date_from => '2025-01-15', date_to => '2025-01-15'});
    is_deeply $errors, [];
    eval { ScriptManager::Command::CaricaMeteo->new->run(undef, {database => 'radar_test', airport => 'LIMC'}) };
    ok(ScriptManager::Exception->caught($@, 'invalid_date_range'), 'anche chiamata diretta richiede entrambe le date');
};

done_testing;
