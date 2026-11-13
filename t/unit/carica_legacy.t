use strict;
use warnings;
use Test::More;
use FindBin;
use YAML::PP;
use ScriptManager::Command::CaricaDB;

my $root = "$FindBin::Bin/../..";
my $profiles = YAML::PP->new->load_file("$root/config/02-carica-variants.yml")->{loader_profiles}{profiles};
local $ENV{TZ} = 'Europe/Rome';
my $header = '20260202120000ABC1234 B738LIMLLIME';
my $sample = sprintf '%06d%06d%06d%s', 64, -64, 100, '120060';
my $i = 0;

for my $id (sort keys %$profiles) {
    my $profile = $profiles->{$id};
    open my $fh, '<', "$root/legacy/scripts/$profile->{source}" or die $!;
    my $source = do { local $/; <$fh> };
    close $fh;
    $source =~ s/\r\n/\n/g;
    $source =~ /^(sub fIntTrac\b.*)\z/ms or die "Funzioni legacy non trovate: $id";
    my $package = 'LegacyCarica' . ++$i;
    my $ok = eval "package $package; use Time::Local; no strict; no warnings; $1; 1;";
    die $@ unless $ok;
    no strict 'refs';
    my @track = &{"${package}::fIntTrac"}($header, 'LIML');
    is_deeply [@track[0 .. 6]], ['ABC1234', '20260202', '120000', 'B738', 'LIML', 'LIME', 'D'],
        "$id: parsing intestazione";
    is $track[7], '2026-2-2 13:0:0', "$id: UTC convertito in Europe/Rome";
    my @hit = &{"${package}::fBattuta"}($sample, '20260202');
    cmp_ok abs($hit[1] - ($profile->{coordinate_origin_m}{x} + 1852.2)), '<', 0.000001,
        "$id: offset X";
    cmp_ok abs($hit[2] - ($profile->{coordinate_origin_m}{y} - 1852.2)), '<', 0.000001,
        "$id: offset Y";
    cmp_ok abs($hit[3] - 3048), '<', 0.000001, "$id: altitudine";
    is $hit[4], '2026-2-2 13:0:59', "$id: secondo 60 corretto nella data locale";
    my $new_track = ScriptManager::Command::CaricaDB->track($header, 'LIML');
    is_deeply $new_track, [@track[0 .. 7]], "$id: loader unificato conserva intestazione";
    my $new_hit = ScriptManager::Command::CaricaDB->hit($sample, '20260202',
        {x_m => $profile->{coordinate_origin_m}{x}, y_m => $profile->{coordinate_origin_m}{y}});
    is $new_hit->[0], $hit[0], "$id: ora UTC conservata";
    for my $field (1 .. 3) {
        cmp_ok abs($new_hit->[$field] - $hit[$field]), '<', 0.000001, "$id: battuta campo $field equivalente";
    }
    is $new_hit->[4], $hit[4], "$id: data locale equivalente";
}

done_testing;
