package ScriptManager::Service::MyISAMImport;
use Mojo::Base -base, -signatures;

use Digest::SHA 'sha256_hex';
use Log::Any ();
use Mojo::JSON 'encode_json';
use ScriptManager::Exception;

has [qw(db ctx)];
has logger => sub { Log::Any->get_logger(category => 'ScriptManager::MyISAMImport') };
has acquired => 0;
has owned => 0;
has locked => 0;
has publishing => 0;
has published => 0;
has reused_tracks => 0;
has repaired_tracks => 0;
has diverted_hits => 0;
has columns => sub { {} };
has schemas => sub { {} };
has bounds => sub { {} };
has counts => sub { {} };
has names => sub ($self) {
    my $id = $self->ctx->execution_id // '';
    ScriptManager::Exception->throw('mysql_import_id', 'Identificatore esecuzione non valido')
        unless $id =~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i;
    $id =~ s/-//g;
    return {map { $_ => '_sm_import_' . lc($id) . "_$_" }
        qw(flay battute battute_doppie track_map undo_flay undo_battute state)};
};
has lock_name => sub ($self) {
    my ($database) = $self->db->selectrow_array('SELECT DATABASE()');
    ScriptManager::Exception->throw('mysql_schema', 'Database MySQL non selezionato') unless defined $database;
    return 'sm:carica_db:' . substr(sha256_hex($database), 0, 48);
};

sub table ($self, $role) {
    return $self->db->quote_identifier($self->names->{$role});
}

sub _fields ($self, $table) {
    return join ', ', map { $self->db->quote_identifier($_) } @{$self->columns->{$table}};
}

sub _drop ($self, $names) {
    for my $role (qw(undo_battute undo_flay battute_doppie battute flay track_map state)) {
        $self->db->do('DROP TABLE IF EXISTS ' . $self->db->quote_identifier($names->{$role}));
    }
}

sub _pending ($self) {
    my $rows = $self->db->selectall_arrayref(
        'SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE ?',
        undef, '_sm_import_%');
    my %imports;
    for my $row (@$rows) {
        next unless $row->[0] =~ /\A_sm_import_([0-9a-f]{32})_(flay|battute|battute_doppie|track_map|undo_flay|undo_battute|state)\z/;
        $imports{$1}{$2} = $row->[0];
    }
    for my $id (sort keys %imports) {
        my $found = $imports{$id};
        my ($phase, $state);
        if ($found->{state}) {
            $state = $self->db->selectrow_hashref(
                'SELECT * FROM '
                . $self->db->quote_identifier($found->{state}) . ' WHERE id = ?', undef, 1);
            $phase = $state->{phase} if $state;
        }
        if (defined $phase && $phase eq 'published') {
            # I journal precedenti non contengono battute_doppie ne i conteggi.
            my @tables = qw(flay battute);
            push @tables, 'battute_doppie'
                if exists $state->{battute_doppie_min} || $found->{battute_doppie} || $found->{track_map};
            for my $table (@tables) {
                my ($min, $max) = @{$state}{"${table}_min", "${table}_max"};
                my $expected = $state->{"${table}_count"};
                $expected = $max - $min + 1
                    if !defined $expected && defined $min && defined $max && $min > 0;
                unless (defined $min && defined $max && defined $expected
                    && (($min > 0 && $max >= $min && $expected > 0 && $expected <= $max - $min + 1)
                        || ($min == 0 && $max == 0 && $expected == 0))) {
                    $phase = 'recovery_required';
                    last;
                }
                my ($count) = $self->db->selectrow_array(
                    "SELECT COUNT(*) FROM $table WHERE row_id BETWEEN ? AND ?", undef, $min, $max);
                if ($count != $expected) {
                    $phase = 'recovery_required';
                    last;
                }
            }
        }
        unless (defined $phase && $phase =~ /\A(?:preparing|published|recovered)\z/) {
            $self->ctx->log(critical => "Importazione MyISAM $id incompleta: recupero verificato necessario");
            ScriptManager::Exception->throw('mysql_recovery_required',
                "Importazione MyISAM $id incompleta. Nuovi caricamenti bloccati: verificare il journal "
                . "_sm_import_${id}_state e le tabelle di recupero; non cancellarle senza verifica");
        }
        $self->ctx->log(warning => "Pulizia staging MyISAM abbandonato $id (fase $phase); nessuna modifica ai dati live");
        my $names = {map { $_ => "_sm_import_${id}_$_" }
            qw(flay battute battute_doppie track_map undo_flay undo_battute state)};
        $self->_drop($names);
    }
}

