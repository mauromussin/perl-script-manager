package ScriptManager::Controller::Dashboard;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use ScriptManager::Exception;
use ScriptManager::Service::Dashboard;
use ScriptManager::Service::CorrelazioniDashboard;
use ScriptManager::Service::CorrelazioneDelete;
use Mojo::JSON ();

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

sub correlation_delete_preview ($c) {
    my $params = {map { $_ => scalar $c->param($_) } qw(airport database day station_id station_code)};
    my $preview = eval { ScriptManager::Service::CorrelazioneDelete->new->preview($params) };
    if (my $error = $@) {
        $c->app->log->error("Verifica cancellazione correlazione fallita: $error");
        return $c->render(text => ScriptManager::Exception->caught($error) ? $error->message
            : 'Verifica non disponibile; consultare i log applicativi', status => 422);
    }
    return $c->render('dashboard/correlation_delete', params => $params, preview => $preview);
}

sub correlation_delete ($c) {
    return $c->render(text => 'Token CSRF non valido', status => 403)
        if $c->validation->csrf_protect->has_error('csrf_token');
    return $c->render(text => 'Confermare esplicitamente la cancellazione', status => 422)
        unless ($c->param('confirm_deletion') // '') eq '1';
    my $params = {map { $_ => scalar $c->param($_) }
        qw(airport database day station_id station_code snapshot)};
    $params->{confirm_deletion} = Mojo::JSON::true;
    my $result = $c->execution_service->submit(elimina_correlazione_cmp => $params,
        requested_by => $c->current_user);
    return $c->render(json => {errors => $result->{errors}}, status => 422) if $result->{errors};
    return $c->redirect_to('execution', id => $result->{id});
}

1;
