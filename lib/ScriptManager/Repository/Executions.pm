package ScriptManager::Repository::Executions;
use Mojo::Base -base, -signatures;
use ScriptManager::Exception;

# Mojo::Pg instance
has 'pg';

my $UUID_RE = qr/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i;

sub is_uuid ($class, $value) { return defined $value && $value =~ $UUID_RE }

my $EXECUTION_SELECT = <<'SQL';
select e.*, p.code as procedure_code, p.name as procedure_name
  from executions e join procedures p on p.id = e.procedure_id
SQL

# ---- procedures ----------------------------------------------------------

sub sync_procedures ($self, $procedures) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    for my $p (@$procedures) {
        $db->query(
            <<'SQL', @{$p}{qw(code name description)}, $p->{enabled} ? 1 : 0,
insert into procedures
  (code, name, description, enabled, handler_class, execution_mode, timeout_seconds, parameter_schema)
values (?, ?, ?, ?, ?, ?, ?, ?)
on conflict (code) do update set
  name = excluded.name, description = excluded.description, enabled = excluded.enabled,
  handler_class = excluded.handler_class, execution_mode = excluded.execution_mode,
  timeout_seconds = excluded.timeout_seconds, parameter_schema = excluded.parameter_schema,
  updated_at = now()
SQL
            @{$p}{qw(handler_class execution_mode timeout_seconds)},
            {json => $p->{parameter_schema}}
        );
    }
    $tx->commit;
    return;
}

# ---- executions ----------------------------------------------------------

sub lock_validation_target ($self, $target) {
    # Keep only the lock in this transaction; ledger invalidations must survive command failures.
    my $db = $self->pg->db;
    my $tx = $db->begin;
    my $locked = $db->query('select pg_try_advisory_xact_lock(hashtextextended(?, 0)) as locked',
        "validation:$target")->hash->{locked};
    ScriptManager::Exception->throw('validation_busy', 'Un altro comando 03-10 sta operando sullo stesso database')
        unless $locked;
    return {db => $db, tx => $tx};
}

sub completed_validation_days ($self, $target, $code) {
    return $self->pg->db->query(
        'select d.day::text from validation_days d join executions e on e.id = d.execution_id '
        . "where d.target = ? and d.procedure_code = ? and e.status = 'completed' order by d.day",
        $target, $code)->arrays->map(sub { $_->[0] })->to_array;
}

sub invalidate_validation_days ($self, $target, $codes, $days) {
    return unless @$days;
    $self->pg->db->query('delete from validation_days where target = ? and procedure_code in ('
        . join(',', ('?') x @$codes) . ') and day in (' . join(',', ('?') x @$days) . ')',
        $target, @$codes, @$days);
}

sub complete_validation_days ($self, $target, $code, $days, $execution_id) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    for my $day (@$days) {
        $db->query('insert into validation_days (target, procedure_code, day, execution_id) values (?, ?, ?, ?) '
            . 'on conflict (target, procedure_code, day) do update '
            . 'set execution_id = excluded.execution_id, completed_at = now()',
            $target, $code, $day, $execution_id);
    }
    $tx->commit;
}

sub weather_usage ($self, $execution_id, $db = undef) {
    $db //= $self->pg->db;
    return $db->query(q{
        select count(*) filter (where reserved_at > clock_timestamp() - interval '1 minute') as minute,
          count(*) filter (where reserved_at > clock_timestamp() - interval '1 hour') as hour,
          count(*) filter (where reserved_at > clock_timestamp() - interval '24 hours') as day,
          count(*) as month, count(*) filter (where execution_id = ?) as execution_requests,
          clock_timestamp()::text as checked_at
        from weather_api_calls where reserved_at > clock_timestamp() - interval '31 days'
    }, $execution_id)->hash;
}

sub reserve_weather_call ($self, $execution_id, $limits) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    $db->query('select pg_advisory_xact_lock(hashtextextended(?, 0))', 'open-meteo:public-budget');
    my $usage = $self->weather_usage($execution_id, $db);
    for my $window (qw(minute hour day month)) {
        ScriptManager::Exception->throw('weather_quota', "Budget Open-Meteo locale esaurito: $window ($limits->{$window})")
            if $usage->{$window} >= $limits->{$window};
    }
    my $id = $db->query('insert into weather_api_calls (execution_id) values (?) returning id', $execution_id)->hash->{id};
    $tx->commit;
    return $id;
}

