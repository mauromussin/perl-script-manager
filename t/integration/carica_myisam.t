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
    has failure_table => 'battute';
    has fail_track_update => 0;
    has statements => sub { [] };
    sub do ($self, $sql, @args) {
        push @{$self->statements}, [$sql, @args];
        die "Errore compensazione simulato\n"
            if $self->cleanup_failure && $sql =~ /\ADELETE FROM battute/;
        die "Errore pulizia simulato\n"
            if $self->drop_failure && $sql =~ /\ADROP TABLE/;
        my $result = $self->db->do($sql, @args);
        die "Errore dopo aggiornamento traccia\n" if $self->fail_track_update && $sql =~ /\AUPDATE flay SET/;
        my $table = $self->failure_table;
        if ($self->failure && !$self->failed && $sql =~ /\AINSERT INTO `\Q$table\E`/) {
            $self->failed(1);
            die $self->failure;
        }
        return $result;
    }
    sub selectall_arrayref ($self, @args) { return $self->db->selectall_arrayref(@args) }
    sub selectrow_hashref ($self, @args) { return $self->db->selectrow_hashref(@args) }
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
    $admin->do('CREATE TABLE battute_doppie LIKE battute');
    $admin->do('ALTER TABLE battute_doppie DROP INDEX u_battuta');
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
    is_deeply $engines, ['MyISAM', 'MyISAM', 'MyISAM'], 'nessuna conversione di motore';
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

subtest 'input incompleto non tocca i dati live' => sub {
    reset_tables();
    for my $data (record() . 'incomplete') {
        $input->child('LIML.OUT')->spew($data);
        eval { loader()->run(context(), $params) };
        ok(ScriptManager::Exception->caught($@), 'input rifiutato con errore applicativo');
        is_deeply rows('flay'), [];
        is_deeply rows('battute'), [];
        is_deeply work_tables(), [], 'staging rimosso';
    }
};

