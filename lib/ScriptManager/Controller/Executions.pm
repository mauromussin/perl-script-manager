package ScriptManager::Controller::Executions;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::File 'path';
use ScriptManager::Exception;

my @STATUSES = qw(queued running completed failed cancel_requested cancelled timed_out);

sub create ($c) {
    return $c->render(text => 'Token CSRF non valido', status => 403)
        if $c->validation->csrf_protect->has_error('csrf_token');

    my $proc = $c->registry->get($c->param('code')) or return $c->reply->not_found;
    my $validator = $c->registry->validator($proc);
    my $input     = $validator->from_form($c->req->body_params);
    my $result    = $c->execution_service->submit($proc->{code}, $input, requested_by => $c->current_user);

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
    return $c->render(
        execution => $exec,
        events    => $c->repo->list_events($exec->{id}),
        artifacts => $c->repo->list_artifacts($exec->{id}),
        refresh   => $final ? 0 : 2,
    );
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
    return $c->reply->not_found unless index("$real_file", "$real_base/") == 0;

    my $name = $art->{stored_name} =~ s/[^A-Za-z0-9._-]/_/gr;
    my $h    = $c->res->headers;
    $h->content_type($art->{media_type});
    $h->content_disposition(qq{attachment; filename="$name"});
    $h->header('Content-Security-Policy' => 'sandbox');
    return $c->reply->file($real_file);
}

1;
