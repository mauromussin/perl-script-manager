use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use Mojo::File 'path';
use ScriptManager::Command::ValidaTracce;
use ScriptManager::Service::ProcedureRegistry;

{
    package TestContext;
    use Mojo::Base 'ScriptManager::Service::Context', -signatures;
    has events => sub { [] };
    has percentages => sub { [] };
    sub check_cancel ($self) { }
    sub log ($self, @event) { push @{$self->events}, \@event }
    sub progress ($self, $percentage, @rest) { push @{$self->percentages}, $percentage }
}

{
    package TestDatabase;
    use Mojo::Base -base, -signatures;
    has queries => sub { [] };
    has tracks => sub { {} };
    has airport_coords => sub { {LIME => [1521961.05, 5034234.14, 123], LIPO => [1555262.5, 5057915.15, 456]} };
    
    sub selectcol_arrayref ($self, $sql, @rest) {
        push @{$self->queries}, [$sql, \@rest];
        if ($sql =~ /FROM flay WHERE validation_fl IS NULL/) {
            return [sort keys %{$self->tracks}];
        }
        return [];
    }
    
    sub selectrow_arrayref ($self, $sql, @rest) {
        push @{$self->queries}, [$sql, \@rest];
        if ($sql =~ /FROM anagrafica\.aeroporti/) {
            my $airport = $rest[1];
            return $self->airport_coords->{$airport};
        }
        return undef;
    }
    
    sub selectall_arrayref ($self, $sql, @rest) {
        push @{$self->queries}, [$sql, \@rest];
        if ($sql =~ /information_schema/) {
            return [['flay', 'InnoDB'], ['battute', 'InnoDB']];
        }
        if ($sql =~ /GROUP BY validation_fl/) {
            return [['Y', 1], ['N', 1]];
        }
        return [];
    }
    
    sub do ($self, $sql, @rest) {
        push @{$self->queries}, [$sql, \@rest];
        return 1;
    }
    
    sub disconnect ($self) { return 1 }
}

my $root = path($FindBin::Bin, '..', '..')->realpath;

subtest 'comando registrato nel catalogo' => sub {
    my $registry = ScriptManager::Service::ProcedureRegistry->new(file => $root->child('config', 'procedures.yml'))->load;
    my $proc = $registry->get('valida_tracce');
    ok $proc, 'valida_tracce presente nel catalogo';
    is $proc->{name}, '03-valida_tracce', 'nome corretto';
    is $proc->{handler_class}, 'ScriptManager::Command::ValidaTracce', 'handler corretto';
    is $proc->{execution_mode}, 'async', 'modalita asincrona';
    is $proc->{timeout_seconds}, 3600, 'timeout appropriato';
    ok $proc->{enabled}, 'comando abilitato';
};

subtest 'validazione parametri schema' => sub {
    my $registry = ScriptManager::Service::ProcedureRegistry->new(file => $root->child('config', 'procedures.yml'))->load;
    my $proc = $registry->get('valida_tracce');
    my $validator = $registry->validator($proc);
    
    my ($data, $errors) = $validator->validate({database => 'test_db', airport => 'LIME'});
    is_deeply $errors, [], 'parametri validi accettati';
    
    (undef, $errors) = $validator->validate({database => 'test db', airport => 'LIME'});
    ok @$errors, 'database con spazi rifiutato';
    
    (undef, $errors) = $validator->validate({database => 'test_db', airport => 'UNKNOWN'});
    ok @$errors, 'airport non configurato rifiutato';
};

subtest 'configurazione schema da MRT.json' => sub {
    local $ENV{MRT_CONFIG_FILE} = $root->child('config', 'MRT.example.json')->to_string;
    my $schema = {properties => {airport => {}}};
    ScriptManager::Command::ValidaTracce->configure_schema($schema, $root->child('config'));
    ok defined $schema->{properties}{airport}{enum}, 'enum configurato da MRT.json';
    ok @{$schema->{properties}{airport}{enum}}, 'almeno un aeroporto disponibile';
    ok defined $schema->{properties}{airport}{'x-enum-labels'}, 'etichette configurate';
};

subtest 'nessuna traccia da validare' => sub {
    local $ENV{MYSQL_HOST} = 'localhost';
    local $ENV{MYSQL_USER} = 'test';
    local $ENV{MYSQL_PASSWORD} = 'test';
    
    my $db = TestDatabase->new;
    my $ctx = TestContext->new;
    my $cmd = ScriptManager::Command::ValidaTracce->new(connect_db => sub (@args) { $db });
    
    my $result = $cmd->run($ctx, {database => 'test_db', airport => 'LIME'});
    ok $result->{success}, 'esecuzione completata';
    is $result->{data}{total_count}, 0, 'conteggio tracce assente';
    like $result->{message}, qr/nessuna traccia/i, 'messaggio appropriato';
};