sub finish_weather_call ($self, $id, $success) {
    $self->pg->db->query('update weather_api_calls set status = ? where id = ?', $success ? 'succeeded' : 'failed', $id);
}

sub invalidate_weather_day ($self, $target, $day) {
    $self->pg->db->query('delete from weather_days where target = ? and day = ?', $target, $day);
    $self->invalidate_validation_days($target, ['correggi_quote'], [$day]);
}

sub record_weather_day ($self, $target, $day, $location, $fingerprint, $execution_id) {
    $self->pg->db->query(q{
        insert into weather_days (target, day, location, fingerprint, execution_id) values (?, ?, ?, ?, ?)
        on conflict (target, day) do update set location = excluded.location,
          fingerprint = excluded.fingerprint, execution_id = excluded.execution_id
    }, $target, $day, {json => $location}, $fingerprint, $execution_id);
}

sub weather_day ($self, $target, $day) {
    return $self->pg->db->query(q{
        select w.location, w.fingerprint from weather_days w join executions e on e.id = w.execution_id
        where w.target = ? and w.day = ? and e.status = 'completed'
    }, $target, $day)->expand->hash;
}

sub create_execution ($self, %args) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    $db->query('select pg_advisory_xact_lock(hashtextextended(?, 0))', "queue-submit:$args{queue_target}")
        if defined $args{queue_target};
    my $id = $db->query(
        <<'SQL', $args{requested_by}, {json => $args{parameters} // {}}, $args{queue_target}, $args{timeout_bypassed} ? 1 : 0, $args{procedure_code}
insert into executions (procedure_id, requested_by, parameters, queue_target, timeout_bypassed)
select id, ?::text, ?::jsonb, ?::text, ?::boolean from procedures where code = ?
returning id
SQL
    )->hash->{id};
    $tx->commit;
    return $id;
}

sub get_execution ($self, $id) {
    return undef unless $self->is_uuid($id);
    my $exec = $self->pg->db->query("$EXECUTION_SELECT where e.id = ?", $id)->expand->hash;
    if ($exec && defined $exec->{queue_target} && $exec->{status} eq 'queued') {
        $exec->{queue_position} = $self->pg->db->query(q{
            select count(*) + 1 as position from executions
            where queue_target = ? and queue_order < ? and status in ('queued', 'running', 'cancel_requested')
        }, $exec->{queue_target}, $exec->{queue_order})->hash->{position};
    }
    return $exec;
}

sub lock_execution ($self, $id) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    return undef unless $db->query(
        'select pg_try_advisory_xact_lock(hashtextextended(?, 0)) as locked',
        "execution:$id")->hash->{locked};
    return {db => $db, tx => $tx};
}

sub running_jobs ($self) {
    return $self->pg->db->query(q{
        select id, minion_job_id from executions
        where status in ('running', 'cancel_requested') and minion_job_id is not null
    })->hashes->to_array;
}

sub mark_interrupted ($self, $id, $job_id, $job_state) {
    my $message = 'Worker interrotto: job Minion non piu attivo; possibili scritture parziali. '
        . 'Verificare i dati prima di rieseguire; nessun retry automatico.';
    my $db = $self->pg->db;
    my $tx = $db->begin;
    my $changed = $db->query(q{
        update executions set status = 'failed', finished_at = now(), exit_code = 1,
          error_code = 'worker_interrupted', error_message = ?, current_step = ?
        where id = ? and minion_job_id = ? and status in ('running', 'cancel_requested')
    }, $message, 'Esecuzione interrotta: job Minion non piu attivo', $id, $job_id)->rows;
    if ($changed) {
        $db->query(q{
            insert into execution_events (execution_id, level, event_type, message, metadata)
            values (?, 'error', 'state', ?, ?)
        }, $id, $message, {json => {operation => 'execution_reconciliation',
            minion_job_id => $job_id, minion_state => $job_state}});
    }
    $tx->commit;
    return $changed;
}

