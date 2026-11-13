use Mojo::Base -strict, -signatures;
use Test::More;
use File::Temp qw(tempdir);
use Mojo::File 'path';
use FindBin;
use ScriptManager::Command::CaricaDB;
use ScriptManager::Service::ProcedureRegistry;

{
    package LoaderContext;
    use Mojo::Base 'ScriptManager::Service::Context', -signatures;
    has events => sub { [] };
    has percentages => sub { [] };
    sub check_cancel ($self) { }
    sub log ($self, @event) { push @{$self->events}, \@event }
    sub progress ($self, $percentage, @rest) { push @{$self->percentages}, $percentage }
}
{
    package LoaderStatement;
    use Mojo::Base -base, -signatures;
    has [qw(db sql)];
    sub execute ($self, @values) {
        push @{$self->db->queries}, [$self->sql, \@values];
        if ($self->sql =~ /^INSERT/) {
            die "Duplicate entry (1062)\n" if $self->db->duplicate;
            $self->db->insert_id($self->db->insert_id + 1);
        }
        return 1;
    }
    sub fetchrow_arrayref ($self) { return undef }
    sub fetchall_arrayref ($self) { return [] }
}
{
    package LoaderDatabase;
    use Mojo::Base -base, -signatures;
    has queries => sub { [] };
    has warnings => sub { [] };
    has insert_id => 0;
    has duplicate => 0;
    has committed => 0;
    has rolled_back => 0;
    has rollback_fails => 0;
    has csv => '';
    sub selectall_arrayref ($self, $sql, @values) {
        push @{$self->queries}, [$sql, \@values];
        return [['flay', 'InnoDB'], ['battute', 'InnoDB']] if $sql =~ /information_schema/;
        return $self->warnings if $sql eq 'SHOW WARNINGS';
        die "Unexpected query $sql";
    }
    sub selectrow_array ($self, $sql) { return 1 }
    sub begin_work ($self) { return 1 }
    sub prepare ($self, $sql) { return LoaderStatement->new(db => $self, sql => $sql) }
    sub last_insert_id ($self, @values) { return $self->insert_id }
    sub do ($self, $sql, $attrs, $file) {
        push @{$self->queries}, [$sql, [$file]];
        $self->csv(Mojo::File::path($file)->slurp);
        return 1;
    }
    sub commit ($self) { $self->committed(1) }
    sub rollback ($self) {
        die "Rollback unavailable\n" if $self->rollback_fails;
        $self->rolled_back(1);
    }
    sub disconnect ($self) { return 1 }
}

my $root = path($FindBin::Bin, '..', '..')->realpath;
my $work = path(tempdir(CLEANUP => 1));
my $input = $work->child('OUT')->make_path;
local $ENV{MRT_CONFIG_FILE} = $root->child('config', 'MRT.example.json')->to_string;
local $ENV{SCRIPT_MANAGER_OUT_ROOT} = "$input";
local $ENV{MYSQL_HOST} = 'mysql.example.invalid';
local $ENV{MYSQL_PORT} = 3306;
local $ENV{MYSQL_USER} = 'test';
local $ENV{MYSQL_PASSWORD} = 'test-not-a-secret';
local $ENV{FILE_OUT_ROOT} = 'E:\FILE_OUT';
my $config = ScriptManager::Command::CaricaDB->mrt($ENV{MRT_CONFIG_FILE});
my $header = '20260202120000ABC1234 B738LIMLLIME';
my $hit = sprintf '%06d%06d%06d%s', 64, -64, 100, '120000';
$input->child('LIML_20260202.OUT')->spew("$header$hit\n");
my $params = {radar => 'lin_2026', folder => '.', database => 'radar_test', merge_midnight => 0};

subtest 'schema esterno e scelte MRT' => sub {
    my $registry = ScriptManager::Service::ProcedureRegistry->new(file => $root->child('config', 'procedures.yml'))->load;
    my $proc = $registry->get('carica_db');
    ok $proc, 'loader presente nel catalogo';
    is $proc->{parameter_schema}{properties}{radar}{'x-widget'}, 'radio', 'radar mutuamente esclusivi';
    my ($data, $errors) = $registry->validator($proc)->validate($params);
    is_deeply $errors, [], 'scelta radar e database accettata';
    (undef, $errors) = $registry->validator($proc)->validate({%$params, radar => 'unknown'});
    ok @$errors, 'radar non configurato rifiutato';
};

subtest 'input sicuro e ICAO dal nome' => sub {
    my $files = ScriptManager::Command::CaricaDB->input_files("$input", '.', $config->{airports});
    is $files->[0]{icao}, 'LIML', 'aeroporto ricavato dal nome';
    eval { ScriptManager::Command::CaricaDB->input_files("$input", '..', $config->{airports}) };
    ok(ScriptManager::Exception->caught($@, 'invalid_out_folder'), 'errore cartella classificato');
    like "$@", qr/relativo/, 'traversal rifiutato';
    $input->child('LIML_LIME.OUT')->spew("$header$hit\n");
    eval { ScriptManager::Command::CaricaDB->input_files("$input", '.', $config->{airports}) };
    ok(ScriptManager::Exception->caught($@, 'invalid_out_filename'), 'errore nome classificato');
    like "$@", qr/univoco/, 'aeroporto ambiguo rifiutato';
    $input->child('LIML_LIME.OUT')->remove;
    $input->child('unknown.OUT')->spew("$header$hit\n");
    eval { ScriptManager::Command::CaricaDB->input_files("$input", '.', $config->{airports}) };
    like "$@", qr/univoco/, 'aeroporto assente rifiutato';
    $input->child('unknown.OUT')->remove;
};