subtest 'traccia valida con battute in intorno aeroporto' => sub {
    local $ENV{MYSQL_HOST} = 'localhost';
    local $ENV{MYSQL_USER} = 'test';
    local $ENV{MYSQL_PASSWORD} = 'test';
    
    my $db = TestDatabase->new(tracks => {
        1 => 'track1',
        2 => 'track2',
    });
    
    # Aggiungi le query per recuperare le battute
    my $queries_ref = $db->queries;
    my $old_selectall = $db->can('selectall_arrayref');
    $db->{queries_original} = $queries_ref;
    
    sub TestDatabase::selectall_arrayref_override {
        my ($self, $sql, @rest) = @_;
        push @{$self->queries}, [$sql, \@rest];
        if ($sql =~ /FROM battute WHERE flay_id/) {
            # Battute per le due tracce
            # Track 1: 4 battute, una valida
            # Track 2: 4 battute, una valida
            my $track_id = $rest[1];
            if ($track_id == 1) {
                return [
                    [1521800, 5034500, 500],  # fuori aeroporto
                    [1522000, 5034200, 100],  # dentro 10km, quota ok - VALIDA
                    [1522500, 5034100, 50],   # fuori per quota
                    [1523000, 5034000, 2000], # fuori per quota
                ];
            } elsif ($track_id == 2) {
                return [
                    [1520000, 5034000, 500],
                    [1521961.05, 5034234.14, 500],  # esattamente al centro, quota ok - VALIDA
                    [1525000, 5035000, 100],
                    [1526000, 5035500, 1500],
                ];
            }
        }
        if ($sql =~ /information_schema/) {
            return [['flay', 'InnoDB'], ['battute', 'InnoDB']];
        }
        if ($sql =~ /GROUP BY validation_fl/) {
            return [['Y', 2], ['N', 0]];
        }
        return [];
    }
    
    *TestDatabase::selectall_arrayref = \&TestDatabase::selectall_arrayref_override;
    
    my $ctx = TestContext->new;
    my $cmd = ScriptManager::Command::ValidaTracce->new(connect_db => sub (@args) { $db });
    
    my $result = $cmd->run($ctx, {database => 'test_db', airport => 'LIME'});
    ok $result->{success}, 'esecuzione completata';
    is $result->{data}{total_count}, 2, 'totale tracce';
    is $result->{data}{valid_count}, 2, 'tracce valide';
    is $result->{data}{invalid_count}, 0, 'tracce non valide';
    
    # Verifica update nel database
    my @updates = grep { $_->[0] =~ /^UPDATE flay SET validation_fl = \?/ } @{$db->queries};
    is scalar @updates, 2, 'due tracce validate come valide';
};

subtest 'traccia non valida per pochi hit' => sub {
    local $ENV{MYSQL_HOST} = 'localhost';
    local $ENV{MYSQL_USER} = 'test';
    local $ENV{MYSQL_PASSWORD} = 'test';
    
    my $db = TestDatabase->new(tracks => {1 => 'track1'});
    
    *TestDatabase::selectall_arrayref = sub {
        my ($self, $sql, @rest) = @_;
        push @{$self->queries}, [$sql, \@rest];
        if ($sql =~ /FROM battute WHERE flay_id/) {
            return [
                [1521800, 5034500, 500],
                [1522000, 5034200, 100],
                [1522500, 5034100, 50],
            ];
        }
        if ($sql =~ /information_schema/) {
            return [['flay', 'InnoDB'], ['battute', 'InnoDB']];
        }
        if ($sql =~ /GROUP BY validation_fl/) {
            return [['N', 1], ['Y', 0]];
        }
        return [];
    };
    
    my $ctx = TestContext->new;
    my $cmd = ScriptManager::Command::ValidaTracce->new(connect_db => sub (@args) { $db });
    
    my $result = $cmd->run($ctx, {database => 'test_db', airport => 'LIME'});
    ok $result->{success};
    is $result->{data}{valid_count}, 0, 'nessuna traccia valida';
    is $result->{data}{invalid_count}, 1, 'una traccia non valida per pochi hit';
    
    my @updates = grep { $_->[0] =~ /^UPDATE battute SET validation/ } @{$db->queries};
    is scalar @updates, 1, 'battute marcate come invalide';
};