sub _check_triggers ($self) {
    my ($account, $database) = $self->db->selectrow_array('SELECT CURRENT_USER(), DATABASE()');
    ScriptManager::Exception->throw('mysql_import_permissions', 'Account MySQL non identificabile')
        unless defined $account && $account =~ /\A(.*)\@([^\@]*)\z/;
    my $grantee = $self->db->quote($1) . '@' . $self->db->quote($2);
    my ($global) = $self->db->selectrow_array(
        'SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES WHERE GRANTEE = ? AND PRIVILEGE_TYPE = ?',
        undef, $grantee, 'TRIGGER');
    my ($schema) = $self->db->selectrow_array(
        'SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES '
        . 'WHERE GRANTEE = ? AND PRIVILEGE_TYPE = ? AND ? LIKE TABLE_SCHEMA',
        undef, $grantee, 'TRIGGER', $database);
    my ($tables) = $self->db->selectrow_array(
        'SELECT COUNT(DISTINCT TABLE_NAME) FROM information_schema.TABLE_PRIVILEGES '
        . 'WHERE GRANTEE = ? AND PRIVILEGE_TYPE = ? AND TABLE_SCHEMA = ? AND TABLE_NAME IN (?, ?, ?)',
        undef, $grantee, 'TRIGGER', $database, 'flay', 'battute', 'battute_doppie');
    ScriptManager::Exception->throw('mysql_import_permissions',
        'Serve il privilegio diretto TRIGGER su flay, battute e battute_doppie per verificare che non ci siano trigger nascosti; '
        . 'la compensazione MyISAM non puo proseguire senza questa verifica')
        unless $global || $schema || $tables == 3;
    my ($count) = $self->db->selectrow_array(
        'SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = DATABASE() AND EVENT_OBJECT_TABLE IN (?, ?, ?)',
        undef, 'flay', 'battute', 'battute_doppie');
    ScriptManager::Exception->throw('mysql_schema',
        'Importazione MyISAM non consentita con trigger su flay, battute o battute_doppie: gli effetti esterni non sono compensabili')
        if $count;
}

