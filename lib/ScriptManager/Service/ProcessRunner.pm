package ScriptManager::Service::ProcessRunner;
use Mojo::Base -base, -signatures;

use IPC::Run ();
use POSIX ();
use ScriptManager::Exception;

# name => absolute path of the approved executables
has allowed => sub { {} };
has max_output_bytes => 1_048_576;
has default_timeout  => 60;

# Runs an approved program without a shell. Returns {exit_code, stdout, stderr, truncated}.
sub run ($self, $name, $args = [], %o) {
    my $exe = $self->allowed->{$name}
        // ScriptManager::Exception->throw('process_not_allowed', "Programma non ammesso: $name");
    ScriptManager::Exception->throw('process_not_found', "Programma non eseguibile: $name") unless -x $exe;
    ScriptManager::Exception->throw('process_bad_args', 'Argomenti non validi')
        if grep { !defined($_) || ref($_) } @$args;

    my $timeout = $o{timeout} // $self->default_timeout;
    my %env     = %{$o{env} // {}};
    my ($in, $out, $err) = ('', '', '');

    local %ENV = (PATH => '/usr/bin:/bin', LANG => 'C.UTF-8', %env);
    my $cwd = $o{cwd};
    my $h   = eval {
        IPC::Run::start(
            [$exe, @$args], \$in, \$out, \$err,
            IPC::Run::timeout($timeout, exception => 'process_timeout'),
            init => sub {
                POSIX::setsid();
                if ($cwd) { chdir $cwd or die "chdir: $!" }
            },
        );
    };
    ScriptManager::Exception->throw('process_start_failed', "Avvio non riuscito: $name") unless $h;

    my $finished = eval { $h->finish; 1 };
    unless ($finished) {
        my $e = $@;
        my $pid = eval { $h->{KIDS}[0]{PID} };
        kill 'KILL', -$pid if $pid;
        eval { $h->kill_kill };
        ScriptManager::Exception->throw('timed_out', "Timeout nell'esecuzione di $name")
            if "$e" =~ /process_timeout/;
        ScriptManager::Exception->throw('process_failed', "Errore nell'esecuzione di $name");
    }

    my $max       = $self->max_output_bytes;
    my $truncated = (length($out) > $max || length($err) > $max) ? 1 : 0;
    return {
        exit_code => $h->result(0),
        stdout    => substr($out, 0, $max),
        stderr    => substr($err, 0, $max),
        truncated => $truncated,
    };
}

1;
