package ScriptManager::Service::RunwayGeometry;
use Mojo::Base -base, -signatures;

use POSIX 'isfinite';
use Scalar::Util 'looks_like_number';
use ScriptManager::Exception;

sub _numeric (@values) {
    return !grep { !defined $_ || ref $_ || !looks_like_number($_) || !isfinite(0 + $_) } @values;
}

sub prepare ($class, $airport, $operation, $revision, $rows, $center = undef) {
    ScriptManager::Exception->throw('invalid_airport', 'Aeroporto non supportato per assegnazione piste')
        unless ($airport // '') =~ /\A(?:LIMC|LIML|LIME|LIPO)\z/;
    ScriptManager::Exception->throw('invalid_operation', 'Operazione pista non valida')
        unless ($operation // '') =~ /\A[AD]\z/;
    ScriptManager::Exception->throw('invalid_revision', 'Revisione 05 non supportata')
        if $operation eq 'A' && ($revision // '') !~ /\A1\.[012]\z/;
    ScriptManager::Exception->throw('invalid_airport', 'La revisione 1.0 non implementa Montichiari')
        if $operation eq 'A' && $revision eq '1.0' && $airport eq 'LIPO';
    my @names = $airport eq 'LIMC' ? qw(35R 17L 35L 17R)
        : $airport eq 'LIML' ? qw(36R 18L) : $airport eq 'LIME' ? qw(11 29) : qw(14 32);
    my %wanted = map { $_ => 1 } @names;
    my %points;
    for my $row (@$rows) {
        my $name = $row->[0] // '';
        $name =~ s/^\s+|\s+$//g;
        next unless $wanted{$name};
        ScriptManager::Exception->throw('runway_geometry', "Estremo pista $name duplicato o con coordinate/quota non valide")
            if exists $points{$name} || !_numeric(@$row[1 .. 3]);
        $points{$name} = [@$row[1 .. 3]];
    }
    ScriptManager::Exception->throw('runway_geometry', 'Estremi pista mancanti in anagrafica.piste')
        if grep { !exists $points{$_} } @names;
    my $height = $points{$names[0]}[2];
    my $offset = $airport eq 'LIME' ? ($operation eq 'D' || $revision ne '1.2' ? -376 : 0)
        : $airport eq 'LIPO' && $operation eq 'A' ? -2515 : 0;
    my @lines;
    while (@names) {
        my ($a, $b) = map { $points{$_} } splice @names, 0, 2;
        ScriptManager::Exception->throw('runway_geometry', 'Estremi pista coincidenti o quote aeroporto discordanti')
            if $a->[0] == $b->[0] && $a->[1] == $b->[1] || $a->[2] != $height || $b->[2] != $height;
        push @lines, [[$a->[0], $a->[1] + $offset], [$b->[0], $b->[1] + $offset]];
    }
    ScriptManager::Exception->throw('runway_geometry', 'Centro aeroporto Malpensa mancante o non valido')
        if $airport eq 'LIMC' && $operation eq 'D'
        && (!defined $center || @$center != 2 || !_numeric(@$center));
    return {airport => $airport, operation => $operation, height => $height, lines => \@lines, center => $center};
}

sub _distance ($line, $hit) {
    my ($a, $b) = @$line;
    my ($dx, $dy) = ($b->[0] - $a->[0], $b->[1] - $a->[1]);
    return abs($dy * $hit->[0] - $dx * $hit->[1] + $a->[1] * $dx - $a->[0] * $dy)
        / sqrt($dx**2 + $dy**2);
}

sub _inside ($hit, $taxi = 0) {
    my @points = $taxi
        ? ([1478955, 5050890], [1478202, 5054817], [1478830, 5054817], [1479537, 5050890])
        : ([1480339, 5040761], [1477436, 5057332], [1478637, 5058095], [1481816, 5040946]);
    for my $i (0 .. 3) {
        my ($a, $b) = @points[$i, ($i + 1) % 4];
        my $m = ($a->[1] - $b->[1]) / ($a->[0] - $b->[0]);
        my $delta = $hit->[1] - ($m * $hit->[0] + $b->[1] - $m * $b->[0]);
        $delta = -$delta if $i == 1 || $i == 2;
        return 0 if $taxi ? $delta < 0 : $delta <= 0;
    }
    return 1;
}

sub _side ($geometry, $hit) {
    my $east = _distance($geometry->{lines}[0], $hit);
    my $west = _distance($geometry->{lines}[1], $hit);
    return $east < $west ? 'E' : $east > $west ? 'W' : 'NA';
}

sub _mxp_pair ($geometry, $earlier, $later) {
    my ($a, $b) = map { _side($geometry, $_) } ($earlier, $later);
    return 'NA' if $a ne $b || $a eq 'NA';
    my $south = $earlier->[1] > $later->[1];
    return $a eq 'E' ? ($south ? '17L' : '35R') : ($south ? '17R' : '35L');
}

sub _arrival ($g, $hits) {
    if ($g->{airport} eq 'LIMC') {
        return {pista => 'N9'} if @$hits < 2;
        my $eligible = sub ($hit) { _inside($hit) && $hit->[2] < $g->{height} + 600 };
        my $pista = !$eligible->($hits->[-1]) ? 'N2' : !$eligible->($hits->[-2]) ? 'N1'
            : _mxp_pair($g, $hits->[-2], $hits->[-1]);
        if ($pista =~ /\A(?:NA|N1|N2)\z/ && @$hits >= 3
            && $eligible->($hits->[-2]) && $eligible->($hits->[-3])) {
            $pista = _mxp_pair($g, $hits->[-3], $hits->[-2]);
            return {pista => $pista, excluded => [$hits->[-1][3]]} if $pista ne 'NA';
        }
        return {pista => $pista};
    }
    my $lin = $g->{airport} eq 'LIML';
    my ($distance, $limit, $height) = $lin ? (300, 120, 300) : (600, 500, 2000);
    my ($j, $k) = ($#$hits, 0);
    while ($distance > $limit && $k < 8 && $j >= 0 && $hits->[$j][2] < $g->{height} + $height) {
        $distance = _distance($g->{lines}[0], $hits->[$j]);
        $k++;
        $j--;
    }
    # Keep the legacy sampling index and eight-iteration behavior, but never use a missing pair.
    return {pista => 'NA', reason => 'Coppia di battute insufficiente o quota fuori soglia'}
        if $j < 0 || $j + 1 > $#$hits || $hits->[$j][2] >= $g->{height} + $height;
    my $axis = $lin ? 1 : 0;
    my $decreasing = $hits->[$j][$axis] > $hits->[$j + 1][$axis];
    return {pista => $lin ? ($decreasing ? '18L' : '36R')
        : $g->{airport} eq 'LIME' ? ($decreasing ? '29' : '11') : ($decreasing ? '32' : '14')};
}

sub _departure ($g, $hits) {
    return {pista => 'NA', reason => 'Meno di due battute valide'} if @$hits < 2;
    if ($g->{airport} eq 'LIMC') {
        my ($a, $b) = @$hits[0, 1];
        my $distance = sqrt(($a->[0] - $g->{center}[0])**2 + ($a->[1] - $g->{center}[1])**2);
        my $eligible = $a->[2] < $g->{height} + 2000 && $distance < 12000;
        my $pista = 'N';
        if ($eligible) {
            # Departures use the opposite latitude comparison to arrivals when latitudes are equal.
            my ($first, $second) = map { _side($g, $_) } ($a, $b);
            $pista = $first ne $second || $first eq 'NA' ? 'NA'
                : $first eq 'E' ? ($a->[1] < $b->[1] ? '35R' : '17L')
                : ($a->[1] < $b->[1] ? '35L' : '17R');
            $pista = '35R' if $pista eq '17L' && $a->[0] > 1479860 && $b->[0] > 1479860
                && $a->[1] > 5053558 && $b->[1] > 5053558;
            $pista = '35L' if $pista eq '17R' && $a->[0] < 1477801 && $b->[0] < 1477801
                && $a->[1] > 5053077 && $b->[1] > 5053077;
            $pista = 'N1' if $a->[1] == $b->[1]
                && !grep { $_->[1] >= 5055500 || $_->[1] <= 5050500 || $_->[0] >= 1480100 || $_->[0] <= 1477600 } ($a, $b);
        }
        my $start = $eligible ? 2 : 1;
        my $outside = grep { !_inside($hits->[$_], 1) } $start .. $#$hits;
        $pista = 'N2' unless $outside;
        return {pista => $pista};
    }
    my $lin = $g->{airport} eq 'LIML';
    my ($distance, $limit, $search_height, $assign_height) = $lin ? (300, 120, 300, 2000) : (600, 500, 450, 800);
    my ($cursor, $first) = (0, undef);
    while ($cursor < @$hits) {
        $first = $hits->[$cursor++];
        last unless $distance > $limit && $first->[2] < $g->{height} + $search_height;
        $distance = _distance($g->{lines}[0], $first);
        $first = undef;
    }
    return {pista => 'NA', reason => 'Coppia di battute insufficiente o quota fuori soglia'}
        unless $first && $first->[2] < $g->{height} + $assign_height && $cursor < @$hits;
    my $second = $hits->[$cursor];
    my $axis = $lin ? 1 : 0;
    my $increasing = $first->[$axis] < $second->[$axis];
    my $pista = $lin ? ($increasing ? '36R' : '18L')
        : $g->{airport} eq 'LIME' ? ($increasing ? '11' : '29') : ($increasing ? '14' : '32');
    $pista = '36R' if $lin && $first->[1] > 5034500 && $second->[1] > 5034500;
    return {pista => $pista};
}

sub analyze ($class, $geometry, $hits) {
    for my $hit (@$hits) {
        ScriptManager::Exception->throw('invalid_hit', 'Battuta con coordinate, quota o identificatore non validi')
            unless @$hit == 4 && _numeric(@$hit);
    }
    my $result = $geometry->{operation} eq 'A' ? _arrival($geometry, $hits) : _departure($geometry, $hits);
    $result->{excluded} //= [];
    $result->{invalid} = $result->{pista} =~ /\AN/ ? 1 : 0;
    return $result;
}

1;
