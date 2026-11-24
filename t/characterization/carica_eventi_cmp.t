use Mojo::Base -strict, -signatures;
use Test::More;
use File::Temp 'tempdir';
use FindBin;
use IPC::Open3;
use Mojo::File 'path';
use Symbol 'gensym';

my $dir = path(tempdir(CLEANUP => 1));
$dir->child('DBI.pm')->spew(<<'MOCK');
package DBI;
our $errstr;
sub connect { bless {}, 'MockDB' }
package MockDB;
sub selectrow_array { 9 }
sub prepare { bless {}, 'MockStatement' }
sub disconnect { 1 }
package MockStatement;
sub execute { shift; print 'MOCK_INSERT ', join('|', @_), "\n"; 1 }
sub finish { 1 }
1;
MOCK

my $script = path($FindBin::Bin, '..', '..', 'legacy', 'scripts', '12-carica_eventi_cmp.pl')->realpath;
my $header = 'Time (s);Duration (s);Durata (-10) (s);Contatore (n);Leq (dB);Leq (-10) (dB);SEL (dB);SEL (-10) (dB);LMax (dB);Simmetria (%)';
my $file = $dir->child('events.txt');

sub execute_legacy () {
    local $ENV{TZ} = 'UTC';
    my $stderr = gensym;
    my $pid = open3(my $in, my $out, $stderr, $^X, "-I$dir", "$script",
        '--database', 'test', '--user', 'test', '--file', "$file", '--centralina', '9');
    print $in "password-test\n";
    close $in;
    my $stdout = do { local $/; <$out> };
    my $error = do { local $/; <$stderr> };
    waitpid($pid, 0);
    return ($? >> 8, $stdout, $error);
}

$file->spew("Titolo\n01/01/2025\n00:00:00\n$header\n10;45;43;1;69.9;70.1;86.5;86.4;74.3;34\n");
my ($exit, $out, $err) = execute_legacy();
is $exit, 0, 'legacy accepts elapsed seconds format';
like $out, qr/MOCK_INSERT 9\|2025-01-01 00:00:10\|45\|69\.9\|70\.1\|86\.5\|86\.4\|74\.3/, 'legacy mapping';

$file->spew("Titolo\n$header\n2025-05-25 11:55:44;45;43;1;69.9;70.1;86.5;86.4;74.3;34\n"
    . "2025-05-25 11:56:44;45;43;1;69.9;70.1;86.5;86.4;74.3;34\n");
($exit, $out, $err) = execute_legacy();
isnt $exit, 0, 'legacy rejects observed timestamp-per-row format';
like $err, qr/Data non valida nella seconda riga/, 'format mismatch is explicit';
unlike $out, qr/MOCK_INSERT/, 'no event inserted for unrecognized format';

done_testing;
