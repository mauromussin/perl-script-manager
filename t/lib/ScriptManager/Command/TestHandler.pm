package ScriptManager::Command::TestHandler;
use Mojo::Base -base, -signatures;

use Time::HiRes ();

has [qw(logger process_runner)];

sub run ($self, $ctx, $p) {
    my $mode = $p->{mode} // 'sum';
    return {success => 1, message => 'sum=' . ($p->{a} + $p->{b}), data => {}} if $mode eq 'sum';
    return {success => 0, message => 'boom'} if $mode eq 'fail';
    die "dettaglio interno /etc/passwd\n" if $mode eq 'die';
    if ($mode eq 'slow') { Time::HiRes::sleep(5); return {success => 1, message => 'late'} }
    return {success => 1, message => 'token length ' . length $p->{token}} if $mode eq 'secret';
    return {success => 0, message => 'modo sconosciuto'};
}

1;