sub claim_database_queue ($self, $exec) {
    my $db = $self->pg->db;
    my $tx = $db->begin;
    return undef unless $db->query(
        'select pg_try_advisory_xact_lock(hashtextextended(?, 0)) as locked',
        "database-queue:$exec->{queue_target}")->hash->{locked};
    # A running managed execution without its lock was interrupted, not safely retryable.
    my $orphans = $self->pg->db->query(q{
        update executions set status = 'failed', finished_at = now(), exit_code = 1,
          error_code = 'worker_interrupted',
          error_message = 'Worker interrotto; possibili scritture parziali. Verificare i dati prima di rieseguire.'
        where queue_target = ? and status in ('running', 'cancel_requested') returning id
    }, $exec->{queue_target})->hashes->to_array;
    $self->add_event($_->{id}, 'error',
        'Worker interrotto: lock della coda rilasciato senza conclusione; nessun retry automatico')
        for @$orphans;
    my $first = $db->query(q{
        select id from executions where queue_target = ? and status = 'queued'
        order by queue_order limit 1
    }, $exec->{queue_target})->hash;
    return undef unless $first && $first->{id} eq $exec->{id};
    return {db => $db, tx => $tx};
}

sub note_queue_wait ($self, $id) {
    my $step = 'In attesa del proprio turno nella coda del database';
    my $changed = $self->pg->db->query(q{
        update executions set current_step = ? where id = ? and status = 'queued'
          and current_step is distinct from ?
    }, $step, $id, $step)->rows;
    $self->add_event($id, 'info', $step, event_type => 'state') if $changed;
}

sub battute_timing_events ($self, $target, $exclude_id) {
    return $self->validation_timing_events($target, $exclude_id, 'valida_battute', 'validation_saving');
}

sub validation_timing_events ($self, $target, $exclude_id, $code, $operation) {
    my ($database) = $target =~ /:([^:]+)\z/;
    return $self->pg->db->query(q{
        with recent as (
          select e.id from executions e join procedures p on p.id = e.procedure_id
          where p.code = ? and e.id <> ?
            and e.requested_at >= now() - interval '90 days'
            and (e.queue_target = ? or (e.queue_target is null and e.parameters->>'database' = ?))
            and exists (select 1 from execution_events measured where measured.execution_id = e.id
              and (measured.message ~ 'Salvataggio:.*[0-9]+ di [0-9]+ operazioni'
                or measured.metadata->>'operation' = ?))
          order by e.requested_at desc limit 10
        )
        select v.execution_id, extract(epoch from v.created_at) as time, v.message, v.metadata
        from recent e join execution_events v on v.execution_id = e.id
        where v.message like 'Salvataggio:%' or v.metadata->>'operation' = ?
        order by v.execution_id, v.id
    }, $code, $exclude_id, $target, $database, $operation, $operation)->expand->hashes->to_array;
}

sub dashboard_databases ($self) {
    return $self->pg->db->query(q{
        select distinct parameters->>'database' as database
        from executions
        where jsonb_typeof(parameters->'database') = 'string'
          and length(parameters->>'database') > 0
        order by database
    })->arrays->map(sub { $_->[0] })->to_array;
}

sub dashboard_executions ($self, $database) {
    return $self->pg->db->query(q{
        select e.id, p.code as procedure_code, p.name as procedure_name, e.status,
          e.parameters->>'date_from' as date_from, e.parameters->>'date_to' as date_to,
          to_char(e.finished_at at time zone 'Europe/Rome', 'DD/MM/YYYY') as finished_date,
          to_char(e.requested_at at time zone 'Europe/Rome', 'DD/MM/YYYY HH24:MI:SS') as requested_date
        from executions e join procedures p on p.id = e.procedure_id
        where e.parameters->>'database' = ?
        order by e.requested_at desc, e.queue_order desc nulls last, e.id desc
    }, $database)->hashes->to_array;
}

sub list_executions ($self, %f) {
    my (@where, @bind);
    if (defined $f{id} && length $f{id}) {
        return [] unless $self->is_uuid($f{id});
        push @where, 'e.id = ?';
        push @bind,  $f{id};
    }
    for my $pair (
        [procedure => 'p.code = ?'],
        [status    => 'e.status = ?'],
        [user      => 'e.requested_by = ?'],
        [from      => 'e.requested_at >= ?::timestamptz'],
        [to        => 'e.requested_at < (?::date + 1)'],
        )
    {
        my ($key, $sql) = @$pair;
        next unless defined $f{$key} && length $f{$key};
        push @where, $sql;
        push @bind,  $f{$key};
    }
    my $sql = $EXECUTION_SELECT;
    $sql .= ' where ' . join(' and ', @where) if @where;
    $sql .= ' order by e.requested_at desc limit ? offset ?';
    push @bind, $f{limit} // 25, $f{offset} // 0;
    return $self->pg->db->query($sql, @bind)->expand->hashes->to_array;
}

