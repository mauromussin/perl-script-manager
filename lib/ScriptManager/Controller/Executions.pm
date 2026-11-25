package ScriptManager::Controller::Executions;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::File 'path';
use ScriptManager::Controller::Catalog ();
use ScriptManager::Exception;
use ScriptManager::Service::CorrelazioneSetup;
use ScriptManager::Service::CorrelazioneReview;

my @STATUSES = qw(queued running completed failed cancel_requested cancelled timed_out);

sub duplicate_options ($c) {
    my $id = $c->param('confirm_completed_execution');
    return defined $id && ($c->param('confirm_duplicate') // '') eq '1'
        ? (confirm_completed_execution => $id) : ();
}

sub render_duplicate ($c, $proc, $duplicate) {
    return $c->render('executions/confirm_duplicate', procedure => $proc,
        duplicate => $duplicate, form => $c->req->body_params, status => 409);
}

sub create ($c) {
    return $c->render(text => 'Token CSRF non valido', status => 403)
        if $c->validation->csrf_protect->has_error('csrf_token');

    my $proc = $c->registry->get($c->param('code')) or return $c->reply->not_found;
    my $validator = $c->registry->validator($proc);
    my $input     = $proc->{code} eq 'correla_eventi_cmp'
        ? ScriptManager::Service::CorrelazioneSetup->new->form_input($c->req->body_params)
        : $validator->from_form($c->req->body_params);
    my %options = (requested_by => $c->current_user, duplicate_options($c));
    if ($proc->{code} eq 'carica_db') {
        my $values = $c->req->body_params->every_param('confirm_timeout_bypass');
        return $c->render(text => 'Conferma timeout non valida', status => 422)
            if @$values && (@$values != 1 || $values->[0] ne '1');
        if (@$values) {
            $options{timeout_bypass_confirmed} = 1;
            $c->stash(timeout_bypass_confirmed => 1);
        }
    }
    my $result = $c->execution_service->submit($proc->{code}, $input, %options);

    return render_duplicate($c, $proc, $result->{duplicate}) if $result->{duplicate};
    return ScriptManager::Controller::Catalog::render_eventi($c, $proc, $input, $result->{errors})
        if $result->{errors} && $proc->{code} eq 'carica_eventi_cmp';
    return ScriptManager::Controller::Catalog::render_correlation($c, $proc, $input, $result->{errors})
        if $result->{errors} && $proc->{code} eq 'correla_eventi_cmp';
    return ScriptManager::Controller::Catalog::render_laeq($c, $proc, $input, $result->{errors})
        if $result->{errors} && $proc->{code} eq 'calcola_laeq';
    return $c->render(
        'catalog/show',
        procedure => $proc,
        validator => $validator,
        values    => $input,
        errors    => $result->{errors},
        status    => 422,
    ) if $result->{errors};
    return $c->redirect_to('execution', id => $result->{id});
}

sub index ($c) {
    my %f;
    for my $key (qw(procedure user id)) {
        my $v = $c->param($key);
        $f{$key} = $v if defined $v && length $v && length $v <= 100;
    }
    my $status = $c->param('status') // '';
    $f{status} = $status if grep { $_ eq $status } @STATUSES;
    for my $key (qw(from to)) {
        my $v = $c->param($key) // '';
        $f{$key} = $v if $v =~ /\A\d{4}-\d\d-\d\d\z/;
    }

    my $size = $c->app->config->{page_size};
    my $page = ($c->param('page') // '') =~ /\A([1-9]\d{0,5})\z/ ? $1 : 1;
    my $rows = $c->repo->list_executions(%f, limit => $size + 1, offset => ($page - 1) * $size);
    my $more = @$rows > $size;
    pop @$rows if $more;

    return $c->render(
        executions => $rows,
        filters    => \%f,
        page       => $page,
        has_more   => $more,
        procedures => $c->registry->all,
        statuses   => \@STATUSES,
    );
}

sub show ($c) {
    my $exec = $c->repo->get_execution($c->param('id')) or return $c->reply->not_found;
    my $final = $c->is_final($exec->{status});
    my $duplicate_source;
    if (($exec->{error_code} // '') eq 'duplicate_confirmation_required') {
        my $proc = $c->registry->get($exec->{procedure_code});
        if ($proc && !$c->registry->validator($proc)->has_sensitive) {
            my ($event) = grep { ($_->{metadata}{operation} // '') eq 'duplicate_detected' }
                @{$c->repo->list_events($exec->{id})};
            $duplicate_source = $event->{metadata}{source_execution_id} if $event;
        }
    }
    return $c->render(
        execution => $exec,
        events    => $c->repo->latest_events($exec->{id}),
        artifacts => $c->repo->list_artifacts($exec->{id}),
        refresh   => $final ? 0 : 2,
        can_bypass_timeout => $c->execution_service->can_bypass_timeout($exec),
        duplicate_confirmation_source => $duplicate_source,
    );
}

sub confirm_queued_duplicate ($c) {
    return $c->render(text => 'Token CSRF non valido', status => 403)
        if $c->validation->csrf_protect->has_error('csrf_token');
    return $c->render(text => 'Confermare esplicitamente la riesecuzione', status => 422)
        unless ($c->param('confirm_duplicate') // '') eq '1';
    my $exec = $c->repo->get_execution($c->param('id')) or return $c->reply->not_found;
    return $c->render(text => 'Conferma non disponibile per questa esecuzione', status => 409)
        unless $exec->{status} eq 'failed'
        && ($exec->{error_code} // '') eq 'duplicate_confirmation_required';
    my $proc = $c->registry->get($exec->{procedure_code});
    return $c->render(text => 'Procedura non disponibile o con parametri sensibili da reinserire', status => 409)
        unless $proc && !$c->registry->validator($proc)->has_sensitive;
    if (defined $exec->{queue_target}) {
        my $host = $ENV{MYSQL_HOST} // '';
        my $port = $ENV{MYSQL_PORT} // 3306;
        return $c->render(text => 'Target MySQL cambiato: inviare una nuova richiesta', status => 409)
            unless $host =~ /\A[A-Za-z0-9.:-]+\z/ && $port =~ /\A\d+\z/
            && join(':', lc($host), 0 + $port, $exec->{parameters}{database} // '') eq $exec->{queue_target};
    }
    my $events = $c->repo->list_events($exec->{id});
    my ($duplicate) = grep { ($_->{metadata}{operation} // '') eq 'duplicate_detected' } @$events;
    return $c->render(text => 'Riferimento alla precedente esecuzione non disponibile', status => 409)
        unless $duplicate && $duplicate->{metadata}{source_execution_id};
    my %options = (requested_by => $c->current_user,
        confirm_completed_execution => $duplicate->{metadata}{source_execution_id});
    if ($exec->{timeout_bypassed}) {
        my ($bypass) = grep { ($_->{metadata}{operation} // '') eq 'timeout_bypass' } @$events;
        return $c->render(text => 'Conferma del timeout non disponibile', status => 409) unless $bypass;
        if (($bypass->{metadata}{source} // '') eq 'initial_confirmation') {
            $options{timeout_bypass_confirmed} = 1;
        } else {
            my $source_id = $bypass->{metadata}{source_execution_id};
            my $source = $c->repo->get_execution($source_id);
            return $c->render(text => 'Conferma del timeout non piu valida', status => 409)
                unless $c->execution_service->can_bypass_timeout($source);
            $options{timeout_bypass_from} = $source_id;
        }
    }
    my $result = $c->execution_service->submit($proc->{code}, $exec->{parameters}, %options);
    return $c->render(json => {errors => $result->{errors}}, status => 422) if $result->{errors};
    return $c->redirect_to('execution', id => $result->{id});
}

sub correlation_results ($c) {
    my $review = ScriptManager::Service::CorrelazioneReview->new(repo => $c->repo);
    my ($execution, $results);
    my $ok = eval {
        my $references;
        ($execution, $references) = $review->source($c->param('id'));
        $results = $review->results($execution, $references);
        1;
    };
    unless ($ok) {
        my $error = $@;
        $c->app->log->error("Consultazione risultati correlazione fallita: $error");
        my $message = ScriptManager::Exception->caught($error) ? $error->message
            : 'Risultati non disponibili; consultare i log applicativi';
        return $c->render(text => $message, status => 422);
    }
    return $c->render('executions/correlation_results', execution => $execution, results => $results, errors => []);
}

sub correlation_activate ($c) {
    return $c->render(text => 'Token CSRF non valido', status => 403)
        if $c->validation->csrf_protect->has_error('csrf_token');
    return $c->render(text => 'Confermare esplicitamente l attualizzazione', status => 422)
        unless ($c->param('confirm_activation') // '') eq '1';
    my $review = ScriptManager::Service::CorrelazioneReview->new(repo => $c->repo);
    my $execution;
    my $ok = eval { ($execution) = $review->source($c->param('id')); 1 };
    unless ($ok) {
        my $error = $@;
        $c->app->log->error("Selezione risultati correlazione fallita: $error");
        return $c->render(text => ScriptManager::Exception->caught($error) ? $error->message
            : 'Risultati non disponibili; consultare i log applicativi', status => 422);
    }
    my $result = $c->execution_service->submit(attualizza_correlazione_cmp => {
        map({ $_ => $execution->{parameters}{$_} } qw(database airport)),
        source_execution_id => $execution->{id},
        activations => $c->req->body_params->every_param('activations'),
        confirm_activation => Mojo::JSON::true,
    }, requested_by => $c->current_user, duplicate_options($c));
    return render_duplicate($c, $c->registry->get('attualizza_correlazione_cmp'), $result->{duplicate})
        if $result->{duplicate};
    return $c->render(json => {errors => $result->{errors}}, status => 422) if $result->{errors};
    return $c->redirect_to('execution', id => $result->{id});
}

sub retry_without_timeout ($c) {
    return $c->render(text => 'Token CSRF non valido', status => 403)
        if $c->validation->csrf_protect->has_error('csrf_token');
    my $exec = $c->repo->get_execution($c->param('id')) or return $c->reply->not_found;
    return $c->render(text => 'Bypass non disponibile per questa esecuzione', status => 409)
        unless $c->execution_service->can_bypass_timeout($exec);
    return $c->render(text => 'Confermare esplicitamente la disattivazione del timeout', status => 422)
        unless ($c->param('confirm_timeout_bypass') // '') eq '1';
    my $result = $c->execution_service->submit($exec->{procedure_code}, {},
        requested_by => $c->current_user, timeout_bypass_from => $exec->{id}, duplicate_options($c));
    return render_duplicate($c, $c->registry->get($exec->{procedure_code}), $result->{duplicate})
        if $result->{duplicate};
    return $c->render(json => {errors => $result->{errors}}, status => 422) if $result->{errors};
    return $c->redirect_to('execution', id => $result->{id});
}

sub cancel ($c) {
    return $c->render(text => 'Token CSRF non valido', status => 403)
        if $c->validation->csrf_protect->has_error('csrf_token');
    my $exec = $c->repo->get_execution($c->param('id')) or return $c->reply->not_found;
    $c->execution_service->cancel($exec->{id});
    return $c->redirect_to('execution', id => $exec->{id});
}

sub download ($c) {
    my $exec = $c->repo->get_execution($c->param('id')) or return $c->reply->not_found;
    my $art  = $c->repo->get_artifact($exec->{id}, $c->param('artifact_id')) or return $c->reply->not_found;

    my $base = path($c->output_root, $exec->{id});
    return $c->reply->not_found unless -d $base;
    my $file = path($c->output_root, split('/', $art->{relative_path}));
    return $c->reply->not_found unless -f $file;

    my ($real_base, $real_file) = ($base->realpath, $file->realpath);
    return $c->reply->not_found unless CORE::index("$real_file", "$real_base/") == 0;

    my $name = $art->{stored_name} =~ s/[^A-Za-z0-9._-]/_/gr;
    my $h    = $c->res->headers;
    $h->content_type($art->{media_type});
    $h->content_disposition(qq{attachment; filename="$name"});
    $h->header('Content-Security-Policy' => 'sandbox');
    return $c->reply->file($real_file);
}

1;
