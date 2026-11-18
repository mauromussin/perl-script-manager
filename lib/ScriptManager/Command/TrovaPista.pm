package ScriptManager::Command::TrovaPista;
use Mojo::Base -base, -signatures;

use DBI;
use ScriptManager::Exception;
use ScriptManager::Service::RunwayGeometry;
use ScriptManager::Service::ValidationWindow;

has [qw(logger process_runner operation)];
has connect_db => sub { sub (@args) { DBI->connect(@args) } };
has window_class => 'ScriptManager::Service::ValidationWindow';

sub configure_schema ($class, $schema, $directory) {
    ScriptManager::Service::ValidationWindow->configure_schema($schema);
}

sub run ($self, $ctx, $params) {
    ScriptManager::Service::ValidationWindow->validate_params($params);
    my $operation = $self->operation;
    ScriptManager::Exception->throw('invalid_operation', 'Operazione pista non configurata')
        unless ($operation // '') =~ /\A[AD]\z/;
    my $airport = $params->{airport} // '';
    my $revision = $params->{revision} // '1.2';
    ScriptManager::Exception->throw('invalid_airport', 'Aeroporto non supportato per assegnazione piste')
        unless $airport =~ /\A(?:LIMC|LIML|LIME|LIPO)\z/;
    ScriptManager::Exception->throw('invalid_revision', 'Revisione 05 non supportata')
        if $operation eq 'A' && $revision !~ /\A1\.[012]\z/;
    ScriptManager::Exception->throw('invalid_airport', 'La revisione 1.0 non implementa Montichiari')
        if $operation eq 'A' && $revision eq '1.0' && $airport eq 'LIPO';
    ScriptManager::Exception->throw('invalid_database', 'Nome database MySQL non valido')
        unless ($params->{database} // '') =~ /\A[A-Za-z0-9_]{1,64}\z/;
    for my $key (qw(MYSQL_HOST MYSQL_USER MYSQL_PASSWORD)) {
        ScriptManager::Exception->throw('mysql_config', "Configurazione $key mancante")
            unless defined $ENV{$key} && length $ENV{$key};
    }
    my $port = $ENV{MYSQL_PORT} // 3306;
    ScriptManager::Exception->throw('mysql_config', 'Host o porta MySQL non validi')
        unless $ENV{MYSQL_HOST} =~ /\A[A-Za-z0-9.:-]+\z/ && $port =~ /\A\d+\z/ && $port > 0 && $port <= 65535;
    $ctx->progress(0, 'Analisi: lettura tracce e anagrafica piste');
    my $db;
    my $connected = eval {
        $db = $self->connect_db->(
            "DBI:MariaDB:database=$params->{database};host=$ENV{MYSQL_HOST};port=$port",
            $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD},
            {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_auto_reconnect => 0});
        1;
    };
    my $error = $@;
    unless ($connected && $db) {
        die $error if ScriptManager::Exception->caught($error);
        die $error if !$connected && !defined $DBI::err;
        ScriptManager::Exception->throw('mysql_connect',
            'Connessione MySQL fallita: verificare MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD e database');
    }
    my $result;
    my $window;
    my $ok = eval {
        $window = $self->window_class->new(db => $db, ctx => $ctx, params => $params,
            stage => $operation eq 'A' ? 5 : 6)->prepare;
        my ($filter, @scope_bind) = $window->filter;
        $ctx->log(info => "Assegnazione piste $operation per $airport"
            . ($operation eq 'A' ? ", revisione $revision" : ', revisione 1.1')
            . '; scritture in AutoCommit senza rollback');
        my $tracks = $db->selectcol_arrayref(
            'SELECT row_id FROM flay WHERE flay_operation = ? AND '
            . ($window->overwrite ? $window->runway_candidates : 'validation_bt = ? AND pista IS NULL')
            . $filter . ' ORDER BY row_id', undef, $operation, ($window->overwrite ? () : (1)), @scope_bind);
        my $geometry;
        if (@$tracks) {
            my $rows = $db->selectall_arrayref(
                'SELECT p.nome_pista, p.LONG_pista, p.LAT_pista, a.QUOTA_aerop '
                . 'FROM anagrafica.aeroporti a JOIN anagrafica.piste p ON a.row_id = p.id_aerop '
                . 'WHERE a.nome_aerop = ?', undef, $airport);
            my $center = $airport eq 'LIMC' && $operation eq 'D'
                ? $db->selectrow_arrayref(
                    'SELECT LONG_aerop, LAT_aerop FROM anagrafica.aeroporti WHERE nome_aerop = ?', undef, $airport)
                : undef;
            $geometry = ScriptManager::Service::RunwayGeometry->prepare($airport, $operation, $revision, $rows, $center);
        }
        my (@plans, $analyzed);
        $analyzed = 0;
        for my $id (@$tracks) {
            $ctx->check_cancel;
            my $hits = $db->selectall_arrayref(
                'SELECT X_m, Y_m, H_m, row_id FROM battute WHERE flay_id = ? AND '
                . ($window->overwrite && $operation eq 'A' ? 'validation IN (?, ?)' : 'validation = ?')
                . ' ORDER BY time_italy, row_id', undef, $id, 'Y',
                ($window->overwrite && $operation eq 'A' ? ('X') : ()));
            my $plan = ScriptManager::Service::RunwayGeometry->analyze($geometry, $hits);
            $plan->{id} = $id;
            push @plans, $plan;
            $analyzed++;
            $ctx->log($plan->{invalid} ? 'warning' : 'info',
                "Traccia $id: pista $plan->{pista}" . (defined $plan->{reason} ? " ($plan->{reason})" : ''),
                track_id => $id, runway => $plan->{pista});
            $ctx->progress(int(50 * $analyzed / @$tracks), "Analisi: $analyzed di " . scalar(@$tracks) . ' tracce');
        }
        my $saved = 0;
        $ctx->progress(50, 'Salvataggio: piste, stati delle tracce ed eventuali battute X');
        $window->start_saving;
        for my $plan (@plans) {
            $ctx->check_cancel;
            for my $id (@{$plan->{excluded}}) {
                $db->do('UPDATE battute SET validation = ? WHERE flay_id = ? AND row_id = ?',
                    undef, 'X', $plan->{id}, $id);
            }
            $ctx->check_cancel;
            if ($plan->{invalid}) {
                $db->do('UPDATE flay SET pista = ?, validation_fl = ?, validation_bt = ? WHERE row_id = ?',
                    undef, $plan->{pista}, 'P', 0, $plan->{id});
            }
            elsif ($operation eq 'A') {
                $db->do('UPDATE flay SET pista = ?, sid = ? WHERE row_id = ?',
                    undef, $plan->{pista}, $plan->{pista}, $plan->{id});
            }
            else {
                $db->do('UPDATE flay SET pista = ? WHERE row_id = ?', undef, $plan->{pista}, $plan->{id});
            }
            $saved++;
            $ctx->progress(50 + int(49 * $saved / @plans),
                "Salvataggio: $saved di " . scalar(@plans) . ' tracce');
        }
        $ctx->check_cancel;
        $ctx->progress(99, 'Riepilogo finale delle piste');
        my $report = $db->selectall_arrayref(
            'SELECT pista, COUNT(*) FROM flay WHERE flay_operation = ? AND pista IS NOT NULL'
            . ($operation eq 'D' ? ' AND sid IS NULL' : '') . $filter . ' GROUP BY pista',
            undef, $operation, @scope_bind);
        $ctx->log(info => "Riepilogo pista nei giorni elaborati $_->[0]: $_->[1]") for @$report;
        my $unassigned = grep { $_->{invalid} } @plans;
        $result = {
            success => 1,
            message => @plans ? scalar(@plans) . " tracce elaborate, $unassigned piste non assegnate"
                : 'Nessuna traccia da assegnare',
            data => {tracks => scalar(@plans), assigned => @plans - $unassigned, unassigned => $unassigned, report => $report},
        };
        1;
    };
    $error = $@;
    unless ($ok) {
        $ctx->log(error => 'Assegnazione piste interrotta; eventuali scritture gia eseguite non sono annullate');
        my $closed = eval { $db->disconnect; 1 };
        $ctx->log(error => 'Chiusura della connessione MySQL fallita') unless $closed;
        die $error;
    }
    $db->disconnect;
    $window->finish($result);
    $ctx->progress(100, 'Assegnazione piste conclusa');
    return $result;
}

1;
