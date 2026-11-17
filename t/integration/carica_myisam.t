use Mojo::Base -strict, -signatures;
use Test::More;
use DBI;
use File::Temp 'tempdir';
use FindBin;
use Mojo::File 'path';
use ScriptManager::Command::CaricaDB;
use ScriptManager::Service::MyISAMImport;

plan skip_all => 'TEST_MYSQL=1 necessario per creare un database MySQL isolato'
    unless ($ENV{TEST_MYSQL} // '') eq '1';

{
    package MyISAMTestContext;
    use Mojo::Base 'ScriptManager::Service::Context', -signatures;
    has events => sub { [] };
    has cancel_at => '';
    has cancelled => 0;
    has fail_final_progress => 0;
    sub log ($self, $level, $message, %meta) {
        push @{$self->events}, {level => $level, message => $message, %meta};
        $self->cancelled(1) if ($meta{operation} // '') eq $self->cancel_at && length $self->cancel_at;
        return $self;
    }
    sub progress ($self, $percentage, @args) {
        die "Errore notifica finale simulato\n" if $self->fail_final_progress && $percentage == 100;
        return $self;
    }
    sub check_cancel ($self) {
        ScriptManager::Exception->throw('cancelled', 'Annullamento test') if $self->cancelled;
    }
}
{
    package MyISAMTestDatabase;
    use Mojo::Base -base, -signatures;
    has [qw(db failure)];
    has failed => 0;
    has cleanup_failure => 0;
    has drop_failure => 0;
    has trigger_count => 0;
    sub do ($self, $sql, @args) {
        die "Errore compensazione simulato\n"
            if $self->cleanup_failure && $sql =~ /\ADELETE FROM battute/;
        die "Errore pulizia simulato\n"
            if $self->drop_failure && $sql =~ /\ADROP TABLE/;
        my $result = $self->db->do($sql, @args);
        if ($self->failure && !$self->failed && $sql =~ /\AINSERT INTO `battute`/) {
            $self->failed(1);
            die $self->failure;
        }
        return $result;
    }
    sub selectall_arrayref ($self, @args) { return $self->db->selectall_arrayref(@args) }
    sub selectrow_array ($self, @args) {
        return $self->trigger_count if $self->trigger_count && $args[0] =~ /information_schema\.TRIGGERS/;
        return $self->db->selectrow_array(@args);
    }
    sub prepare ($self, @args) { return $self->db->prepare(@args) }
    sub last_insert_id ($self, @args) { return $self->db->last_insert_id(@args) }
    sub quote_identifier ($self, @args) { return $self->db->quote_identifier(@args) }
    sub quote ($self, @args) { return $self->db->quote(@args) }
    sub disconnect ($self) { return $self->db->disconnect }
    sub begin_work ($self) { die "MyISAM non deve chiamare begin_work\n" }
    sub commit ($self) { die "MyISAM non deve chiamare commit\n" }
    sub rollback ($self) { die "MyISAM non deve chiamare rollback\n" }
}
{
    package MyISAMTestLoader;
    use Mojo::Base 'ScriptManager::Command::CaricaDB', -signatures;
    has fail_after_merge => 0;
    sub merge_midnight ($self, @args) {
        $self->SUPER::merge_midnight(@args);
        die "Errore dopo unione simulato\n" if $self->fail_after_merge;
    }
}

my $schema = sprintf 'sm_test_mysql_%d_%d', $$, int rand 1_000_000;
die "Nome database test non valido\n" unless $schema =~ /\Asm_test_mysql_\d+_\d+\z/;
my $dsn = 'DBI:MariaDB:host=' . ($ENV{MYSQL_HOST} // '') . ';port=' . ($ENV{MYSQL_PORT} // 3306);
my $admin = DBI->connect($dsn, $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD}, {RaiseError => 1, PrintError => 0});
my $created = 0;
END {
    if ($created && $admin) {
        $admin->do('DROP DATABASE ' . $admin->quote_identifier($schema));
        $admin->disconnect;
    }
}
$admin->do('CREATE DATABASE ' . $admin->quote_identifier($schema));
$created = 1;
$admin->do('USE ' . $admin->quote_identifier($schema));

my $input = path(tempdir(CLEANUP => 1));
my $root = path($FindBin::Bin, '..', '..')->realpath;
local $ENV{MRT_CONFIG_FILE} = $root->child('config', 'MRT.example.json')->to_string;
local $ENV{SCRIPT_MANAGER_OUT_ROOT} = "$input";
local $ENV{FILE_OUT_ROOT} = 'E:\FILE_OUT';
my $params = {radar => 'lin_2026', database => $schema, folder => '.', merge_midnight => 0};
my $counter = 0;

sub context (%args) {
    return MyISAMTestContext->new(execution_id => sprintf('00000000-0000-4000-8000-%012d', ++$counter), %args);
}

sub connection (%args) {
    my $db = DBI->connect($dsn . ';database=' . $schema, $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD},
        {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_local_infile => 1,
            mariadb_server_prepare => 0, mariadb_auto_reconnect => 0});
    return MyISAMTestDatabase->new(db => $db, %args);
}

sub reset_tables () {
    my $tables = $admin->selectcol_arrayref(
        'SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = ?', undef, $schema);
    $admin->do('DROP TABLE ' . $admin->quote_identifier($_)) for @$tables;
    $admin->do(q{
        CREATE TABLE flay (
          row_id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
          flay CHAR(7), data DATE, ora TIME, aircraft CHAR(4),
          airport_dep CHAR(4), airport_arr CHAR(4), flay_operation ENUM('A','D','N'),
          validation_fl ENUM('Y','N','L','D','P','M'), validation_bt TINYINT,
          data_ora_italy DATETIME,
          UNIQUE KEY u_flay (flay, data, ora)
        ) ENGINE=MyISAM
    });
    $admin->do(q{
        CREATE TABLE battute (
          row_id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
          ora TIME, flay_id INT UNSIGNED, X_m DOUBLE(11,2), Y_m DOUBLE(11,2),
          Z_m DOUBLE(11,2), H_m DOUBLE(11,2), A_m DOUBLE(11,2), path DOUBLE(11,2),
          vel DOUBLE(11,2), hmod ENUM('M'), validation ENUM('Y','N','A','S','T','D','L','P','X'),
          time_italy DATETIME,
          UNIQUE KEY u_battuta (flay_id, ora, X_m, Y_m, H_m), KEY k_flay (flay_id)
        ) ENGINE=MyISAM
    });
}

sub record ($flight = 'ABC1234', $date = '20260202', $time = '120000') {
    return $date . $time . $flight . ' B738LIMLLIME'
        . sprintf('%06d%06d%06d%s', 64, -64, 100, $time) . "\n";
}

sub rows ($table) {
    return $admin->selectall_arrayref('SELECT * FROM ' . $admin->quote_identifier($table) . ' ORDER BY row_id');
}

sub work_tables () {
    return $admin->selectcol_arrayref(
        'SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME LIKE ?',
        undef, $schema, '_sm_import_%');
}

sub loader (%args) {
    my $db = connection(%args);
    return MyISAMTestLoader->new(connect_db => sub (@) { $db });
}

subtest 'pubblicazione MyISAM senza transazioni e con ID rimappati' => sub {
    reset_tables();
    $admin->do(q{INSERT INTO flay (flay,data,ora) VALUES ('OLD0001','2026-01-01','12:00:00')});
    $admin->do(q{INSERT INTO battute (flay_id,ora) VALUES (1,'12:00:00')});
    $input->child('LIML.OUT')->spew(record());
    my $result = loader()->run(context(), $params);
    ok $result->{success};
    is scalar @{rows('flay')}, 2;
    is scalar @{rows('battute')}, 2;
    is rows('battute')->[-1][2], rows('flay')->[-1][0], 'ID locale rimappato all ID live';
    is_deeply work_tables(), [], 'journal e staging puliti';
    my $engines = $admin->selectcol_arrayref(
        'SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = ?', undef, $schema);
    is_deeply $engines, ['MyISAM', 'MyISAM'], 'nessuna conversione di motore';
};

subtest 'errore dopo pubblicazione non dichiara una compensazione inesistente' => sub {
    reset_tables();
    $input->child('LIML.OUT')->spew(record());
    eval { loader()->run(context(fail_final_progress => 1), $params) };
    ok(ScriptManager::Exception->caught($@, 'mysql_already_published'), 'dati gia pubblicati esplicitati');
    is scalar @{rows('flay')}, 1;
    is scalar @{rows('battute')}, 1;
    is_deeply work_tables(), [];
};

subtest 'contatori AUTO_INCREMENT preesistenti non vengono riutilizzati' => sub {
    reset_tables();
    $admin->do('ALTER TABLE flay AUTO_INCREMENT = 100');
    $admin->do('ALTER TABLE battute AUTO_INCREMENT = 200');
    $input->child('LIML.OUT')->spew(record());
    ok loader()->run(context(), $params)->{success};
    is rows('flay')->[0][0], 100;
    is rows('battute')->[0][0], 200;
    is rows('battute')->[0][2], 100;
};

subtest 'input incompleto e duplicati nello staging non toccano i dati live' => sub {
    reset_tables();
    for my $data (record() . 'incomplete', record() . record()) {
        $input->child('LIML.OUT')->spew($data);
        eval { loader()->run(context(), $params) };
        ok(ScriptManager::Exception->caught($@), 'input rifiutato con errore applicativo');
        is_deeply rows('flay'), [];
        is_deeply rows('battute'), [];
        is_deeply work_tables(), [], 'staging rimosso';
    }
};

subtest 'duplicato live dopo un inserimento parziale viene compensato' => sub {
    reset_tables();
    $admin->do(q{INSERT INTO flay (flay,data,ora) VALUES ('ZZZ1234','2026-02-02','12:00:00')});
    my $before = rows('flay');
    $input->child('LIML.OUT')->spew(record('ABC1234') . record('ZZZ1234'));
    eval { loader()->run(context(), $params) };
    ok(ScriptManager::Exception->caught($@, 'mysql_duplicate'), 'duplicato live classificato');
    is_deeply rows('flay'), $before, 'inserimento parziale eliminato senza cancellare la traccia preesistente';
    is_deeply rows('battute'), [];
    is_deeply work_tables(), [];
};

subtest 'errore dopo LOAD live, annullamento e timeout eliminano soltanto le nuove righe' => sub {
    reset_tables();
    $admin->do(q{INSERT INTO flay (flay,data,ora) VALUES ('OLD0001','2026-01-01','12:00:00')});
    $admin->do(q{INSERT INTO battute (flay_id,ora) VALUES (1,'12:00:00')});
    my ($tracks, $hits) = (rows('flay'), rows('battute'));
    $input->child('LIML.OUT')->spew(record());
    for my $case (
        [context(), loader(failure => "Errore pubblicazione simulato\n"), undef],
        [context(cancel_at => 'myisam_publish_tracks'), loader(), 'cancelled'],
        [context(), loader(failure => ScriptManager::Exception->new(code => 'timed_out', message => 'Timeout test')), 'timed_out']
    ) {
        eval { $case->[1]->run($case->[0], $params) };
        my $error = $@;
        ok $error;
        ok(ScriptManager::Exception->caught($error, $case->[2]), 'tipo errore preservato') if $case->[2];
        is_deeply rows('flay'), $tracks;
        is_deeply rows('battute'), $hits;
        is_deeply work_tables(), [];
    }
};

subtest 'errore dopo merge ripristina anche dati preesistenti modificati' => sub {
    reset_tables();
    $admin->do(q{INSERT INTO flay (flay,data,ora,airport_dep,airport_arr,flay_operation)
        VALUES ('OLD0001','2026-02-01','23:05:00','LIML','LIME','D'),
               ('OLD0001','2026-02-02','00:05:00','LIML','LIME','D')});
    $admin->do(q{INSERT INTO battute (flay_id,ora) VALUES (2,'00:05:00')});
    my ($tracks, $hits) = (rows('flay'), rows('battute'));
    $input->child('LIML.OUT')->spew(record());
    my $load = loader()->fail_after_merge(1);
    eval { $load->run(context(), {%$params, merge_midnight => 1}) };
    ok(ScriptManager::Exception->caught($@, 'mysql_load_failed'), 'errore dopo merge classificato');
    is_deeply rows('flay'), $tracks, 'flag preesistenti ripristinati';
    is_deeply rows('battute'), $hits, 'associazione preesistente ripristinata';
    is_deeply work_tables(), [];
};

subtest 'merge riuscito conserva il comportamento per tracce vecchie e nuove' => sub {
    reset_tables();
    $admin->do(q{INSERT INTO flay (flay,data,ora,airport_dep,airport_arr,flay_operation)
        VALUES ('OLD0001','2026-02-01','23:05:00','LIML','LIME','D'),
               ('OLD0001','2026-02-02','00:05:00','LIML','LIME','D'),
               ('NEW0001','2026-02-01','23:05:00','LIML','LIME','D')});
    $admin->do(q{INSERT INTO battute (flay_id,ora) VALUES (2,'00:05:00')});
    $input->child('LIML.OUT')->spew(record('NEW0001', '20260202', '000600'));
    ok loader()->run(context(), {%$params, merge_midnight => 1})->{success};
    is $admin->selectrow_array('SELECT validation_fl FROM flay WHERE row_id = 2'), 'M';
    is $admin->selectrow_array('SELECT validation_fl FROM flay WHERE row_id = 4'), 'M';
    is rows('battute')->[0][2], 1, 'battuta preesistente unita alla traccia precedente';
    is rows('battute')->[1][2], 3, 'battuta nuova unita alla traccia precedente';
    is_deeply work_tables(), [];
};

subtest 'compensazione fallita conserva il journal e blocca nuovi caricamenti' => sub {
    reset_tables();
    $input->child('LIML.OUT')->spew(record());
    my $ctx = context();
    eval { loader(failure => "Errore pubblicazione\n", cleanup_failure => 1)->run($ctx, $params) };
    ok(ScriptManager::Exception->caught($@, 'mysql_recovery_required'));
    ok scalar(grep { $_->{level} eq 'critical' } @{$ctx->events});
    my $journal = ScriptManager::Service::MyISAMImport->new(ctx => $ctx)->names->{state};
    is $admin->selectrow_array('SELECT phase FROM ' . $admin->quote_identifier($journal)), 'recovery_required';
    my ($tracks, $hits, $work) = (rows('flay'), rows('battute'), work_tables());
    eval { loader()->run(context(), $params) };
    ok(ScriptManager::Exception->caught($@, 'mysql_recovery_required'), 'retry bloccato');
    is_deeply rows('flay'), $tracks, 'retry non cancella dati ambigui';
    is_deeply rows('battute'), $hits;
    is_deeply work_tables(), $work, 'journal e backup conservati';

    # In questo schema isolato sappiamo che non esistono scrittori esterni.
    $admin->do('DELETE FROM battute');
    $admin->do('DELETE FROM flay');
    $admin->do('UPDATE ' . $admin->quote_identifier($journal) . ' SET phase = ?', undef, 'recovered');
    ok loader()->run(context(), $params)->{success}, 'ripartenza dopo recupero verificato';
    is scalar @{rows('flay')}, 1;
    is scalar @{rows('battute')}, 1;
    is_deeply work_tables(), [];
};

subtest 'journal publishing dopo disconnessione non viene cancellato nemmeno con lo stesso ID' => sub {
    reset_tables();
    my $ctx = context();
    my $db = connection();
    my $session = ScriptManager::Service::MyISAMImport->new(db => $db, ctx => $ctx)->prepare;
    $session->_phase('publishing');
    $db->disconnect;
    my $work = work_tables();
    $input->child('LIML.OUT')->spew(record());
    eval { loader()->run($ctx, $params) };
    ok(ScriptManager::Exception->caught($@, 'mysql_recovery_required'));
    is_deeply work_tables(), $work, 'journal dello stesso ID preservato';
    is_deeply rows('flay'), [];
};

subtest 'lock del database impedisce due importatori concorrenti' => sub {
    reset_tables();
    my $db = connection();
    my $session = ScriptManager::Service::MyISAMImport->new(db => $db, ctx => context())->prepare;
    $input->child('LIML.OUT')->spew(record());
    eval { loader()->run(context(), $params) };
    ok(ScriptManager::Exception->caught($@, 'mysql_import_busy'));
    $session->abort;
    $db->disconnect;
    is_deeply work_tables(), [];
};

subtest 'lock di pubblicazione blocca anche uno scrittore esterno' => sub {
    reset_tables();
    my $db = connection();
    my $session = ScriptManager::Service::MyISAMImport->new(db => $db, ctx => context())->prepare;
    $db->do('INSERT INTO ' . $session->table('flay') . ' (flay,data,ora) VALUES (?, ?, ?)',
        undef, 'ABC1234', '2026-02-02', '12:00:00');
    $db->do('INSERT INTO ' . $session->table('battute') . ' (ora,flay_id) VALUES (?, ?)', undef, '12:00:00', 1);
    $admin->do('SET SESSION lock_wait_timeout = 1');
    $session->publish({LIML => 'Linate'}, sub {
        my $written = eval {
            $admin->do(q{INSERT INTO flay (flay,data,ora) VALUES ('EXT0001','2026-02-03','12:00:00')});
            1;
        };
        ok !$written, 'scrittura esterna non eseguita durante la pubblicazione';
        is $admin->err, 1205, 'attesa lock scaduta sul client esterno';
    });
    $db->disconnect;
    is scalar @{rows('flay')}, 1, 'nessuna traccia esterna inserita';
    is_deeply work_tables(), [];
};

subtest 'guardia trigger simulata e cambiamenti reali di schema impediscono la pubblicazione' => sub {
    reset_tables();
    $input->child('LIML.OUT')->spew(record());
    eval { loader(trigger_count => 1)->run(context(), $params) };
    ok(ScriptManager::Exception->caught($@, 'mysql_schema'), 'trigger rifiutato');
    is_deeply rows('flay'), [];

    my $ctx = context();
    my $db = connection();
    my $session = ScriptManager::Service::MyISAMImport->new(db => $db, ctx => $ctx)->prepare;
    $admin->do('ALTER TABLE flay ADD COLUMN changed_during_import INT');
    eval { $session->publish({LIML => 'Linate'}) };
    ok(ScriptManager::Exception->caught($@, 'mysql_schema'), 'schema cambiato rifiutato prima di scrivere');
    $session->abort;
    $db->disconnect;
    is_deeply rows('flay'), [];
    is_deeply work_tables(), [];
};

subtest 'journal published senza tutte le righe live richiede verifica manuale' => sub {
    reset_tables();
    $input->child('LIML.OUT')->spew(record());
    my $ctx = context();
    ok loader(drop_failure => 1)->run($ctx, $params)->{success};
    $admin->do('DELETE FROM battute');
    my $work = work_tables();
    eval { loader()->run(context(), $params) };
    ok(ScriptManager::Exception->caught($@, 'mysql_recovery_required'), 'pubblicazione incompleta non scartata');
    is_deeply work_tables(), $work, 'materiale di recupero conservato';
};

subtest 'pulizia fallita dopo pubblicazione mantiene un esito corretto e riprende al prossimo import' => sub {
    reset_tables();
    $input->child('LIML.OUT')->spew(record());
    my $ctx = context();
    ok loader(drop_failure => 1)->run($ctx, $params)->{success}, 'dati pubblicati';
    ok scalar(grep { $_->{level} eq 'warning' && $_->{message} =~ /pulizia staging incompleta/ } @{$ctx->events});
    ok @{work_tables()}, 'journal published conservato';
    $input->child('LIML.OUT')->spew(record('NEW0001', '20260203'));
    ok loader()->run(context(), $params)->{success}, 'nuovo import dopo pulizia del precedente';
    is scalar @{rows('flay')}, 2;
    is_deeply work_tables(), [];
};

done_testing;