subtest 'tracce senza battute non bloccano MyISAM e non attivano da sole il merge' => sub {
    for my $valid (0, 1) {
        reset_tables();
        $admin->do(q{INSERT INTO flay (flay,data,ora,airport_dep,flay_operation)
            VALUES ('OLD0001','2026-02-01','23:05:00','LIML','D'),
                   ('OLD0001','2026-02-02','00:05:00','LIML','D')});
        $admin->do(q{INSERT INTO battute (flay_id,ora) VALUES (2,'00:05:00')});
        my ($tracks, $hits) = (rows('flay'), rows('battute'));
        my $header = substr(record(), 0, 34);
        $input->child('LIML.OUT')->spew("$header\n" . ($valid ? record() : '') . "$header\r\n");
        my $ctx = context();
        my $result = loader()->run($ctx, {%$params, merge_midnight => 1});
        ok $result->{success};
        is_deeply $result->{data}, {
            tracks => $valid, hits => $valid, duplicate_tracks => 0, duplicate_hits => 0, skipped_tracks => 2,
            repaired_tracks => 0, skipped_hits => 0,
        };
        is scalar @{rows('flay')}, 2 + $valid;
        is scalar @{rows('battute')}, 1 + $valid;
        is_deeply rows('battute_doppie'), [], 'tracce vuote non trattate come duplicati';
        unless ($valid) {
            is_deeply rows('flay'), $tracks, 'senza dati validi nessun merge di tracce preesistenti';
            is_deeply rows('battute'), $hits;
        }
        is scalar(grep { $_->{level} eq 'warning' && ($_->{operation} // '') eq 'skip_empty_track' } @{$ctx->events}), 2;
        is_deeply work_tables(), [], 'staging e journal rimossi anche senza dati validi';
    }
};

subtest 'battute identiche ripetute non bloccano ne staging principale ne doppie' => sub {
    reset_tables();
    my $line = record();
    my $header = substr($line, 0, 34);
    my $sample = substr($line, 34, 24);
    $line = $header . ($sample x 3) . "\n";
    $input->child('LIML.OUT')->spew($line . $line);
    my $ctx = context();
    my $result = loader()->run($ctx, $params);
    ok $result->{success};
    is $result->{data}{hits}, 2, 'una battuta valida per ogni record OUT';
    is $result->{data}{skipped_hits}, 4;
    is scalar @{rows('flay')}, 1;
    is scalar @{rows('battute')}, 1;
    is scalar @{rows('battute_doppie')}, 1, 'deduplica solo dentro il record, non tra occorrenze diverse';
    is scalar(grep { $_->{level} eq 'warning' && ($_->{operation} // '') eq 'skip_duplicate_hit' } @{$ctx->events}), 4;
    is_deeply work_tables(), [];
};

subtest 'duplicati nello stesso OUT e tra OUT conservano le battute separatamente' => sub {
    reset_tables();
    my $different = record();
    substr($different, 34, 6, '000128');
    $input->child('LIML.OUT')->spew(record() . $different . record('NEW0001'));
    $input->child('LIML_2.OUT')->spew(record());
    my $ctx = context();
    my $result = loader()->run($ctx, $params);
    $input->child('LIML_2.OUT')->remove;
    ok $result->{success};
    is_deeply $result->{data}, {tracks => 2, hits => 4, duplicate_tracks => 2, duplicate_hits => 2, skipped_tracks => 0, repaired_tracks => 0, skipped_hits => 0};
    is scalar @{rows('flay')}, 2, 'nessuna traccia aggiuntiva o carattere spia';
    is rows('flay')->[0][1], 'ABC1234', 'nome volo originale preservato';
    is scalar @{rows('battute')}, 2, 'solo le prime occorrenze in battute';
    is scalar @{rows('battute_doppie')}, 2, 'anche record identici conservati separatamente';
    is rows('battute_doppie')->[0][2], rows('flay')->[0][0], 'battuta diversa associata alla prima traccia';
    is rows('battute_doppie')->[1][2], rows('flay')->[0][0], 'duplicato tra file associato alla stessa traccia';
    isnt rows('battute_doppie')->[0][3], rows('battute')->[0][3], 'contenuto diverso non sovrascritto';
    my @warnings = grep { $_->{level} eq 'warning' && ($_->{operation} // '') eq 'duplicate_track' } @{$ctx->events};
    is scalar @warnings, 2;
    like $warnings[0]{message}, qr/LIML\.OUT, riga 2/, 'origine precisa nel warning';
    is_deeply work_tables(), [];
};

subtest 'duplicati live riusano ID e metadati senza modificare battute preesistenti' => sub {
    reset_tables();
    $admin->do(q{INSERT INTO flay (row_id,flay,data,ora,aircraft,validation_fl)
        VALUES (42,'ZZZ1234','2026-02-02','12:00:00','A320','Y')});
    $admin->do(q{INSERT INTO battute (flay_id,ora) VALUES (42,'12:00:00')});
    $admin->do(q{INSERT INTO battute_doppie (row_id,flay_id,ora) VALUES (300,42,'12:00:00')});
    my $before = rows('flay');
    my $hits = rows('battute');
    $input->child('LIML.OUT')->spew(record('ZZZ1234') . record('ABC1234') . record('ZZZ1234'));
    my $result = loader()->run(context(), $params);
    ok $result->{success};
    is_deeply $result->{data}, {tracks => 1, hits => 3, duplicate_tracks => 2, duplicate_hits => 2, skipped_tracks => 0, repaired_tracks => 0, skipped_hits => 0};
    is_deeply rows('flay')->[0], $before->[0], 'validazione e metadati preesistenti intatti';
    is_deeply rows('battute')->[0], $hits->[0];
    is scalar @{rows('flay')}, 2;
    is scalar @{rows('battute')}, 2;
    is scalar @{rows('battute_doppie')}, 3;
    is rows('battute_doppie')->[-1][2], 42, 'ID esistente non traslato';
    is rows('battute_doppie')->[-2][2], 42, 'anche la prima occorrenza live e deviata';
    cmp_ok rows('battute_doppie')->[-2][0], '>', 300, 'AUTO_INCREMENT doppie rispettato';
    $input->child('LIML.OUT')->spew(record('ZZZ1234'));
    $result = loader()->run(context(), $params);
    is_deeply $result->{data}, {tracks => 0, hits => 1, duplicate_tracks => 1, duplicate_hits => 1, skipped_tracks => 0, repaired_tracks => 0, skipped_hits => 0},
        'caricamento composto soltanto da tracce gia presenti';
    is_deeply work_tables(), [];
};

subtest 'tracce esistenti senza battute completano solo i campi vuoti e ricevono le battute principali' => sub {
    for my $engine (qw(MyISAM InnoDB)) {
        reset_tables();
        $admin->do("ALTER TABLE $_ ENGINE=$engine") for qw(flay battute battute_doppie);
        $admin->do(q{INSERT INTO flay (row_id,flay,data,ora,aircraft,airport_arr,validation_fl,validation_bt)
            VALUES (42,'ABC1234','2026-02-02','12:00:00','   ','LIRF','Y',1)});
        my $identical = ScriptManager::Command::CaricaDB->track(record('NEW0001'), 'LIML');
        $admin->do(q{INSERT INTO flay
            (row_id,flay,data,ora,aircraft,airport_dep,airport_arr,flay_operation,data_ora_italy,validation_fl,validation_bt)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)}, undef, 43, @$identical, 'M', 0);
        $admin->do(q{INSERT INTO flay
            (row_id,flay,data,ora,aircraft,airport_dep,airport_arr,flay_operation,data_ora_italy)
            VALUES (44,'ALT0001','2026-02-02','12:00:00','A320','EGLL','LIRF','A','2026-01-01 01:00:00'),
                   (45,'HIT0001','2026-02-02','12:00:00',NULL,NULL,NULL,NULL,NULL)});
        $admin->do(q{INSERT INTO battute (flay_id,ora) VALUES (45,'12:00:00')});
        $admin->do(q{INSERT INTO battute_doppie (row_id,flay_id,ora) VALUES (300,42,'12:00:00')});
        my $before = rows('flay');
        my $old_duplicate = rows('battute_doppie')->[0];
        $input->child('LIML.OUT')->spew(record() . record() . record('NEW0001') . record('ALT0001') . record('HIT0001'));
        my $db = connection();
        my $load = MyISAMTestLoader->new(connect_db => sub (@) { $engine eq 'MyISAM' ? $db : $db->db });
        my $result = $load->run(context(), $params);
        ok $result->{success}, "$engine: caricamento riuscito";
        is_deeply $result->{data}, {
            tracks => 0, hits => 5, duplicate_tracks => 2, duplicate_hits => 2, skipped_tracks => 0, repaired_tracks => 3, skipped_hits => 0,
        };
        like $result->{message}, qr/3 tracce preesistenti senza battute completate/;
        my $after = rows('flay');
        is scalar @$after, 4, 'nessuna nuova traccia';
        is_deeply [@{$after->[0]}[0 .. 10]],
            [42, 'ABC1234', '2026-02-02', '12:00:00', 'B738', 'LIML', 'LIRF', 'D', 'Y', 1, '2026-02-02 13:00:00'],
            'completati soltanto campi vuoti; ID, valori e flag validati preservati';
        is_deeply $after->[1], $before->[1], 'traccia identica e flag M invariati';
        is_deeply $after->[2], $before->[2], 'campi non vuoti discordanti preservati';
        is_deeply $after->[3], $before->[3], 'traccia con battute gia presenti non completata';
        is_deeply [map { $_->[2] } @{rows('battute')}], [45, 42, 43, 44],
            'prime battute collegate agli ID esistenti';
        is scalar @{rows('battute_doppie')}, 3;
        is_deeply rows('battute_doppie')->[0], $old_duplicate, 'doppie preesistenti non impediscono il completamento';
        is_deeply [sort { $a <=> $b } map { $_->[2] } @{rows('battute_doppie')}], [42, 42, 45],
            'ulteriori occorrenze e tracce con battute vanno nelle doppie';
        if ($engine eq 'MyISAM') {
            my @updates = grep { $_->[0] =~ /\AUPDATE flay SET/ } @{$db->statements};
            is scalar @updates, 1, 'nessun UPDATE se i metadati sono gia presenti';
            is $updates[0][-1], 42, 'UPDATE solo sulla traccia con campi vuoti';
        }
        is_deeply work_tables(), [];
        $input->child('LIML.OUT')->spew(record());
        $result = loader()->run(context(), $params) if $engine eq 'MyISAM';
        if ($engine eq 'MyISAM') {
            is $result->{data}{repaired_tracks}, 0, 'dopo il recupero la traccia non e piu priva di battute';
            is $result->{data}{duplicate_hits}, 1, 'riesecuzione instradata nelle doppie';
        }
    }
};

subtest 'compensazione ripristina i metadati completati anche senza merge' => sub {
    reset_tables();
    $admin->do(q{INSERT INTO flay (row_id,flay,data,ora,validation_fl,validation_bt)
        VALUES (42,'ABC1234','2026-02-02','12:00:00','M',1)});
    $admin->do(q{INSERT INTO battute_doppie (flay_id,ora) VALUES (42,'12:00:00')});
    my @before = map { rows($_) } qw(flay battute battute_doppie);
    $input->child('LIML.OUT')->spew(record() . record() . record('NEW0001'));
    for my $case (
        [connection(fail_track_update => 1), context(), 'mysql_load_failed'],
        [connection(failure => "Errore dopo battute principali\n"), context(), 'mysql_load_failed'],
        [connection(), context(cancel_at => 'complete_empty_track'), 'cancelled'],
        [connection(failure => ScriptManager::Exception->new(code => 'timed_out', message => 'Timeout test')),
            context(), 'timed_out'],
    ) {
        my $load = MyISAMTestLoader->new(connect_db => sub (@) { $case->[0] });
        eval { $load->run($case->[1], $params) };
        ok(ScriptManager::Exception->caught($@, $case->[2]), 'errore preservato');
        is_deeply rows('flay'), $before[0], 'metadati e flag preesistenti ripristinati';
        is_deeply rows('battute'), $before[1];
        is_deeply rows('battute_doppie'), $before[2];
        is_deeply work_tables(), [];
    }
};

subtest 'completamento prima del merge resta annullabile con entrambi i motori' => sub {
    for my $engine (qw(MyISAM InnoDB)) {
        reset_tables();
        $admin->do("ALTER TABLE $_ ENGINE=$engine") for qw(flay battute battute_doppie);
        $admin->do(q{INSERT INTO flay (row_id,flay,data,ora,airport_dep,flay_operation)
            VALUES (1,'ABC1234','2026-02-01','23:05:00','LIML','D'),
                   (42,'ABC1234','2026-02-02','00:05:00',NULL,NULL)});
        $admin->do(q{INSERT INTO battute (flay_id,ora) VALUES (1,'23:05:00')});
        my @before = map { rows($_) } qw(flay battute battute_doppie);
        $input->child('LIML.OUT')->spew(record('ABC1234', '20260202', '000500'));
        my $db = connection();
        my $load = MyISAMTestLoader->new(
            connect_db => sub (@) { $engine eq 'MyISAM' ? $db : $db->db }, fail_after_merge => 1);
        eval { $load->run(context(), {%$params, merge_midnight => 1}) };
        ok $@, "$engine: errore dopo merge";
        is_deeply rows('flay'), $before[0], 'ripristinati anche campi che rendevano la traccia idonea al merge';
        is_deeply rows('battute'), $before[1], 'nuove battute rimosse anche dopo spostamento';
        is_deeply rows('battute_doppie'), $before[2];
        is_deeply work_tables(), [];
        $db->disconnect if $engine eq 'InnoDB';
    }
};

subtest 'errore dopo inserimento doppie compensa tutte e tre le tabelle' => sub {
    reset_tables();
    $admin->do(q{INSERT INTO flay (flay,data,ora) VALUES ('OLD0001','2026-01-01','12:00:00')});
    $admin->do(q{INSERT INTO battute (flay_id,ora) VALUES (1,'12:00:00')});
    $admin->do(q{INSERT INTO battute_doppie (flay_id,ora) VALUES (1,'12:00:00')});
    my @before = map { rows($_) } qw(flay battute battute_doppie);
    $input->child('LIML.OUT')->spew(record() . record());
    eval { loader(failure => "Errore dopo doppie\n", failure_table => 'battute_doppie')->run(context(), $params) };
    ok(ScriptManager::Exception->caught($@, 'mysql_load_failed'));
    is_deeply rows('flay'), $before[0];
    is_deeply rows('battute'), $before[1];
    is_deeply rows('battute_doppie'), $before[2], 'nessuna battuta doppia parziale mantenuta';
    is_deeply work_tables(), [];
};

subtest 'vincolo SQL sulle doppie dopo una scrittura parziale non lascia nuovi dati' => sub {
    reset_tables();
    $admin->do(q{INSERT INTO flay (row_id,flay,data,ora) VALUES (42,'OLD0001','2026-02-02','12:00:00')});
    $admin->do(q{INSERT INTO battute (flay_id,ora) VALUES (42,'12:00:00')});
    $admin->do(q{INSERT INTO battute_doppie (flay_id,ora) VALUES (42,'12:00:00')});
    $admin->do('ALTER TABLE battute_doppie ADD UNIQUE KEY test_unique (flay_id,ora)');
    my @before = map { rows($_) } qw(flay battute battute_doppie);
    $input->child('LIML.OUT')->spew(record() . record() . record('OLD0001'));
    eval { loader()->run(context(), $params) };
    ok(ScriptManager::Exception->caught($@, 'mysql_duplicate'));
    is_deeply rows('flay'), $before[0];
    is_deeply rows('battute'), $before[1];
    is_deeply rows('battute_doppie'), $before[2], 'anche inserimenti parziali compensati';
    is_deeply work_tables(), [];
};

subtest 'InnoDB conferma o annulla anche le battute doppie nella stessa transazione' => sub {
    for my $fail (0, 1) {
        reset_tables();
        $admin->do("ALTER TABLE $_ ENGINE=InnoDB") for qw(flay battute battute_doppie);
        $admin->do(q{INSERT INTO flay (row_id,flay,data,ora) VALUES (42,'OLD0001','2026-02-02','12:00:00')});
        $admin->do(q{INSERT INTO battute (flay_id,ora) VALUES (42,'12:00:00')});
        $input->child('LIML.OUT')->spew(record() . record() . record('OLD0001'));
        my $db = connection();
        my $load = MyISAMTestLoader->new(connect_db => sub (@) { $db->db }, fail_after_merge => $fail);
        my $result = eval { $load->run(context(), {%$params, merge_midnight => 1}) };
        if ($fail) {
            like "$@", qr/Errore dopo unione/, 'errore finale preservato';
            is scalar @{rows('flay')}, 1, 'nuova traccia annullata';
            is scalar @{rows('battute')}, 1, 'battuta preesistente conservata';
            is_deeply rows('battute_doppie'), [], 'doppie annullate';
            $db->disconnect;
        } else {
            ok $result->{success};
            is_deeply $result->{data}, {tracks => 1, hits => 3, duplicate_tracks => 2, duplicate_hits => 2, skipped_tracks => 0, repaired_tracks => 0, skipped_hits => 0};
            is scalar @{rows('flay')}, 2;
            is scalar @{rows('battute')}, 2;
            is scalar @{rows('battute_doppie')}, 2;
            is rows('battute_doppie')->[0][2], rows('battute')->[-1][2], 'duplicato interno associato alla traccia nuova';
            is rows('battute_doppie')->[1][2], 42, 'duplicato live associato alla traccia esistente';
        }
    }
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
    $admin->do(q{INSERT INTO battute_doppie (flay_id,ora) VALUES (2,'00:05:00')});
    my ($tracks, $hits, $duplicates) = map { rows($_) } qw(flay battute battute_doppie);
    $input->child('LIML.OUT')->spew(record() . record());
    my $load = loader()->fail_after_merge(1);
    eval { $load->run(context(), {%$params, merge_midnight => 1}) };
    ok(ScriptManager::Exception->caught($@, 'mysql_load_failed'), 'errore dopo merge classificato');
    is_deeply rows('flay'), $tracks, 'flag preesistenti ripristinati';
    is_deeply rows('battute'), $hits, 'associazione preesistente ripristinata';
    is_deeply rows('battute_doppie'), $duplicates, 'doppie preesistenti preservate e nuove rimosse';
    is_deeply work_tables(), [];
};

subtest 'merge riuscito conserva il comportamento per tracce vecchie e nuove' => sub {
    reset_tables();
    $admin->do(q{INSERT INTO flay (flay,data,ora,airport_dep,airport_arr,flay_operation)
        VALUES ('OLD0001','2026-02-01','23:05:00','LIML','LIME','D'),
               ('OLD0001','2026-02-02','00:05:00','LIML','LIME','D'),
               ('NEW0001','2026-02-01','23:05:00','LIML','LIME','D')});
    $admin->do(q{INSERT INTO battute (flay_id,ora) VALUES (2,'00:05:00')});
    $input->child('LIML.OUT')->spew(record('NEW0001', '20260202', '000600') x 2);
    ok loader()->run(context(), {%$params, merge_midnight => 1})->{success};
    is $admin->selectrow_array('SELECT validation_fl FROM flay WHERE row_id = 2'), 'M';
    is $admin->selectrow_array('SELECT validation_fl FROM flay WHERE row_id = 4'), 'M';
    is rows('battute')->[0][2], 1, 'battuta preesistente unita alla traccia precedente';
    is rows('battute')->[1][2], 3, 'battuta nuova unita alla traccia precedente';
    is rows('battute_doppie')->[0][2], 4, 'come nel legacy le doppie restano sulla traccia individuata';
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
    $input->child('LIML.OUT')->spew(record() . record());
    my $ctx = context();
    ok loader(drop_failure => 1)->run($ctx, $params)->{success};
    $admin->do('DELETE FROM battute_doppie');
    my $work = work_tables();
    eval { loader()->run(context(), $params) };
    ok(ScriptManager::Exception->caught($@, 'mysql_recovery_required'), 'pubblicazione incompleta non scartata');
    is_deeply work_tables(), $work, 'materiale di recupero conservato';
};

subtest 'journal published precedenti senza doppie rimangono recuperabili' => sub {
    reset_tables();
    $input->child('LIML.OUT')->spew(record());
    my $ctx = context();
    ok loader(drop_failure => 1)->run($ctx, $params)->{success};
    my $session = ScriptManager::Service::MyISAMImport->new(db => $admin, ctx => $ctx);
    $admin->do('DROP TABLE ' . $session->table($_)) for qw(battute_doppie track_map);
    $admin->do('ALTER TABLE ' . $session->table('state')
        . ' DROP COLUMN battute_doppie_min, DROP COLUMN battute_doppie_max, '
        . 'DROP COLUMN flay_count, DROP COLUMN battute_count, DROP COLUMN battute_doppie_count');
    $input->child('LIML.OUT')->spew(record('NEW0001'));
    ok loader()->run(context(), $params)->{success}, 'pulizia del vecchio journal e nuovo caricamento';
    is scalar @{rows('flay')}, 2;
    is_deeply work_tables(), [];
};

subtest 'journal published con riuso tracce ammette intervalli vuoti o non contigui' => sub {
    for my $new (0, 1) {
        reset_tables();
        $admin->do(q{INSERT INTO flay (row_id,flay,data,ora) VALUES (42,'OLD0001','2026-02-02','12:00:00')});
        $input->child('LIML.OUT')->spew(record('OLD0001') . ($new ? record() : ''));
        my $ctx = context();
        ok loader(drop_failure => 1)->run($ctx, $params)->{success};
        my $session = ScriptManager::Service::MyISAMImport->new(db => $admin, ctx => $ctx);
        is $admin->selectrow_array('SELECT flay_count FROM ' . $session->table('state')), $new;
        $input->child('LIML.OUT')->spew(record('NEW0001'));
        ok loader()->run(context(), $params)->{success}, 'pubblicazione verificata usando i conteggi';
        is scalar @{rows('flay')}, 2 + $new;
        is_deeply work_tables(), [];
    }
};

subtest 'pulizia fallita dopo pubblicazione mantiene un esito corretto e riprende al prossimo import' => sub {
    reset_tables();
    $input->child('LIML.OUT')->spew(record() . record() . record('THR0001'));
    my $ctx = context();
    ok loader(drop_failure => 1)->run($ctx, $params)->{success}, 'dati pubblicati';
    ok scalar(grep { $_->{level} eq 'warning' && $_->{message} =~ /pulizia staging incompleta/ } @{$ctx->events});
    ok @{work_tables()}, 'journal published conservato';
    $input->child('LIML.OUT')->spew(record('NEW0001', '20260203'));
    ok loader()->run(context(), $params)->{success}, 'nuovo import dopo pulizia del precedente';
    is scalar @{rows('flay')}, 3;
    is_deeply work_tables(), [];
};

done_testing;
