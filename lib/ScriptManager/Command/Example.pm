package ScriptManager::Command::Example;
use Mojo::Base -base, -signatures;

use Encode 'encode';
use Time::HiRes 'sleep';

has [qw(logger process_runner)];

sub run ($self, $ctx, $params) {
    my $repeat = $params->{repeat} // 3;
    my $delay  = $params->{delay_seconds} // 0;
    my $case   = $params->{case} // 'unchanged';
    my $text   = $params->{message};
    $text = uc $text if $case eq 'upper';
    $text = lc $text if $case eq 'lower';

    $ctx->log(info => "Elaborazione di $repeat passaggi");
    my @lines;
    for my $i (1 .. $repeat) {
        $ctx->check_cancel;
        push @lines, "$i: $text";
        $ctx->progress(int(100 * $i / $repeat), "Passaggio $i di $repeat");
        sleep $delay if $delay > 0;
    }

    if ($params->{write_file}) {
        $ctx->write_artifact('output.txt', encode('UTF-8', join("\n", @lines) . "\n"));
        $ctx->log(info => 'File output.txt generato');
    }

    return {success => 1, message => "Completati $repeat passaggi", data => {lines => scalar @lines}};
}

1;
