package ScriptManager::Controller::Catalog;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub health ($c) {
    my $ok = eval { $c->pg->db->query('select 1'); 1 };
    return $c->render(text => $ok ? 'ok' : 'database non raggiungibile', status => $ok ? 200 : 503);
}

sub index ($c) {
    return $c->render(procedures => $c->registry->enabled);
}

sub show ($c) {
    my $proc = $c->registry->get($c->param('code')) or return $c->reply->not_found;

    # "from" prefills the form with the stored parameters of a previous execution (re-run).
    my $values = {};
    if (my $from = $c->param('from')) {
        my $e = $c->repo->get_execution($from);
        $values = $e->{parameters} if $e && $e->{procedure_code} eq $proc->{code};
    }
    return $c->render(
        procedure => $proc,
        validator => $c->registry->validator($proc),
        values    => $values,
        errors    => [],
    );
}

1;
