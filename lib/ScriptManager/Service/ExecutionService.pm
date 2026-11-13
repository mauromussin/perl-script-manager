package ScriptManager::Service::ExecutionService;
use Mojo::Base -base, -signatures;

use Log::Any ();
use Scalar::Util 'blessed';
use ScriptManager::Exception;
use ScriptManager::Service::Context;

has [qw(repo registry minion output_root process_runner)];
has retention_days => 30;
has debug_operations => 0;
has logger         => sub { Log::Any->get_logger(category => 'ScriptManager::Execution') };

# Validates the input and creates an execution. Returns {id => ...} or {errors => [...]}.
sub submit ($self, $code, $input, %o) {
    my $proc = $self->registry->get($code)
        // ScriptManager::Exception->throw('unknown_procedure', 'Procedura non disponibile');
    my $validator = $self->registry->validator($proc);
    my ($params, $errors) = $validator->validate($input);
    return {errors => $errors} if @$errors;

    my $id = $self->repo->create_execution(
        procedure_code => $code,
        requested_by   => $o{requested_by} // 'anonymous',
        parameters     => $validator->redact($params),
    );
    $self->repo->add_event($id, 'info', 'Esecuzione registrata', event_type => 'state');

    if ($proc->{execution_mode} eq 'async') {
        my $job_id = $self->minion->enqueue(run_procedure => [$id], {attempts => 1});
        $self->repo->set_job_id($id, $job_id);
        $self->repo->add_event($id, 'info', "Procedura $code accodata al worker (job $job_id)", event_type => 'state');
    }
    else {
        $self->execute($id, $params);
    }
    return {id => $id};
}

sub execute ($self, $id, $params = undef) {
    my $exec = $self->repo->get_execution($id) or return;
    my $proc = $self->registry->get($exec->{procedure_code});
    return unless $self->repo->mark_running($id);

    my $ctx = ScriptManager::Service::Context->new(
        execution_id   => $id,
        repo           => $self->repo,
        output_root    => $self->output_root,
        logger         => $self->logger,
        debug_operations => $self->debug_operations,
        retention_days => $proc ? ($proc->{retention_days} // $self->retention_days) : $self->retention_days,
    );
    $ctx->log(info => 'Esecuzione avviata', event_type => 'state');

    my ($result, $err);
    if (!$proc) {
        $err = ScriptManager::Exception->new(code => 'procedure_disabled', message => 'Procedura non più disponibile');
    }
    else {
        my $timeout = $proc->{timeout_seconds};
        my $ok      = eval {
            local $SIG{ALRM} = sub {
                die ScriptManager::Exception->new(code => 'timed_out', message => "Timeout di $timeout secondi superato");
            };
            alarm $timeout;
            $ctx->log(info => "Preparazione comando $proc->{handler_class}; timeout $timeout secondi");
            my $handler = $proc->{handler_class}->new(logger => $self->logger, process_runner => $self->process_runner);
            $result = $handler->run($ctx, $params // $exec->{parameters});
            alarm 0;
            1;
        };
        alarm 0;
        $err = $@ || 'errore sconosciuto' unless $ok;
    }

    my %final = $self->_outcome($result, $err, $id);
    my $level = $final{status} eq 'completed' ? 'info'
        : ($final{error_code} // '') eq 'internal_error' ? 'critical'
        : $final{status} eq 'cancelled' ? 'warning' : 'error';
    $ctx->log($level, $final{summary} // $final{error_message}, event_type => 'state');
    $self->repo->mark_finished($id, %final);
    return $final{status};
}

sub _outcome ($self, $result, $err, $id) {
    if (!$err) {
        return (status => 'completed', exit_code => 0, summary => $result->{message} // 'Completata')
            if ref $result eq 'HASH' && $result->{success};
        return (
            status        => 'failed',
            exit_code     => 1,
            error_code    => 'command_failed',
            error_message => (ref $result eq 'HASH' && $result->{message}) || 'La procedura ha restituito un errore',
        );
    }
    if (ScriptManager::Exception->caught($err)) {
        my $status = $err->code eq 'timed_out' ? 'timed_out' : $err->code eq 'cancelled' ? 'cancelled' : 'failed';
        return (status => $status, exit_code => 1, error_code => $err->code, error_message => $err->message);
    }
    $self->logger->critical("[CRITICAL] [exec=$id] Errore non gestito: $err");
    return (status => 'failed', exit_code => 1, error_code => 'internal_error',
        error_message => "Errore interno durante l'esecuzione. Consultare i log di app e worker "
            . "(docker compose logs app worker) cercando l'identificatore $id per la causa tecnica");
}

# Returns the resulting status ('cancelled' | 'cancel_requested') or undef if not cancellable.
sub cancel ($self, $id) {
    my $status = $self->repo->request_cancel($id) or return undef;
    my $exec   = $self->repo->get_execution($id);
    if ($status eq 'cancelled') {
        if (defined $exec->{minion_job_id} and my $job = $self->minion->job($exec->{minion_job_id})) {
            $job->remove;
        }
        $self->repo->add_event($id, 'warning', 'Esecuzione annullata prima dell\'avvio', event_type => 'state');
    }
    else {
        $self->repo->add_event($id, 'warning', 'Annullamento richiesto', event_type => 'state');
    }
    return $status;
}

sub register_tasks ($self) {
    $self->minion->add_task(
        run_procedure => sub ($job, $id) {
            my $exec = $self->repo->get_execution($id) or return $job->fail('Esecuzione non trovata');
            my $proc = $self->registry->get($exec->{procedure_code});
            my $guard;
            if ($proc && $proc->{exclusive}) {
                $guard = $job->minion->guard("procedure:$exec->{procedure_code}", $proc->{timeout_seconds} + 60, {limit => 1})
                    or return $job->retry({delay => 5, attempts => $job->retries + 2});
            }
            $self->execute($id);
            return;
        }
    );
    return $self;
}

1;
