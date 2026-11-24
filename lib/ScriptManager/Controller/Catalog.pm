package ScriptManager::Controller::Catalog;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use ScriptManager::Exception;
use ScriptManager::Service::EventiCMP;

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
    if ($proc->{code} eq 'carica_eventi_cmp') {
        $values->{database} //= $c->param('database');
        $values->{airport} //= $c->param('airport');
        return render_eventi($c, $proc, $values, []);
    }
    return $c->render(
        procedure => $proc,
        validator => $c->registry->validator($proc),
        values    => $values,
        errors    => [],
    );
}

sub render_eventi ($c, $proc, $values, $errors) {
    my $preview;
    if (defined $values->{database} && length $values->{database}
        && defined $values->{airport} && length $values->{airport}) {
        $preview = eval { ScriptManager::Service::EventiCMP->new->preview(@$values{qw(database airport)}) };
        if (my $error = $@) {
            if (ScriptManager::Exception->caught($error)) {
                push @$errors, {path => '', message => $error->message};
            } else {
                $c->app->log->error("Preparazione importazione eventi fallita: $error");
                push @$errors, {path => '', message => 'Impossibile preparare l importazione; consultare i log applicativi'};
            }
        }
    }
    return $c->render('catalog/eventi', procedure => $proc, values => $values,
        preview => $preview, errors => $errors, status => @$errors ? 422 : 200);
}

1;