sub prepare ($self) {
    my ($acquired) = $self->db->selectrow_array('SELECT GET_LOCK(?, 0)', undef, $self->lock_name);
    ScriptManager::Exception->throw('mysql_import_busy', 'Un altro caricamento usa questo database MySQL')
        unless defined $acquired && $acquired == 1;
    $self->acquired(1);
    $self->ctx->log(info => 'Lock esclusivo del caricatore MyISAM acquisito', operation => 'myisam_lock');
    $self->_pending;
    $self->_check_triggers;
    for my $table (qw(flay battute battute_doppie)) {
        my $rows = $self->db->selectall_arrayref(
            'SELECT COLUMN_NAME, COLUMN_TYPE, EXTRA FROM information_schema.COLUMNS '
            . 'WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION', undef, $table);
        my ($id) = grep { $_->[0] eq 'row_id' } @$rows;
        ScriptManager::Exception->throw('mysql_schema', "MyISAM: $table.row_id deve essere INT UNSIGNED AUTO_INCREMENT")
            unless $id && $id->[1] =~ /\Aint(?:\(\d+\))? unsigned\z/i && $id->[2] =~ /auto_increment/i;
        $self->columns->{$table} = [map { $_->[0] } grep { $_->[2] !~ /(?:VIRTUAL|STORED) GENERATED/i } @$rows];
        $self->schemas->{$table} = encode_json($rows);
    }
    $self->db->do('CREATE TABLE ' . $self->table('state') . ' ('
        . 'id TINYINT PRIMARY KEY, phase VARCHAR(32) NOT NULL, '
        . 'flay_min BIGINT UNSIGNED, flay_max BIGINT UNSIGNED, '
        . 'battute_min BIGINT UNSIGNED, battute_max BIGINT UNSIGNED, '
        . 'battute_doppie_min BIGINT UNSIGNED, battute_doppie_max BIGINT UNSIGNED, '
        . 'flay_count BIGINT UNSIGNED, battute_count BIGINT UNSIGNED, '
        . 'battute_doppie_count BIGINT UNSIGNED) ENGINE=MyISAM');
    $self->owned(1);
    $self->db->do('INSERT INTO ' . $self->table('state') . ' (id, phase) VALUES (?, ?)', undef, 1, 'preparing');
    for my $role (qw(flay battute battute_doppie undo_flay undo_battute)) {
        (my $source = $role) =~ s/\Aundo_//;
        $self->db->do('CREATE TABLE ' . $self->table($role) . ' LIKE ' . $self->db->quote_identifier($source));
        $self->db->do('ALTER TABLE ' . $self->table($role) . ' AUTO_INCREMENT = 1');
    }
    $self->db->do('CREATE TABLE ' . $self->table('track_map')
        . ' (local_id INT UNSIGNED PRIMARY KEY, live_id INT UNSIGNED NOT NULL, has_hits TINYINT NOT NULL) ENGINE=MyISAM');
    $self->ctx->log(info => 'Staging MyISAM creato: validazione senza scrivere in flay, battute e battute_doppie',
        operation => 'myisam_staging', journal => $self->names->{state});
    return $self;
}

sub _range ($self, $table) {
    my ($last) = $self->db->selectrow_array(
        'SELECT COALESCE(MAX(row_id), 0) FROM ' . $self->db->quote_identifier($table));
    my ($next) = $self->db->selectrow_array(
        'SELECT AUTO_INCREMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?',
        undef, $table);
    my $filter = $table eq 'flay' ? ' WHERE row_id NOT IN (SELECT local_id FROM ' . $self->table('track_map') . ')' : '';
    my ($size, $count) = $self->db->selectrow_array('SELECT MAX(row_id), COUNT(*) FROM ' . $self->table($table) . $filter);
    ScriptManager::Exception->throw('mysql_staging_empty', "Staging $table vuoto o contatore MySQL non disponibile")
        unless defined $count && defined $next;
    my $offset = $last > $next - 1 ? $last : $next - 1;
    $self->counts->{$table} = $count;
    unless ($count) {
        $self->bounds->{$table} = [0, 0];
        return $offset;
    }
    ScriptManager::Exception->throw('mysql_id_exhausted', "Identificatori INT UNSIGNED esauriti per $table")
        if $offset + $size > 4_294_967_295;
    $self->bounds->{$table} = [$offset + 1, $offset + $size];
    return $offset;
}

