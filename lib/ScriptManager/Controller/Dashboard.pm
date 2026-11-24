package ScriptManager::Controller::Dashboard;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use ScriptManager::Exception;
use ScriptManager::Service::Dashboard;
use ScriptManager::Service::CorrelazioniDashboard;

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

sub correlations ($c) {
    my $data = eval {
        ScriptManager::Service::CorrelazioniDashboard->new(repo => $c->repo)
            ->load($c->param('airport'), $c->param('year'));
    };
    if (my $error = $@) {
        $c->app->log->error("Cruscotto correlazioni non disponibile: $error");
        return $c->render(text => ScriptManager::Exception->caught($error) ? $error->message
            : 'Impossibile leggere il cruscotto correlazioni; consultare i log applicativi',
            status => ScriptManager::Exception->caught($error, 'invalid_dashboard_filter') ? 422 : 503);
    }
    return $c->render('dashboard/correlations', %$data);
}

1;
