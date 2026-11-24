package ScriptManager::Command::AttualizzaCorrelazione;
use Mojo::Base -base, -signatures;

use ScriptManager::Service::CorrelazioneReview;

has [qw(logger process_runner)];

sub run ($self, $ctx, $params) {
    return ScriptManager::Service::CorrelazioneReview->new(repo => $ctx->repo)->activate($ctx, $params);
}

1;
