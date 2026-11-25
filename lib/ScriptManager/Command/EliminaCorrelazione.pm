package ScriptManager::Command::EliminaCorrelazione;
use Mojo::Base -base, -signatures;

use ScriptManager::Service::CorrelazioneDelete;

has [qw(logger process_runner)];

sub run ($self, $ctx, $params) {
    return ScriptManager::Service::CorrelazioneDelete->new->run($ctx, $params);
}

1;
