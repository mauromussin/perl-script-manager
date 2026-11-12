use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(getcwd abs_path);
use FindBin;
use Digest::SHA qw(sha256_hex);

my $script = abs_path("$FindBin::Bin/../../docker/export-image.sh");
my $original_dir = getcwd;
my $work = tempdir(CLEANUP => 1);
my $bin = File::Spec->catdir($work, 'bin');
mkdir $bin or die "mkdir $bin: $!";
my $docker = File::Spec->catfile($bin, 'docker');
open my $mock, '>', $docker or die "open $docker: $!";
print {$mock} <<'SH';
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$DOCKER_TEST_LOG"
case "$1" in
    tag) exit 0 ;;
    save)
        [ "${DOCKER_TEST_FAIL:-}" != save ] || exit 17
        printf 'saved production image\n' > "$3"
        ;;
    load)
        [ "${DOCKER_TEST_FAIL:-}" != load ] || exit 18
        test -s "$3"
        ;;
    image)
        if [ "${DOCKER_TEST_FAIL:-}" = identity ] && [ "$3" = perl-script-manager:production ]; then
            printf 'sha256:different\n'
        else
            printf 'sha256:production\n'
        fi
        ;;
    *) exit 19 ;;
esac
SH
close $mock or die "close $docker: $!";
chmod 0755, $docker or die "chmod $docker: $!";

local $ENV{PATH} = "$bin:$ENV{PATH}";
local $ENV{DOCKER_TEST_LOG} = File::Spec->catfile($work, 'docker.log');
local $ENV{DOCKER_TEST_FAIL};
chdir $work or die "chdir $work: $!";

is system('sh', $script), 0, 'exports and reloads the production image';
open my $checksum, '<', 'image-artifact/perl-script-manager.tar.sha256' or die $!;
my $checksum_line = <$checksum>;
close $checksum;
my $expected_hash = sha256_hex("saved production image\n");
like $checksum_line, qr/^\Q$expected_hash\E\s+perl-script-manager\.tar$/,
    'checksum matches the exported archive';
open my $log, '<', $ENV{DOCKER_TEST_LOG} or die $!;
my $commands = do { local $/; <$log> };
close $log;
like $commands, qr/^save --output image-artifact\/perl-script-manager\.tar perl-script-manager:production$/m,
    'archive uses the local production tag';
like $commands, qr/^load --input image-artifact\/perl-script-manager\.tar$/m,
    'archive is reimported before checking identity';

for my $failure (qw(save load identity)) {
    $ENV{DOCKER_TEST_FAIL} = $failure;
    isnt system('sh', $script), 0, "fails explicitly on $failure error";
}

chdir $original_dir or die "chdir $original_dir: $!";
done_testing;
