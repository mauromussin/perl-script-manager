package ScriptManager::Controller::Dashboard;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use ScriptManager::Exception;
use ScriptManager::Service::Dashboard;

sub index ($c) {
    my $data = eval {
        ScriptManager::Service::Dashboard->new(repo => $c->repo)->load(
            $c->registry->all, $c->param('database'), $c->param('year'));
    };
    my $error = $@;
    if ($error) {
        die $error unless ScriptManager::Exception->caught($error, 'invalid_dashboard_filter');
        return $c->render(text => $error->message, status => 422);
    }
    return $c->render(%$data);
}

1;