sub set_job_id ($self, $id, $job_id) {
    $self->pg->db->query('update executions set minion_job_id = ? where id = ?', $job_id, $id);
    return;
}

# Returns true only when the execution was still queued.
sub mark_running ($self, $id) {
    return $self->pg->db->query(
        <<'SQL', $id)->rows > 0;
update executions set status = 'running', started_at = now(), progress = 0, current_step = null
 where id = ? and status = 'queued'
SQL
}

sub update_progress ($self, $id, $progress, $step = undef) {
    $self->pg->db->query(
        <<'SQL', $progress, $step, $id);
update executions set progress = coalesce(?::integer, progress), current_step = coalesce(?, current_step)
 where id = ?
SQL
    return;
}

sub mark_finished ($self, $id, %r) {
    $self->pg->db->query(
        <<'SQL', @r{qw(status exit_code summary error_code error_message status)}, $id);
update executions set status = ?, finished_at = now(), exit_code = ?, summary = ?,
  error_code = ?, error_message = ?,
  progress = case when ?::text = 'completed' then 100 else progress end
 where id = ?
SQL
    return;
}

# Cancels a queued execution directly; flags a running one. Returns the new status or undef.
sub request_cancel ($self, $id) {
    my $db = $self->pg->db;
    my $r  = $db->query(
        <<'SQL', $id)->hash;
update executions set status = 'cancelled', finished_at = now()
 where id = ? and status = 'queued' returning status
SQL
    return $r->{status} if $r;
    $r = $db->query(
        <<'SQL', $id)->hash;
update executions set status = 'cancel_requested'
 where id = ? and status = 'running' returning status
SQL
    return $r ? $r->{status} : undef;
}

sub status ($self, $id) {
    my $r = $self->pg->db->query('select status from executions where id = ?', $id)->hash;
    return $r ? $r->{status} : undef;
}

# ---- events --------------------------------------------------------------

sub add_event ($self, $id, $level, $message, %o) {
    $self->pg->db->query(
        'insert into execution_events (execution_id, level, event_type, message, metadata) values (?, ?, ?, ?, ?)',
        $id, $level, $o{event_type} // 'log', $message, {json => $o{metadata} // {}});
    return;
}

sub list_events ($self, $id) {
    return $self->pg->db->query(
        'select id, level, event_type, message, metadata, created_at from execution_events where execution_id = ? order by id',
        $id)->expand->hashes->to_array;
}

sub latest_events ($self, $id) {
    return $self->pg->db->query(
        'select id, level, event_type, message, metadata, created_at from execution_events '
        . 'where execution_id = ? order by created_at desc, id desc limit 25',
        $id)->expand->hashes->to_array;
}

# ---- artifacts -----------------------------------------------------------

sub add_artifact ($self, $id, %a) {
    return $self->pg->db->query(
        <<'SQL', $id, @a{qw(original_name stored_name media_type size_bytes sha256 relative_path)}, $a{retention_days})->hash->{id};
insert into execution_artifacts
  (execution_id, original_name, stored_name, media_type, size_bytes, sha256, relative_path, expires_at)
values (?, ?, ?, ?, ?, ?, ?, now() + (?::integer * interval '1 day'))
returning id
SQL
}

sub list_artifacts ($self, $id) {
    return $self->pg->db->query('select * from execution_artifacts where execution_id = ? order by id', $id)
        ->hashes->to_array;
}

sub get_artifact ($self, $execution_id, $artifact_id) {
    return undef unless defined $artifact_id && $artifact_id =~ /\A\d+\z/;
    return $self->pg->db->query(
        'select * from execution_artifacts where execution_id = ? and id = ?
            and (expires_at is null or expires_at > now())', $execution_id, $artifact_id
    )->hash;
}

1;
