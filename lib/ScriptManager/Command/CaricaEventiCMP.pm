package ScriptManager::Command::CaricaEventiCMP;
use Mojo::Base -base, -signatures;

use ScriptManager::Exception;
use ScriptManager::Service::EventiCMP;

has [qw(logger process_runner)];
has eventi => sub { ScriptManager::Service::EventiCMP->new };

sub run ($self, $ctx, $params) {
    my $files = $self->eventi->files;
    my ($names, $hashes, $stations) = @{$params}{qw(files hashes stations)};
    ScriptManager::Exception->throw('invalid_associations', 'Associare una stazione a ogni file TXT')
        unless ref $names eq 'ARRAY' && ref $hashes eq 'ARRAY' && ref $stations eq 'ARRAY'
        && @$names == @$files && @$hashes == @$files && @$stations == @$files;
    for my $i (0 .. $#$files) {
        ScriptManager::Exception->throw('txt_changed', "L'elenco dei file TXT e cambiato: ripetere l'associazione")
            unless ($names->[$i] // '') eq $files->[$i]{name}
            && ($hashes->[$i] // '') eq $files->[$i]{sha256};
    }

    $ctx->progress(0, 'Verifica file e stazioni');
    my $db = $self->eventi->connect($params->{database});
    my $allowed = $self->eventi->stations($db, $params->{airport});
    my %allowed = map { $_->{row_id} => $_ } @$allowed;
    my %codes;
    $codes{$_->{c_cab}}++ for grep { defined $_->{c_cab} } @$allowed;
    my @input;
    for my $i (0 .. $#$files) {
        $ctx->check_cancel;
        my ($id, $expected_code) = ($stations->[$i] // '') =~ /\A([1-9]\d*):(\d+)\z/;
        ScriptManager::Exception->throw('invalid_associations', "Stazione non valida per $names->[$i]")
            unless defined $id && $allowed{$id};
        my $code = $allowed{$id}{c_cab};
        ScriptManager::Exception->throw('invalid_associations',
            "Codice c_cab cambiato, mancante, non valido o ambiguo per la stazione $allowed{$id}{nome}")
            unless defined $code && $code =~ /\A\d+\z/ && $code <= 2147483647
            && $code eq $expected_code && $codes{$code} == 1;
        my $events = $self->eventi->read_events($names->[$i], $hashes->[$i]);
        push @input, {name => $names->[$i], station => $code, events => $events};
        $ctx->log(info => "$names->[$i]: " . scalar(@$events) . " eventi, stazione $allowed{$id}{nome} (c_cab $code)");
        $ctx->progress(int(25 * ($i + 1) / @$files), 'Verifica file TXT');
    }

    my $indexes = $db->selectall_arrayref(
        'SELECT INDEX_NAME, COLUMN_NAME, SEQ_IN_INDEX, SUB_PART FROM information_schema.STATISTICS '
        . 'WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND NON_UNIQUE = 0 ORDER BY INDEX_NAME, SEQ_IN_INDEX',
        {Slice => {}}, $params->{database}, 'st_eventi_cmp');
    my %indexes;
    for my $index (@$indexes) {
        push @{$indexes{$index->{INDEX_NAME}}}, defined $index->{SUB_PART} ? '' : lc($index->{COLUMN_NAME} // '');
    }
    my $unique = grep { join(',', @$_) eq 'id_centralina_cmp,data_ora,durata,leq' } values %indexes;
    my $locked = 0;
    my ($inserted, $duplicates) = (0, 0);
    my $ok = eval {
        $ctx->check_cancel;
        $db->do(q{SET SESSION sql_mode = CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), 'STRICT_ALL_TABLES')});
        unless ($unique) {
            $db->do('LOCK TABLES st_eventi_cmp WRITE');
            $locked = 1;
            $ctx->log(warning => 'Indice univoco eventi assente: controllo duplicati sotto lock MySQL');
        }
        my $find = $db->prepare('SELECT row_id FROM st_eventi_cmp '
            . 'WHERE id_centralina_cmp = ? AND Data_ora = ? AND Durata = ? AND Leq = ? LIMIT 1');
        my $insert = $db->prepare('INSERT INTO st_eventi_cmp '
            . '(id_centralina_cmp, Data_ora, Durata, Leq, Leq_10, Sel, Sel_10, LMax) VALUES (?, ?, ?, ?, ?, ?, ?, ?)');
        my $total = 0;
        $total += @{$_->{events}} for @input;
        my $done = 0;
        $ctx->log(warning => 'Scritture AutoCommit: errori, timeout o annullamento possono lasciare dati parziali');
        for my $file (@input) {
            my ($file_inserted, $file_duplicates) = (0, 0);
            for my $event (@{$file->{events}}) {
                if ($done % 100 == 0) {
                    $ctx->check_cancel;
                    $ctx->progress(25 + int(74 * $done / $total), 'Importazione eventi');
                }
                my @key = ($file->{station}, @$event[0 .. 2]);
                if (!$unique) {
                    $find->execute(@key);
                    if ($find->fetchrow_arrayref) { $duplicates++; $file_duplicates++; $done++; next }
                }
                my $saved = eval { $insert->execute($file->{station}, @$event); 1 };
                my $error = $@;
                unless ($saved) {
                    die $error if ScriptManager::Exception->caught($error);
                    die $error unless ($insert->err // 0) == 1062;
                    $find->execute(@key);
                    die $error unless $find->fetchrow_arrayref;
                    $duplicates++;
                    $file_duplicates++;
                    $done++;
                    next;
                }
                $inserted++;
                $file_inserted++;
                $done++;
            }
            $ctx->log(info => "$file->{name}: $file_inserted inseriti, $file_duplicates duplicati ignorati");
        }
        1;
    };
    my $error = $@;
    if ($locked) {
        my $unlocked = eval { $db->do('UNLOCK TABLES'); 1 };
        my $unlock_error = $@;
        die $error || $unlock_error unless $unlocked;
    }
    $db->disconnect;
    die $error unless $ok;
    $ctx->progress(100, 'Importazione completata');
    return {success => 1, message => "Eventi inseriti: $inserted; duplicati ignorati: $duplicates"};
}

1;
