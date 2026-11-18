package ScriptManager::Command::AssegnaSID;
use Mojo::Base -base, -signatures;

use DBI;
use ScriptManager::Exception;
use ScriptManager::Service::SIDGeometry;
use ScriptManager::Service::ValidationWindow;

has [qw(logger process_runner)];
has connect_db => sub { sub (@args) { DBI->connect(@args) } };
has window_class => 'ScriptManager::Service::ValidationWindow';

sub configure_schema ($class, $schema, $directory) {
    ScriptManager::Service::ValidationWindow->configure_schema($schema);
    $schema->{properties}{overwrite}{title} = 'Sovrascrivi le SID dei decolli selezionati';
}

sub run ($self, $ctx, $params) {
    ScriptManager::Service::ValidationWindow->validate_params($params);
    ScriptManager::Exception->throw('invalid_database', 'Nome database MySQL non valido')
        unless ($params->{database} // '') =~ /\A[A-Za-z0-9_]{1,64}\z/;
    my $airport = $params->{airport} // '';
    ScriptManager::Exception->throw('invalid_airport', 'SID 2.2 corr supporta solo LIMC, LIML e LIME')
        unless $airport =~ /\A(?:LIMC|LIML|LIME)\z/;
    for my $key (qw(MYSQL_HOST MYSQL_USER MYSQL_PASSWORD)) {
        ScriptManager::Exception->throw('mysql_config', "Configurazione $key mancante")
            unless defined $ENV{$key} && length $ENV{$key};
    }
    my $port = $ENV{MYSQL_PORT} // 3306;
    ScriptManager::Exception->throw('mysql_config', 'Host o porta MySQL non validi')
        unless $ENV{MYSQL_HOST} =~ /\A[A-Za-z0-9.:-]+\z/ && $port =~ /\A\d+\z/ && $port > 0 && $port <= 65535;
    $ctx->progress(0, 'Analisi: lettura dei decolli per assegnazione SID');
    my $db;
    my $connected = eval {
        $db = $self->connect_db->(
            "DBI:MariaDB:database=$params->{database};host=$ENV{MYSQL_HOST};port=$port",
            $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD},
            {RaiseError => 1, PrintError => 0, AutoCommit => 1, mariadb_auto_reconnect => 0});
        1;
    };
    my $connect_error = $@;
    unless ($connected && $db) {
        die $connect_error if ScriptManager::Exception->caught($connect_error);
        die $connect_error if !$connected && !defined $DBI::err;
        ScriptManager::Exception->throw('mysql_connect',
            'Connessione MySQL fallita: verificare host, porta, credenziali e database');
    }
    my ($result, $window);
    my $ok = eval {
        $window = $self->window_class->new(db => $db, ctx => $ctx, params => $params, stage => 7)->prepare;
        my ($filter, @bind) = $window->filter;
        $ctx->log(info => "Assegnazione SID per $airport, revisione 2.2 dal_2015_corr; "
            . 'date su data_ora_arr; AutoCommit senza rollback');
        my $tracks = $db->selectall_arrayref(
            'SELECT row_id, pista, validation_bt FROM flay WHERE flay_operation = ? AND validation_bt > ? '
            . 'AND pista IS NOT NULL' . ($window->overwrite ? '' : ' AND sid IS NULL')
            . $filter . ' ORDER BY row_id', undef, 'D', 0, @bind);
        my @plans;
        for my $track (@$tracks) {
            $ctx->check_cancel;
            my $hits = $db->selectall_arrayref(
                'SELECT X_m, Y_m, H_m FROM battute WHERE flay_id = ? AND validation = ? ORDER BY time_italy, row_id',
                undef, $track->[0], 'Y');
            my $sid = ScriptManager::Service::SIDGeometry->analyze($airport, $track->[1], $hits, $ctx);
            $sid = 'NA' if !defined $sid && $track->[2] == 1;
            push @plans, {id => $track->[0], sid => $sid};
            $ctx->log(!defined $sid || $sid eq 'NA' ? 'warning' : 'info',
                "Traccia $track->[0]: SID " . ($sid // 'NULL (nessuna corrispondenza, validation_bt > 1)'));
            $ctx->progress(int(50 * @plans / @$tracks), 'Analisi: ' . scalar(@plans) . ' di ' . scalar(@$tracks) . ' tracce');
        }
        $ctx->progress(50, 'Salvataggio: SID dei decolli');
        $window->start_saving;
        my $saved = 0;
        for my $plan (@plans) {
            $ctx->check_cancel;
            $db->do('UPDATE flay SET sid = ? WHERE row_id = ?', undef, $plan->{sid}, $plan->{id})
                if defined $plan->{sid};
            $saved++;
            $ctx->progress(50 + int(49 * $saved / @plans),
                "Salvataggio: $saved di " . scalar(@plans) . ' tracce');
        }
        $ctx->check_cancel;
        $ctx->progress(99, 'Riepilogo finale delle SID');
        my $report = $db->selectall_arrayref(
            'SELECT sid, COUNT(*) FROM flay WHERE flay_operation = ? AND validation_bt = ?'
            . $filter . ' GROUP BY sid', undef, 'D', 1, @bind);
        $ctx->log(info => 'Riepilogo SID ' . ($_->[0] // 'NULL') . ": $_->[1]") for @$report;
        my $unassigned = grep { !defined $_->{sid} || $_->{sid} eq 'NA' } @plans;
        $result = {
            success => 1,
            message => scalar(@plans) . " tracce elaborate, $unassigned SID non assegnate",
            data => {tracks => scalar(@plans), assigned => @plans - $unassigned,
                unassigned => $unassigned, report => $report},
        };
        1;
    };
    my $error = $@;
    unless ($ok) {
        $ctx->log(error => 'Assegnazione SID interrotta; eventuali scritture gia eseguite non sono annullate');
        my $closed = eval { $db->disconnect; 1 };
        $ctx->log(error => 'Chiusura della connessione MySQL fallita') unless $closed;
        die $error;
    }
    $db->disconnect;
    $window->finish($result);
    $ctx->progress(100, 'Assegnazione SID conclusa');
    return $result;
}

1;