sub _existing_tracks ($self) {
    my $stage = $self->table('flay');
    my $map = $self->table('track_map');
    $self->db->do("INSERT INTO $map (local_id, live_id, has_hits) SELECT $stage.row_id, flay.row_id, "
        . 'EXISTS (SELECT 1 FROM battute WHERE battute.flay_id = flay.row_id) '
        . "FROM $stage INNER JOIN flay ON $stage.flay = flay.flay "
        . "AND $stage.data = flay.data AND $stage.ora = flay.ora");
    my ($count) = $self->db->selectrow_array("SELECT COUNT(*) FROM $map");
    $self->reused_tracks($count);
    return unless $count;
    my ($repaired) = $self->db->selectrow_array("SELECT COUNT(*) FROM $map WHERE has_hits = 0");
    $self->repaired_tracks($repaired);
    my $hits = $self->table('battute');
    my @columns = grep { $_ ne 'row_id' } @{$self->columns->{battute}};
    my $fields = join ', ', map { $self->db->quote_identifier($_) } @columns;
    my ($diverted) = $self->db->selectrow_array(
        "SELECT COUNT(*) FROM $hits WHERE flay_id IN (SELECT local_id FROM $map WHERE has_hits = 1)");
    $self->diverted_hits($diverted);
    $self->db->do('INSERT INTO ' . $self->table('battute_doppie') . " ($fields) "
        . "SELECT $fields FROM $hits WHERE flay_id IN (SELECT local_id FROM $map WHERE has_hits = 1) ORDER BY row_id");
    $self->db->do("DELETE FROM $hits WHERE flay_id IN (SELECT local_id FROM $map WHERE has_hits = 1)");
    $self->ctx->log(warning => ($count - $repaired) . " tracce gia presenti con battute: $diverted battute deviate in battute_doppie",
        operation => 'myisam_existing_tracks') if $count > $repaired;
}

sub _snapshot ($self, $airports, $merge) {
    return unless $merge || $self->repaired_tracks;
    my @codes = sort keys %$airports;
    my $placeholders = join ',', ('?') x @codes;
    my $condition = 'row_id IN (SELECT live_id FROM ' . $self->table('track_map') . ' WHERE has_hits = 0)';
    my @values;
    if ($merge) {
        $condition .= ' OR (ora < ? AND validation_fl IS NULL '
            . "AND (airport_dep IN ($placeholders) OR airport_arr IN ($placeholders)))";
        @values = ('00:10:00', @codes, @codes);
    }
    $self->db->do('INSERT INTO ' . $self->table('undo_flay') . ' (' . $self->_fields('flay') . ') '
        . 'SELECT ' . $self->_fields('flay') . " FROM flay WHERE $condition", undef, @values);
    $self->db->do('INSERT INTO ' . $self->table('undo_battute') . ' (' . $self->_fields('battute') . ') '
        . 'SELECT ' . $self->_fields('battute') . ' FROM battute WHERE flay_id IN '
        . '(SELECT row_id FROM ' . $self->table('undo_flay') . ')');
    $self->ctx->log(info => 'Salvati i dati preesistenti interessati dal completamento tracce o dall\'unione a mezzanotte',
        operation => 'myisam_snapshot');
}

sub _insert ($self, $table, $offset) {
    my $select = join ', ', map {
        $_ eq 'row_id' ? 'row_id + ?' : $self->db->quote_identifier($_)
    } @{$self->columns->{$table}};
    $self->db->do('INSERT INTO ' . $self->db->quote_identifier($table)
        . ' (' . $self->_fields($table) . ') SELECT ' . $select . ' FROM ' . $self->table($table)
        . ($table eq 'flay' ? ' WHERE row_id NOT IN (SELECT local_id FROM ' . $self->table('track_map') . ')' : '')
        . ' ORDER BY row_id', undef, $offset);
}

sub _phase ($self, $phase) {
    $self->db->do('UPDATE ' . $self->table('state') . ' SET phase = ? WHERE id = ?', undef, $phase, 1);
}

sub _unlock_tables ($self) {
    return unless $self->locked;
    $self->db->do('UNLOCK TABLES');
    $self->locked(0);
}

sub _release ($self) {
    $self->_unlock_tables;
    return unless $self->acquired;
    my ($released) = $self->db->selectrow_array('SELECT RELEASE_LOCK(?)', undef, $self->lock_name);
    ScriptManager::Exception->throw('mysql_lock_release', 'Rilascio lock del caricatore MyISAM non verificato')
        unless defined $released && $released == 1;
    $self->acquired(0);
}

