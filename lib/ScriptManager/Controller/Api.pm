package ScriptManager::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub procedures ($c) {
    my @list = map { +{%{$_}{qw(code name description execution_mode timeout_seconds parameter_schema)}} }
        @{$c->registry->enabled};
    return $c->render(json => {procedures => \@list});
}

sub create ($c) {
    my $input = $c->req->json;
    return $c->render(json => {error => 'Corpo JSON (oggetto) richiesto'}, status => 400)
        unless ref $input eq 'HASH';
    my $proc = $c->registry->get($c->param('code')) or return $c->render(json => {error => 'Procedura non trovata'}, status => 404);

    my $result = $c->execution_service->submit($proc->{code}, $input, requested_by => $c->current_user);
    return $c->render(json => {errors => $result->{errors}}, status => 422) if $result->{errors};
    return $c->render(json => {id => $result->{id}}, status => 201);
}

sub status ($c) {
    my $exec = $c->repo->get_execution($c->param('id')) or return $c->render(json => {error => 'Esecuzione non trovata'}, status => 404);
    my %out = map { $_ => $exec->{$_} } qw(
        id procedure_code status parameters progress current_step requested_by requested_at
        started_at finished_at exit_code summary error_code error_message
    );
    $out{events} = [map { +{%{$_}{qw(level event_type message created_at)}} } @{$c->repo->list_events($exec->{id})}];
    $out{artifacts} = [
        map { +{%{$_}{qw(id original_name media_type size_bytes sha256 created_at expires_at)}} }
            @{$c->repo->list_artifacts($exec->{id})}
    ];
    return $c->render(json => \%out);
}

1;