subtest 'cartelle OUT vuote o non disponibili' => sub {
    my $empty = $work->child('empty')->make_path;
    $empty->child('nested')->make_path->child('LIML.OUT')->spew("$header$hit\n");
    $empty->child('notes.txt')->spew('non e un file OUT');
    eval { ScriptManager::Command::CaricaDB->input_files("$empty", '.', $config->{airports}) };
    ok(ScriptManager::Exception->caught($@, 'out_files_missing'), 'assenza OUT classificata');
    like "$@", qr/Nessun file \.OUT/, 'causa comprensibile';
    like "$@", qr/FILE_OUT_ROOT/, 'indica la configurazione da verificare';
    like "$@", qr/non nelle sue sottocartelle/, 'ricerca non ricorsiva esplicita';
    unlike "$@", qr/\Q$work\E/, 'percorso interno non esposto';

    for my $location (["$empty", 'missing'], [$work->child('missing')->to_string, '.']) {
        eval { ScriptManager::Command::CaricaDB->input_files(@$location, $config->{airports}) };
        ok(ScriptManager::Exception->caught($@, 'out_folder_unavailable'), 'cartella mancante classificata');
        unlike "$@", qr/\Q$work\E/, 'percorso interno non esposto';
    }
};

subtest 'importazione e opzione mezzanotte' => sub {
    for my $merge (0, 1) {
        my $db = LoaderDatabase->new;
        my $ctx = LoaderContext->new;
        my $loader = ScriptManager::Command::CaricaDB->new(connect_db => sub (@args) {
            like $args[0], qr/database=radar_test;host=mysql\.example\.invalid/, 'database selezionato e host da ambiente';
            ok $args[3]{mariadb_local_infile}, 'LOCAL INFILE abilitato nel driver';
            return $db;
        });
        my $result = $loader->run($ctx, {%$params, merge_midnight => $merge});
        ok $result->{success}, 'caricamento completato';
        ok $db->committed, 'transazione confermata';
        my @fields = split /,/, $db->csv;
        is scalar(@fields), 13, 'formato battute legacy a 13 campi';
        is $fields[2], 1, 'battuta associata alla nuova traccia';
        is scalar(grep { $_->[0] =~ /^SELECT row_id/ } @{$db->queries}), $merge,
            'checkbox governa unione a mezzanotte';
        is $ctx->percentages->[-1], 100, 'avanzamento finale';
        my $messages = join "\n", map { $_->[1] } @{$ctx->events};
        like $messages, qr/Cartella OUT sull'host: E:\\FILE_OUT/, 'radice Windows completa nei log';
        like $messages, qr/\Q$input\E/, 'percorso completo nel container nei log';
        like $messages, qr/Connessione MySQL riuscita/, 'connessione registrata';
        like $messages, qr/Transazione MySQL confermata/, 'commit registrato';
        unlike $messages, qr/test-not-a-secret/, 'password non registrata';
        unlike $messages, qr/Conversione e scrittura battuta/, 'dettaglio disabilitato di default';
    }
};

subtest 'sottocartella e dettaglio delle operazioni' => sub {
    my $nested = $input->child('2026', 'novembre')->make_path;
    $nested->child('LIML.OUT')->spew("$header$hit\n");
    my $db = LoaderDatabase->new;
    my $ctx = LoaderContext->new(debug_operations => 1);
    my $loader = ScriptManager::Command::CaricaDB->new(connect_db => sub (@args) { $db });
    ok $loader->run($ctx, {%$params, folder => '2026/novembre'})->{success}, 'caricamento da sottocartella';
    my $messages = join "\n", map { $_->[1] } @{$ctx->events};
    like $messages, qr/Cartella OUT sull'host: E:\\FILE_OUT\\2026\\novembre/, 'path host completo della sottocartella';
    like $messages, qr/\Q$nested\E/, 'path container completo della sottocartella';
    like $messages, qr/Validazione e inserimento traccia/, 'operazione traccia registrata';
    like $messages, qr/Conversione e scrittura battuta/, 'operazione battuta registrata';
    ok $db->committed, 'logging non altera il caricamento';
};

subtest 'rollback fallito produce un evento CRITICAL' => sub {
    my $db = LoaderDatabase->new(duplicate => 1, rollback_fails => 1);
    my $ctx = LoaderContext->new;
    my $loader = ScriptManager::Command::CaricaDB->new(connect_db => sub (@args) { $db });
    eval { $loader->run($ctx, $params) };
    like "$@", qr/Duplicate/, 'errore originale preservato';
    ok scalar(grep { $_->[0] eq 'critical' && $_->[1] =~ /Rollback MySQL fallito/ } @{$ctx->events}),
        'fallimento del rollback evidenziato';
    ok !$db->committed, 'nessun commit';
};

subtest 'duplicati e warning annullano il caricamento' => sub {
    for my $db (LoaderDatabase->new(duplicate => 1),
                LoaderDatabase->new(warnings => [['Warning', 1062, 'Duplicate entry']])) {
        my $loader = ScriptManager::Command::CaricaDB->new(connect_db => sub (@args) { $db });
        eval { $loader->run(LoaderContext->new, $params) };
        like "$@", qr/Duplicate|duplicati/, 'duplicato segnalato';
        ok $db->rolled_back, 'rollback eseguito';
        ok !$db->committed, 'nessun commit';
    }
    $input->child('LIML_20260202.OUT')->spew("$header$hit$hit\n");
    my $db = LoaderDatabase->new;
    my $loader = ScriptManager::Command::CaricaDB->new(connect_db => sub (@args) { $db });
    eval { $loader->run(LoaderContext->new, $params) };
    like "$@", qr/Battuta duplicata/, 'battute ripetute rifiutate anche senza vincolo SQL';
    ok $db->rolled_back, 'rollback della traccia con battute ripetute';
};

done_testing;