subtest 'traccia non valida per nessun hit in intorno aeroporto' => sub {
    local $ENV{MYSQL_HOST} = 'localhost';
    local $ENV{MYSQL_USER} = 'test';
    local $ENV{MYSQL_PASSWORD} = 'test';
    
    my $db = TestDatabase->new(tracks => {1 => 'track1'});
    
    *TestDatabase::selectall_arrayref = sub {
        my ($self, $sql, @rest) = @_;
        push @{$self->queries}, [$sql, \@rest];
        if ($sql =~ /FROM battute WHERE flay_id/) {
            return [
                [1500000, 5000000, 500],  # molto lontano
                [1510000, 5020000, 100],  # lontano
                [1520000, 5030000, 2000], # fuori per quota
                [1521800, 5034500, 500],  # fuori per distanza
            ];
        }
        if ($sql =~ /information_schema/) {
            return [['flay', 'InnoDB'], ['battute', 'InnoDB']];
        }
        if ($sql =~ /GROUP BY validation_fl/) {
            return [['N', 1]];
        }
        return [];
    };
    
    my $ctx = TestContext->new;
    my $cmd = ScriptManager::Command::ValidaTracce->new(connect_db => sub (@args) { $db });
    
    my $result = $cmd->run($ctx, {database => 'test_db', airport => 'LIME'});
    is $result->{data}{valid_count}, 0, 'nessuna traccia valida';
    is $result->{data}{invalid_count}, 1, 'una traccia non valida per hit fuori intorno';
};

subtest 'offset Y applicato per aeroporti specifici' => sub {
    local $ENV{MYSQL_HOST} = 'localhost';
    local $ENV{MYSQL_USER} = 'test';
    local $ENV{MYSQL_PASSWORD} = 'test';
    
    # Verifica offset per LIME
    is $ScriptManager::Command::ValidaTracce::AIRPORTS{LIME}{offset_y}, -376, 'offset LIME corretto';
    
    # Verifica offset per LIPO
    is $ScriptManager::Command::ValidaTracce::AIRPORTS{LIPO}{offset_y}, -2515, 'offset LIPO corretto';
};

subtest 'errori database classificati correttamente' => sub {
    local $ENV{MYSQL_HOST} = 'localhost';
    local $ENV{MYSQL_USER} = 'test';
    local $ENV{MYSQL_PASSWORD} = 'test';
    
    my $driver = DBI->install_driver('MariaDB') if eval { DBI->install_driver('MariaDB'); 1 };
    
    # Test mancanza variabili ambiente
    local $ENV{MYSQL_HOST} = '';
    my $ctx = TestContext->new;
    my $cmd = ScriptManager::Command::ValidaTracce->new(connect_db => sub (@args) { TestDatabase->new });
    
    eval { $cmd->run($ctx, {database => 'test_db', airport => 'LIME'}) };
    ok(ScriptManager::Exception->caught($@, 'mysql_config'), 'mancanza MYSQL_HOST rilevata');
};

subtest 'avanzamento tracciato' => sub {
    local $ENV{MYSQL_HOST} = 'localhost';
    local $ENV{MYSQL_USER} = 'test';
    local $ENV{MYSQL_PASSWORD} = 'test';
    
    my $db = TestDatabase->new(tracks => {1 => 'track1', 2 => 'track2', 3 => 'track3'});
    
    *TestDatabase::selectall_arrayref = sub {
        my ($self, $sql, @rest) = @_;
        push @{$self->queries}, [$sql, \@rest];
        if ($sql =~ /FROM battute WHERE flay_id/) {
            return [
                [1521961.05, 5034234.14, 100],
                [1522000, 5034200, 100],
                [1522500, 5034100, 50],
                [1523000, 5034000, 2000],
            ];
        }
        if ($sql =~ /information_schema/) {
            return [['flay', 'InnoDB'], ['battute', 'InnoDB']];
        }
        if ($sql =~ /GROUP BY validation_fl/) {
            return [['Y', 3]];
        }
        return [];
    };
    
    my $ctx = TestContext->new;
    my $cmd = ScriptManager::Command::ValidaTracce->new(connect_db => sub (@args) { $db });
    
    my $result = $cmd->run($ctx, {database => 'test_db', airport => 'LIME'});
    ok $result->{success};
    ok scalar @{$ctx->percentages}, 'avanzamento registrato';
    is $ctx->percentages->[-1], 100, 'ultimo avanzamento al 100%';
};

done_testing;
