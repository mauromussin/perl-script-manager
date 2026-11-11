use Mojo::Base -strict;
use Test::More;
use ScriptManager::Exception;
use ScriptManager::Service::ProcessRunner;

my $runner = ScriptManager::Service::ProcessRunner->new(
    allowed          => {perl => $^X},
    max_output_bytes => 20,
);

my $r = $runner->run(perl => ['-e', 'print "ciao"; print STDERR "err"; exit 3']);
is $r->{exit_code}, 3, 'exit code';
is $r->{stdout}, 'ciao', 'stdout';
is $r->{stderr}, 'err', 'stderr';

$r = $runner->run(perl => ['-e', 'print "x" x 100']);
is length $r->{stdout}, 20, 'output truncated';
ok $r->{truncated}, 'truncation flagged';

$r = $runner->run(perl => ['-e', 'print $ARGV[0]', 'a; echo injected']);
is $r->{stdout}, 'a; echo injected', 'arguments are not interpreted by a shell';

eval { $runner->run('rm', ['-rf', '/']) };
ok(ScriptManager::Exception->caught($@, 'process_not_allowed'), 'unlisted program rejected');

eval { $runner->run(perl => [undef]) };
ok(ScriptManager::Exception->caught($@, 'process_bad_args'), 'undefined argument rejected');

eval { $runner->run(perl => ['-e', 'sleep 10'], timeout => 1) };
ok(ScriptManager::Exception->caught($@, 'timed_out'), 'timeout enforced');

done_testing;
