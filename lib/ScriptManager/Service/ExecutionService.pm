package ScriptManager::Service::ExecutionService;
use Mojo::Base -base, -signatures;

use Log::Any ();
use Scalar::Util 'blessed';
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use ScriptManager::Exception;
use ScriptManager::Service::Context;

has [qw(repo registry minion output_root process_runner)];
has retention_days => 30;
has debug_operations => 0;
has next_reconciliation => 0;
has logger         => sub { Log::Any->get_logger(category => 'ScriptManager::Execution') };

# Validates the input and creates an execution. Returns {id => ...} or {errors => [...]}.
sub submit ($self, $code, $input, %o) {
    my $proc = $self->registry->get($code)
        // ScriptManager::Exception->throw('unknown_procedure', 'Procedura non disponibile');
    my $source;
    if (defined $o{timeout_bypass_from}) {
        $source = $self->repo->get_execution($o{timeout_bypass_from});
        ScriptManager::Exception->throw('timeout_bypass_not_allowed',
            'Il bypass richiede una 04 bloccata dalla stima oltre il timeout')
            unless $code eq 'valida_battute' && $self->can_bypass_timeout($source);
        $input = $source->{parameters};
    }
    my $validator = $self->registry->validator($proc);
    my ($params, $errors) = $validator->validate($input);
    return {errors => $errors} if @$errors;

    my $target;
    if ($proc->{queue_by_database}) {
        return {errors => [{path => '/database', message => 'Configurazione host/porta MySQL o database non valida per la coda'}]}
            unless ($ENV{MYSQL_HOST} // '') =~ /\A[A-Za-z0-9.:-]+\z/
                && ($ENV{MYSQL_PORT} // 3306) =~ /\A\d+\z/
                && ($ENV{MYSQL_PORT} // 3306) > 0 && ($ENV{MYSQL_PORT} // 3306) <= 65535
                && ($params->{database} // '') =~ /\A[A-Za-z0-9_]{1,64}\z/;
        $target = join ':', lc($ENV{MYSQL_HOST}), 0 + ($ENV{MYSQL_PORT} // 3306), $params->{database};
    }
    my $id = $self->repo->create_execution(
        procedure_code => $code,
        requested_by   => $o{requested_by} // 'anonymous',
        parameters     => $validator->redact($params),
        queue_target   => $target,
        timeout_bypassed => $source ? 1 : 0,
    );
    $self->repo->add_event($id, 'info', 'Esecuzione registrata', event_type => 'state');
    $self->repo->add_event($id, 'warning',
        'Conferma utente: controllo della stima e timeout reale disattivati per questa esecuzione; '
        . 'possibili scritture parziali in caso di interruzione',
        event_type => 'state', metadata => {operation => 'timeout_bypass', source_execution_id => $source->{id}})
        if $source;

    if ($proc->{execution_mode} eq 'async') {
        my $job_id = eval { $self->minion->enqueue(run_procedure => [$id], {attempts => 1}) };
        unless (defined $job_id) {
            $self->logger->error("[exec=$id] Registrazione Minion fallita: " . ($@ || 'identificatore job assente'));
            my $message = 'Registrazione nel worker fallita; inviare una nuova richiesta';
            $self->repo->mark_finished($id, status => 'failed', exit_code => 1,
                error_code => 'queue_enqueue_failed', error_message => $message);
            $self->repo->add_event($id, 'error', $message, event_type => 'state');
            ScriptManager::Exception->throw('queue_enqueue_failed', $message);
        }
        $self->repo->set_job_id($id, $job_id);
        $self->repo->add_event($id, 'info', "Procedura $code accodata al worker (job $job_id)", event_type => 'state');
    }
    else {
        $self->execute($id, $params);
    }
    return {id => $id};
}

sub can_bypass_timeout ($self, $exec) {
    my $proc = $self->registry->get('valida_battute');
    return $exec && $proc && $proc->{queue_by_database}
        && $exec->{procedure_code} eq 'valida_battute' && $exec->{status} eq 'failed'
        && ($exec->{error_code} // '') eq 'timeout_estimate' && !$exec->{timeout_bypassed} ? 1 : 0;
}

sub execute ($self, $id, $params = undef) {
    my $exec = $self->repo->get_execution($id) or return;
    return unless $exec->{status} eq 'queued';
    my $proc = $self->registry->get($exec->{procedure_code});
    my $queue_guard;
    if (defined $exec->{queue_target}) {
        $queue_guard = $self->repo->claim_database_queue($exec);
        unless ($queue_guard) {
            $self->repo->note_queue_wait($id);
            return 'queued';
        }
        my $target = join ':', lc($ENV{MYSQL_HOST} // ''), 0 + ($ENV{MYSQL_PORT} // 3306),
            $exec->{parameters}{database};
        if ($target ne $exec->{queue_target}) {
            $self->repo->mark_finished($id, status => 'failed', exit_code => 1,
                error_code => 'queue_target_changed',
                error_message => 'Host/porta MySQL cambiati dopo la richiesta. Inviare una nuova richiesta.');
            $self->repo->add_event($id, 'error', 'Target della coda diverso dalla configurazione attuale');
            return 'failed';
        }
    }
    my $execution_guard = $self->repo->lock_execution($id) or return;
    return unless $self->repo->mark_running($id);

    my $bypassed = $exec->{procedure_code} eq 'valida_battute' && $exec->{timeout_bypassed};
    my $ctx = ScriptManager::Service::Context->new(
        execution_id   => $id,
        repo           => $self->repo,
        output_root    => $self->output_root,
        logger         => $self->logger,
        debug_operations => $self->debug_operations,
        retention_days => $proc ? ($proc->{retention_days} // $self->retention_days) : $self->retention_days,
        timeout_seconds => $proc ? $proc->{timeout_seconds} : 3600,
        timeout_bypassed => $bypassed ? 1 : 0,
        started_monotonic => clock_gettime(CLOCK_MONOTONIC),
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
            alarm($bypassed ? 0 : $timeout);
            $ctx->log(info => "Preparazione comando $proc->{handler_class}; "
                . ($bypassed ? 'timeout disattivato con conferma utente' : "timeout $timeout secondi"));
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
        : ($final{error_code} // '') =~ /\A(?:internal_error|mysql_recovery_required|mysql_already_published)\z/ ? 'critical'
        : $final{status} eq 'cancelled' ? 'warning' : 'error';
    $ctx->log($level, $final{summary} // $final{error_message}, event_type => 'state');
    $self->repo->mark_finished($id, %final);
    $ctx->validation_guard(undef);
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

sub reconcile_interrupted ($self, $force = 0) {
    my $now = clock_gettime(CLOCK_MONOTONIC);
    return 0 if !$force && $now < $self->next_reconciliation;
    $self->minion->repair;
    my $count = 0;
    for my $exec (@{$self->repo->running_jobs}) {
        my $guard = $self->repo->lock_execution($exec->{id}) or next;
        my $job = $self->minion->backend->list_jobs(0, 1, {ids => [$exec->{minion_job_id}]})->{jobs}[0];
        next if $job && $job->{state} eq 'active';
        my $state = $job ? $job->{state} : 'missing';
        my $changed = $self->repo->mark_interrupted($exec->{id}, $exec->{minion_job_id}, $state);
        $self->logger->error("[exec=$exec->{id}] Worker interrotto; job Minion $state, possibili scritture parziali")
            if $changed;
        $count += $changed;
    }
    $self->next_reconciliation(clock_gettime(CLOCK_MONOTONIC) + 30);
    return $count;
}

sub register_tasks ($self) {
    $self->minion->on(worker => sub ($minion, $worker) {
        $worker->on($_ => sub { $self->reconcile_interrupted }) for qw(wait busy);
    });
    $self->minion->add_task(
        run_procedure => sub ($job, $id) {
            my $exec = $self->repo->get_execution($id) or return $job->fail('Esecuzione non trovata');
            my $proc = $self->registry->get($exec->{procedure_code});
            my $guard;
            if ($proc && $proc->{exclusive} && !defined $exec->{queue_target}) {
                $guard = $job->minion->guard("procedure:$exec->{procedure_code}", $proc->{timeout_seconds} + 60, {limit => 1})
                    or return $job->retry({delay => 5, attempts => $job->retries + 2});
            }
            my $status = $self->execute($id);
            return $job->retry({delay => 5, attempts => $job->retries + 2})
                if defined $status && $status eq 'queued';
            return;
        }
    );
    return $self;
}

1;
