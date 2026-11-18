package ScriptManager::Service::SIDGeometry;
use Mojo::Base -base, -signatures;

use POSIX 'isfinite';
use Scalar::Util 'looks_like_number';
use ScriptManager::Exception;

# Order and half-plane directions reproduce 2.2 dal_2015_corr, including its nonstandard PIA5D region.
my %RULES = (
    LIMC => [
        ['070', ['35R'], '-++-', [[1481809,5058260],[1483762,5054300],[1480663,5054194],[1479914,5057691]]],
        ['071', ['35R'], '-++-', [[1481119,5059866],[1481763,5058329],[1479469,5057434],[1479126,5058149]]],
        ['358', ['35R'], '-+++', [[1477729,5060985],[1480050,5060942],[1479408,5058786],[1477736,5058563]]],
        ['280', ['35L'], '--+-', [[1472274,5058746],[1474498,5057356],[1475288,5054065],[1472250,5054536]]],
        ['310', ['35L'], '-++-', [[1471707,5062155],[1473670,5060074],[1472217,5058976],[1469277,5059726]]],
        ['320', ['35L'], '-++-', [[1475273,5061126],[1476715,5059343],[1474864,5059246],[1472998,5060996]]],
        ['294', ['17L','17R'], '-++-', [[1465813,5054241],[1476236,5052011],[1474813,5041242],[1463736,5044280]]],
        ['038', ['17L','17R'], '--++', [[1483066,5056252],[1498021,5069326],[1514641,5048669],[1496109,5036434]]],
    ],
    LIML => [
        ['SRN5C', ['36R'], '+--+', [[1515090.853,5037026.835],[1507453.303,5037133.903],[1512842.416,5052444.693],[1515733.264,5046662.996]]],
        ['NIKMO', ['36R'], '+-++', [[1515733.264,5046662.996],[1512842.416,5052444.693],[1523763.398,5052837.277],[1521764.787,5046091.964]]],
        ['TZO5C', ['36R'], '--++', [[1521764.787,5046091.964],[1523763.398,5052837.277],[1527386.793,5044235.742],[1523849.096,5043280.995]]],
        ['DORIN', ['36R'], '-+++', [[1523849.096,5043280.995],[1527386.793,5044235.742],[1526663.33,5038601.306],[1523889.223,5039132.145]]],
        ['PIKOT', ['36R'], '-++-', [[1523889.223,5039132.145],[1526663.33,5038601.306],[1525959.213,5031208.137],[1523139.744,5032814.164]]],
        ['PIA5D', ['18L'], '-++-', [[1527401.35,5028891.24],[1523580.173,5030277.09],[1526069.32,5023912.946],[1522920.885,5025581.347]]],
        ['SSUD', ['18L'], '-+--', [[1522920.885,5025581.347],[1526069.32,5023912.946],[1515403.694,5022993.038],[1516721.395,5026540.678]]],
    ],
    LIME => [
        ['267', ['29'], '++--', [[1547614.38,5058795.07],[1547344.51,5056548.76],[1545439.50,5056159.82],[1545685.57,5058683.95]]],
        ['220', ['29'], '-+--', [[1549609.10,5057383.96],[1550211.54,5056898.01],[1546639.65,5055755.00],[1547892.20,5057096.45]]],
        ['044', ['29'], '++--', [[1552815.04,5057239.32],[1551664.10,5055921.69],[1550132.16,5055334.32],[1550529.04,5057374.26]]],
    ],
);

my %COMPILED;
for my $airport (keys %RULES) {
    $COMPILED{$airport} = [map {
        my ($sid, $runways, $signs, $points) = @$_;
        my @lines;
        for my $i (0 .. 3) {
            my ($a, $b) = @$points[$i, ($i + 1) % 4];
            my $m = ($a->[1] - $b->[1]) / ($a->[0] - $b->[0]);
            push @lines, [$m, $b->[1] - $m * $b->[0], substr($signs, $i, 1)];
        }
        {sid => $sid, runways => {map { $_ => 1 } @$runways}, lines => \@lines};
    } @{$RULES{$airport}}];
}

sub analyze ($class, $airport, $runway, $hits, $ctx = undef) {
    ScriptManager::Exception->throw('invalid_airport', 'SID 2.2 corr supporta solo LIMC, LIML e LIME')
        unless exists $COMPILED{$airport // ''};
    ScriptManager::Exception->throw('invalid_runway', 'Pista mancante o non valida')
        unless defined $runway && !ref $runway && length $runway;
    for my $hit (@$hits) {
        ScriptManager::Exception->throw('invalid_hit', 'Battuta SID con coordinate o quota non valide')
            unless @$hit == 3 && !grep {
                !defined $_ || ref $_ || !looks_like_number($_) || !isfinite(0 + $_)
            } @$hit;
    }
    for my $i (1 .. $#$hits) {
        $ctx->check_cancel if $ctx;
        return '150' if $airport eq 'LIME' && $runway eq '11';
        my ($x, $y, $h) = @{$hits->[$i]};
        next unless $h < ($airport eq 'LIMC' ? 3000 : 3500);
        RULE: for my $rule (@{$COMPILED{$airport}}) {
            next unless $rule->{runways}{$runway};
            for my $line (@{$rule->{lines}}) {
                my $boundary = $line->[0] * $x + $line->[1];
                next RULE unless $line->[2] eq '+' ? $y > $boundary : $y < $boundary;
            }
            return $rule->{sid};
        }
    }
    return $runway eq '17L' || $runway eq '17R' ? '168' : 'NA' if $airport eq 'LIMC';
    return undef;
}

1;
