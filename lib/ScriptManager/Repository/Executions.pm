package ScriptManager::Repository::Executions;
use Mojo::Base -base, -signatures;

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

sub create_execution ($self, %args) {
    return $self->pg->db->query(
        <<'SQL', $args{requested_by}, {json => $args{parameters} // {}}, $args{procedure_code}
insert into executions (procedure_id, requested_by, parameters)
select id, ?::text, ?::jsonb from procedures where code = ?
returning id
SQL
    )->hash->{id};
}

sub get_execution ($self, $id) {
    return undef unless $self->is_uuid($id);
    return $self->pg->db->query("$EXECUTION_SELECT where e.id = ?", $id)->expand->hash;
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
update executions set status = 'running', started_at = now(), progress = 0
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
