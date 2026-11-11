-- 1 up
create table procedures (
  id              serial primary key,
  code            text not null unique,
  name            text not null,
  description     text not null default '',
  enabled         boolean not null default true,
  handler_class   text not null,
  execution_mode  text not null check (execution_mode in ('sync', 'async')),
  timeout_seconds integer not null check (timeout_seconds > 0),
  parameter_schema jsonb not null default '{}',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table executions (
  id            uuid primary key default gen_random_uuid(),
  procedure_id  integer not null references procedures (id),
  minion_job_id bigint,
  requested_by  text not null,
  status        text not null default 'queued' check (status in
    ('queued', 'running', 'completed', 'failed', 'cancel_requested', 'cancelled', 'timed_out')),
  parameters    jsonb not null default '{}',
  progress      integer check (progress between 0 and 100),
  current_step  text,
  requested_at  timestamptz not null default now(),
  started_at    timestamptz,
  finished_at   timestamptz,
  exit_code     integer,
  summary       text,
  error_code    text,
  error_message text
);
create index executions_procedure_idx on executions (procedure_id);
create index executions_status_idx on executions (status);
create index executions_requested_at_idx on executions (requested_at desc);

create table execution_events (
  id           bigserial primary key,
  execution_id uuid not null references executions (id) on delete cascade,
  level        text not null check (level in ('info', 'warning', 'error', 'debug')),
  event_type   text not null default 'log',
  message      text not null,
  metadata     jsonb not null default '{}',
  created_at   timestamptz not null default now()
);
create index execution_events_execution_idx on execution_events (execution_id, id);

create table execution_artifacts (
  id            bigserial primary key,
  execution_id  uuid not null references executions (id) on delete cascade,
  original_name text not null,
  stored_name   text not null,
  media_type    text not null,
  size_bytes    bigint not null,
  sha256        text not null,
  relative_path text not null,
  created_at    timestamptz not null default now(),
  expires_at    timestamptz
);
create index execution_artifacts_execution_idx on execution_artifacts (execution_id);

-- 1 down
drop table if exists execution_artifacts;
drop table if exists execution_events;
drop table if exists executions;
drop table if exists procedures;