sub publish ($self, $airports, $merge = undef, $complete = undef) {
    $self->ctx->check_cancel;
    $self->ctx->log(info => 'Pubblicazione MyISAM: acquisizione lock sulle tabelle live',
        operation => 'myisam_publish_lock');
    $self->db->do('LOCK TABLES flay WRITE, battute WRITE, battute_doppie WRITE, '
        . join(', ', map { $self->table($_) . ' WRITE' }
            qw(flay battute battute_doppie track_map undo_flay undo_battute state)));
    $self->locked(1);
    $self->_check_triggers;
    for my $table (qw(flay battute battute_doppie)) {
        my ($engine) = $self->db->selectrow_array(
            'SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?',
            undef, $table);
        my $schema = $self->db->selectall_arrayref(
            'SELECT COLUMN_NAME, COLUMN_TYPE, EXTRA FROM information_schema.COLUMNS '
            . 'WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION', undef, $table);
        ScriptManager::Exception->throw('mysql_schema', "Schema o motore di $table cambiato durante lo staging")
            unless defined $engine && $engine eq 'MyISAM' && encode_json($schema) eq $self->schemas->{$table};
    }
    $self->_existing_tracks;
    die "Gestione completamento tracce senza battute non disponibile\n"
        if $self->repaired_tracks && !$complete;
    my %offsets = map { $_ => $self->_range($_) } qw(flay battute battute_doppie);
    for my $table (qw(battute battute_doppie)) {
        $self->db->do('UPDATE ' . $self->table($table) . ' SET flay_id = COALESCE('
            . '(SELECT live_id FROM ' . $self->table('track_map') . ' WHERE local_id = '
            . $self->table($table) . '.flay_id), flay_id + ?)', undef, $offsets{flay});
    }
    $self->db->do('UPDATE ' . $self->table('state')
        . ' SET phase = ?, flay_min = ?, flay_max = ?, battute_min = ?, battute_max = ?, '
        . 'battute_doppie_min = ?, battute_doppie_max = ?, '
        . 'flay_count = ?, battute_count = ?, battute_doppie_count = ? WHERE id = ?',
        undef, 'publishing', (map { @{$self->bounds->{$_}} } qw(flay battute battute_doppie)),
        (map { $self->counts->{$_} } qw(flay battute battute_doppie)), 1);
    $self->publishing(1);
    $self->_snapshot($airports, $merge);
    if ($self->repaired_tracks) {
        my $stage = $self->table('flay');
        my $map = $self->table('track_map');
        my $fields = join ', ', map { "$stage." . $self->db->quote_identifier($_) }
            qw(flay data ora aircraft airport_dep airport_arr flay_operation data_ora_italy);
        my $rows = $self->db->selectall_arrayref(
            "SELECT $map.live_id, $fields FROM $stage INNER JOIN $map ON $stage.row_id = $map.local_id "
            . "WHERE $map.has_hits = 0 ORDER BY $stage.row_id");
        for my $row (@$rows) {
            $self->ctx->check_cancel;
            my ($id, @track) = @$row;
            $complete->($id, \@track);
        }
    }
    $self->ctx->log(info => 'Inserimento delle tracce validate nelle tabelle live', operation => 'myisam_publish_tracks');
    $self->_insert('flay', $offsets{flay});
    $self->ctx->check_cancel;
    $self->ctx->log(info => 'Inserimento delle battute validate nelle tabelle live', operation => 'myisam_publish_hits');
    $self->_insert('battute', $offsets{battute});
    $self->ctx->check_cancel;
    $self->ctx->log(info => 'Inserimento delle battute dei record duplicati in battute_doppie',
        operation => 'myisam_publish_duplicates');
    $self->_insert('battute_doppie', $offsets{battute_doppie});
    if ($merge) {
        my $result = $merge->();
        my $removed = ref($result) eq 'HASH' ? $result->{deduplicated} : 0;
        if ($removed) {
            die "Conteggio battute sovrapposte non valido\n"
                unless $removed =~ /\A\d+\z/ && $removed <= $self->counts->{battute};
            $self->counts->{battute} -= $removed;
            $self->db->do('UPDATE ' . $self->table('state') . ' SET battute_count = ? WHERE id = ?',
                undef, $self->counts->{battute}, 1);
        }
    }
    $self->ctx->check_cancel;
    {
        local $SIG{ALRM} = 'IGNORE';
        alarm 0;
        $self->_phase('published');
        $self->published(1);
    }
    $self->_unlock_tables;
    $self->ctx->log(info => 'Pubblicazione MyISAM completata; nessun rollback transazionale utilizzato',
        operation => 'myisam_publish_complete');
    my $clean = eval { $self->_drop($self->names); 1 };
    unless ($clean) {
        $self->logger->error('[ERROR] [exec=' . $self->ctx->execution_id . "] Pulizia staging MyISAM: $@");
        $self->ctx->log(warning => 'Dati MyISAM pubblicati, ma pulizia staging incompleta; '
            . 'la prossima esecuzione riprendera la pulizia', journal => $self->names->{state});
    }
    $self->_release;
    return $self;
}

