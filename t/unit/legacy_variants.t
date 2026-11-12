use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File 'path';
use FindBin;
use YAML::PP;

my $root = path($FindBin::Bin, '..', '..')->realpath;
my $config = YAML::PP->new->load_file($root->child('config', '02-carica-variants.yml')->to_string)
    ->{loader_profiles};

is $config->{base_profile}, 'lin_2026', 'newest LIN profile is the declared base';
is scalar keys %{$config->{profiles}}, 10, 'all ten 02-carica variants have profiles';
is $config->{common}{input}{sample_offset_chars}, 34, 'common sample offset matches scripts';
is $config->{common}{input}{sample_length_chars}, 24, 'common sample length matches scripts';

for my $profile (values %{$config->{profiles}}) {
    ok $root->child('legacy', 'scripts', $profile->{source})->is_file,
        "$profile->{source} exists";
    ok defined $profile->{coordinate_origin_m}{x} && defined $profile->{coordinate_origin_m}{y},
        "$profile->{source} declares both coordinate offsets";
}

is $config->{profiles}{orio_radar_lin}{duplicate_tracks}{strategy},
    'reuse_existing_track_and_append_to_main_table',
    'older ORIO from LIN keeps duplicate samples in battute';
is $config->{profiles}{orio_dbltrk_new_radar}{duplicate_load_strategy},
    'short_circuit_or_chain',
    'new-radar ORIO load ordering remains explicitly represented';
ok !$config->{execution_ready}, 'profiles are not presented as runnable procedures';

done_testing;