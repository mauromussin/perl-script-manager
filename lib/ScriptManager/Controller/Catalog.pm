package ScriptManager::Controller::Catalog;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use ScriptManager::Exception;
use ScriptManager::Service::EventiCMP;
use ScriptManager::Service::CorrelazioneSetup;

sub health ($c) {
    my $ok = eval { $c->pg->db->query('select 1'); 1 };
    return $c->render(text => $ok ? 'ok' : 'database non raggiungibile', status => $ok ? 200 : 503);
}

sub index ($c) {
    return $c->render(procedures => [grep { !$_->{ui_hidden} } @{$c->registry->enabled}]);
}

sub show ($c) {
    my $proc = $c->registry->get($c->param('code')) or return $c->reply->not_found;
    return $c->reply->not_found if $proc->{ui_hidden};

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
    if ($proc->{code} eq 'correla_eventi_cmp') {
        $values->{airport} //= $c->param('airport');
        $values->{database} //= $c->param('database');
        return render_correlation($c, $proc, $values, []);
    }
    return $c->render(
        procedure => $proc,
        validator => $c->registry->validator($proc),
        values    => $values,
        errors    => [],
    );
}

sub render_correlation ($c, $proc, $values, $errors) {
    my ($databases, $preview);
    my $setup = ScriptManager::Service::CorrelazioneSetup->new(repo => $c->repo);
    if (defined $values->{airport} && length $values->{airport}) {
        my $ok = eval {
            $databases = $setup->databases($values->{airport});
            $preview = $setup->preview(@$values{qw(airport database)})
                if defined $values->{database} && length $values->{database};
            1;
        };
        unless ($ok) {
            my $error = $@;
            if (ScriptManager::Exception->caught($error)) {
                push @$errors, {path => '', message => $error->message};
            } else {
                $c->app->log->error("Preparazione correlazione fallita: $error");
                push @$errors, {path => '', message => 'Impossibile preparare la correlazione; consultare i log applicativi'};
            }
        }
    }
    return $c->render('catalog/correlazione', procedure => $proc, values => $values,
        databases => $databases, preview => $preview, errors => $errors, status => @$errors ? 422 : 200);
}

sub prepare_correlation ($c) {
    return $c->render(text => 'Token CSRF non valido', status => 403)
        if $c->validation->csrf_protect->has_error('csrf_token');
    my $proc = $c->registry->get('correla_eventi_cmp') or return $c->reply->not_found;
    my $values = {airport => $c->param('airport'), database => $c->param('database')};
    return $c->render(text => 'Confermare esplicitamente la creazione delle tabelle', status => 422)
        unless ($c->param('confirm_schema') // '') eq '1';
    my $setup = ScriptManager::Service::CorrelazioneSetup->new(repo => $c->repo);
    my $tables = $c->req->body_params->every_param('missing_table');
    my $ok = eval { $setup->prepare(@$values{qw(airport database)}, $tables); 1 };
    unless ($ok) {
        my $error = $@;
        $c->app->log->error("Creazione tabelle correlazione fallita: $error");
        my $message = ScriptManager::Exception->caught($error) ? $error->message
            : 'Creazione tabelle fallita: alcune tabelle potrebbero essere state create; consultare i log';
        return render_correlation($c, $proc, $values, [{path => '', message => $message}]);
    }
    $c->app->log->warn('Tabelle di correlazione create per ' . $values->{database} . ': ' . join(', ', @$tables));
    return $c->redirect_to($c->url_for('procedure', code => 'correla_eventi_cmp')
        ->query(airport => $values->{airport}, database => $values->{database}));
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
