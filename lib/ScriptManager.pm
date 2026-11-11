package ScriptManager;
use Mojo::Base 'Mojolicious', -signatures;

use Log::Any::Adapter;
use Mojo::File 'path';
use Mojo::Pg;
use Mojo::Pg::Migrations;
use ScriptManager::Repository::Executions;
use ScriptManager::Service::ExecutionService;
use ScriptManager::Service::ProcedureRegistry;
use ScriptManager::Service::ProcessRunner;
use YAML::PP;

our $VERSION = '0.1.0';

my $MIGRATION_LOCK = 872340;

my %DEFAULTS = (
    log_level => 'info',
    paths     => {
        input_dir       => 'var/input',
        output_dir      => 'var/output',
        log_dir         => 'var/logs',
        procedures_file => 'config/procedures.yml',
    },
    database                 => {url => undef, schema => undef},
    secret                   => undef,
    retention_days           => 30,
    page_size                => 25,
    max_process_output_bytes => 1_048_576,
    # name => absolute path of programs ProcessRunner may execute
    process_commands => {},
);

sub startup ($self) {
    my $config = $self->_load_config;
    $self->config($config);

    die "SCRIPT_MANAGER_SECRET non impostata\n" if $self->mode eq 'production' && !$config->{secret};
    $self->secrets([$config->{secret} // 'dev-only-insecure-secret']);
    $self->max_request_size(1_048_576);
    $self->log->level($config->{log_level} eq 'debug' ? 'debug' : 'info');
    Log::Any::Adapter->set('Stderr', log_level => $config->{log_level});

    my $url = $config->{database}{url} // die "DATABASE_URL non impostata\n";
    my $pg  = Mojo::Pg->new($url);
    $pg->search_path([$config->{database}{schema}]) if $config->{database}{schema};

    $self->plugin(Minion => {Pg => $pg});

    my $output_root = $self->_dir($config->{paths}{output_dir})->make_path;
    my $registry    = ScriptManager::Service::ProcedureRegistry->new(file => $self->_dir($config->{paths}{procedures_file}))->load;
    my $repo        = ScriptManager::Repository::Executions->new(pg => $pg);

    $self->_migrate($url, $pg, $repo, $registry);

    my $service = ScriptManager::Service::ExecutionService->new(
        repo           => $repo,
        registry       => $registry,
        minion         => $self->minion,
        output_root    => $output_root,
        retention_days => $config->{retention_days},
        process_runner => ScriptManager::Service::ProcessRunner->new(
            allowed          => $config->{process_commands},
            max_output_bytes => $config->{max_process_output_bytes},
        ),
    )->register_tasks;

    $self->helper(pg                => sub ($c) { $pg });
    $self->helper(repo              => sub ($c) { $repo });
    $self->helper(registry          => sub ($c) { $registry });
    $self->helper(execution_service => sub ($c) { $service });
    $self->helper(output_root       => sub ($c) { $output_root });
    # Authentication is not defined yet (see docs, section 20).
    $self->helper(current_user => sub ($c) { 'anonymous' });
    $self->helper(is_final     => sub ($c, $status) { scalar grep { $_ eq $status } qw(completed failed cancelled timed_out) });

    $self->hook(after_dispatch => sub ($c) {
        my $h = $c->res->headers;
        $h->header('X-Content-Type-Options' => 'nosniff');
        $h->header('X-Frame-Options'        => 'DENY');
        $h->header('Referrer-Policy'        => 'same-origin');
        $h->header('Content-Security-Policy' => "default-src 'self'; frame-ancestors 'none'")
            unless $h->header('Content-Security-Policy');
    });

    $self->_routes;
    return;
}

sub _routes ($self) {
    my $r = $self->routes->namespaces(['ScriptManager::Controller']);

    $r->get('/healthz')->to('catalog#health');
    $r->get('/')->to('catalog#index')->name('catalog');
    $r->get('/procedures/<code>')->to('catalog#show')->name('procedure');
    $r->post('/procedures/<code>/run')->to('executions#create')->name('procedure_run');
    $r->get('/executions')->to('executions#index')->name('executions');
    $r->get('/executions/<id>')->to('executions#show')->name('execution');
    $r->post('/executions/<id>/cancel')->to('executions#cancel')->name('execution_cancel');
    $r->get('/executions/<id>/artifacts/<artifact_id>')->to('executions#download')->name('artifact');

    $r->get('/api/procedures')->to('api#procedures');
    $r->post('/api/procedures/<code>/executions')->to('api#create');
    $r->get('/api/executions/<id>')->to('api#status');
    return;
}

# Precedence: defaults < config/application.yml < environment < config passed to the constructor.
sub _load_config ($self) {
    my %config = %{_merge({}, \%DEFAULTS)};
    my $file   = $self->home->child('config', 'application.yml');
    %config = %{_merge(\%config, YAML::PP->new->load_file("$file") // {})} if -f $file;

    my %env;
    $env{database} = {url => $ENV{DATABASE_URL}} if $ENV{DATABASE_URL};
    $env{secret}   = $ENV{SCRIPT_MANAGER_SECRET} if $ENV{SCRIPT_MANAGER_SECRET};
    %config = %{_merge(\%config, \%env)};

    return _merge(\%config, $self->config);
}

sub _merge ($base, $over) {
    my %out = %$base;
    for my $key (keys %$over) {
        $out{$key}
            = ref $over->{$key} eq 'HASH' && ref $out{$key} eq 'HASH'
            ? _merge($out{$key}, $over->{$key})
            : $over->{$key};
    }
    return \%out;
}

sub _dir ($self, $p) {
    my $path = path($p);
    return $path->is_abs ? $path : $self->home->child(split m{/}, $p);
}

# Serialized across processes: app and worker start together.
sub _migrate ($self, $url, $pg, $repo, $registry) {
    my $lock = Mojo::Pg->new($url)->db;
    $lock->query('select pg_advisory_lock(?)', $MIGRATION_LOCK);
    eval {
        $self->minion->backend->pg->db->query('select 1');    # runs Minion migrations
        Mojo::Pg::Migrations->new(pg => $pg)->name('script_manager')
            ->from_file($self->home->child('migrations', 'script_manager.sql')->to_string)->migrate;
        $repo->sync_procedures($registry->all);
        1;
    } or do {
        my $err = $@;
        $lock->query('select pg_advisory_unlock(?)', $MIGRATION_LOCK);
        die $err;
    };
    $lock->query('select pg_advisory_unlock(?)', $MIGRATION_LOCK);
    return;
}

1;