sub abort ($self) {
    if ($self->published) {
        $self->_release;
        ScriptManager::Exception->throw('mysql_already_published',
            'Dati MyISAM gia pubblicati prima dell\'errore finale: non rieseguire il caricamento senza verifica');
    }
    return unless $self->acquired;
    local $SIG{ALRM} = 'IGNORE';
    alarm 0;
    my $safe = eval {
        if ($self->publishing) {
            die "Lock delle tabelle perso\n" unless $self->locked;
            $self->ctx->log(error => 'Pubblicazione MyISAM interrotta: compensazione dei dati sotto lock',
                operation => 'myisam_compensate');
            for my $table (qw(battute_doppie battute flay)) {
                next unless $self->counts->{$table};
                $self->db->do("DELETE FROM $table WHERE row_id BETWEEN ? AND ?", undef, @{$self->bounds->{$table}});
            }
            for my $table (qw(flay battute)) {
                $self->db->do("REPLACE INTO $table (" . $self->_fields($table) . ') SELECT '
                    . $self->_fields($table) . ' FROM ' . $self->table("undo_$table"));
            }
            $self->_phase('recovered');
            $self->ctx->log(info => 'Compensazione MyISAM completata: nuove righe rimosse e dati preesistenti ripristinati',
                operation => 'myisam_compensate_complete');
        }
        $self->_unlock_tables;
        $self->_drop($self->names) if $self->owned;
        1;
    };
    unless ($safe) {
        $self->logger->error('[ERROR] [exec=' . $self->ctx->execution_id . "] Compensazione/pulizia MyISAM: $@");
        my $recorded = eval { $self->_phase('recovery_required'); 1 };
        $self->logger->error('[ERROR] [exec=' . $self->ctx->execution_id . "] Aggiornamento journal MyISAM: $@")
            unless $recorded;
        $self->ctx->log(critical => 'Aggiornamento journal MyISAM non riuscito; conservare tutte le tabelle di lavoro')
            unless $recorded;
        $self->ctx->log(critical => 'Compensazione/pulizia MyISAM non completata: recupero verificato necessario',
            journal => $self->names->{state});
    }
    my $released = eval { $self->_release; 1 };
    unless ($released) {
        $self->logger->error('[ERROR] [exec=' . $self->ctx->execution_id . "] Rilascio lock MyISAM: $@");
        $self->ctx->log(critical => 'Rilascio lock MyISAM fallito: la connessione verra chiusa');
    }
    ScriptManager::Exception->throw('mysql_recovery_required',
        'Caricamento MyISAM interrotto con recupero non completato. Nuovi caricamenti bloccati: verificare '
        . $self->names->{state} . ' e le tabelle di recupero; non cancellarle senza verifica')
        unless $safe && $released;
    $self->ctx->log(info => 'Staging MyISAM rimosso dopo l\'errore; nessun caricamento parziale mantenuto',
        operation => 'myisam_abort_complete') if $self->owned;
    return;
}

1;
