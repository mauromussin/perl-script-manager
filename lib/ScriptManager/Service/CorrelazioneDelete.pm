package ScriptManager::Service::CorrelazioneDelete;
use Mojo::Base -base, -signatures;

use Digest::SHA 'sha256_hex';
use Mojo::JSON 'encode_json';
use POSIX 'strftime';
use Time::Local 'timegm';
use ScriptManager::Exception;
use ScriptManager::Service::CorrelazioneSetup;
use ScriptManager::Service::EventiCMP;

has eventi => sub { ScriptManager::Service::EventiCMP->new };
has setup => sub { ScriptManager::Service::CorrelazioneSetup->new };

sub inspect ($self, $params, $db) {
    my ($airport, $database, $day, $id, $code) = @$params{qw(airport database day station_id station_code)};
    $self->setup->validate_target($airport, $database);
    my ($year) = $database =~ /_(\d{4})_bruma\z/i;
    my ($y, $m, $d) = ($day // '') =~ /\A([1-9]\d{3})-(\d\d)-(\d\d)\z/;
    my $epoch = defined $y ? eval { timegm(0, 0, 0, $d, $m - 1, $y) } : undef;
    ScriptManager::Exception->throw('invalid_correlation_deletion', 'Data non valida o diversa dall anno del database')
        unless defined $epoch && strftime('%Y-%m-%d', gmtime($epoch)) eq $day && $y eq $year;
    ScriptManager::Exception->throw('invalid_correlation_deletion', 'Stazione non valida')
        unless defined $id && $id =~ /\A[1-9]\d{0,9}\z/ && $id <= 2147483647
        && defined $code && $code =~ /\A\d{1,10}\z/ && $code <= 2147483647;
    my $stations = $db->selectall_arrayref(
        'SELECT s.row_id, a.nome_aerop, s.name FROM anagrafica.stazioni s '
        . 'LEFT JOIN anagrafica.aeroporti a ON a.row_id=s.aeroporti_id WHERE s.c_cab=?',
        undef, $code);
    ScriptManager::Exception->throw('invalid_correlation_deletion', 'Stazione non appartenente all aeroporto o codice ambiguo')
        unless @$stations == 1 && $stations->[0][0] == $id
        && defined $stations->[0][1] && uc($stations->[0][1]) eq $airport;

    my $links = $db->selectall_arrayref(
        'SELECT c.row_id, c.evento_cmp_id, c.flay_id, c.battuta_id, c.distance, c.shift '
        . 'FROM battute_eventi_cmp c JOIN st_eventi_cmp e ON e.row_id=c.evento_cmp_id '
        . 'WHERE e.id_centralina_cmp=? AND DATE(e.data_ora)=? ORDER BY c.row_id',
        undef, $code, $day);
    my $has_lvan = 1;
    my @results;
    for my $item (['st_lva', 'data_lva'], ['st_lvan', 'data_lvan']) {
        my ($table, $date) = @$item;
        my $rows;
        my $ok = eval {
            $rows = $db->selectall_arrayref(
                "SELECT row_id, id_log, valore, attuale FROM $table "
                . "WHERE id_stazione=? AND $date=? AND correlato=1 ORDER BY row_id",
                undef, $code, $day);
            1;
        };
        my ($error, $error_code) = ($@, $db->err);
        if (!$ok) {
            die $error unless $table eq 'st_lvan' && defined $error_code && $error_code == 1146;
            $has_lvan = 0;
            $rows = [];
        }
        push @results, $rows;
    }
    my $active = 0;
    $active += scalar grep { $_->[3] } @$_ for @results;
    ScriptManager::Exception->throw('invalid_correlation_deletion', 'Nessuna correlazione o risultato correlato attuale da eliminare')
        unless @$links || $active;
    my $server = join ':', lc($ENV{MYSQL_HOST} // ''), 0 + ($ENV{MYSQL_PORT} // 3306);
    my $snapshot = sha256_hex(encode_json([$server, $airport, $database, $day, 0 + $id, 0 + $code,
        $links, \@results, 0 + $has_lvan]));
    return {snapshot => $snapshot, links => scalar @$links, active => $active,
        station_name => $stations->[0][2], has_lvan => $has_lvan};
}

sub preview ($self, $params) {
    my $db = $self->eventi->connect($params->{database});
    my $result = $self->inspect($params, $db);
    $db->disconnect;
    return $result;
}

sub run ($self, $ctx, $params) {
    ScriptManager::Exception->throw('invalid_correlation_deletion', 'Conferma o verifica non valida')
        unless $params->{confirm_deletion} && ($params->{snapshot} // '') =~ /\A[0-9a-f]{64}\z/;
    my $db = $self->eventi->connect($params->{database});
    my $preview = $self->inspect($params, $db);
    ScriptManager::Exception->throw('correlation_changed', 'Dati modificati dopo la conferma: ripetere la verifica')
        unless $preview->{snapshot} eq $params->{snapshot};
    $ctx->log(warning => 'Cancellazione MyISAM in AutoCommit: errori o annullamenti possono lasciare effetti parziali',
        operation => 'correlation_deletion_start', map { $_ => $params->{$_} } qw(database airport day station_id station_code));
    $ctx->check_cancel;
    my $deleted = $db->do(
        'DELETE c FROM battute_eventi_cmp c JOIN st_eventi_cmp e ON e.row_id=c.evento_cmp_id '
        . 'WHERE e.id_centralina_cmp=? AND DATE(e.data_ora)=?',
        undef, @$params{qw(station_code day)});
    $ctx->log(info => "Abbinamenti eliminati: $deleted", operation => 'correlation_deletion_links', deleted => 0 + $deleted);
    for my $item (['st_lva', 'data_lva'], ['st_lvan', 'data_lvan']) {
        $ctx->check_cancel;
        my ($table, $date) = @$item;
        next if $table eq 'st_lvan' && !$preview->{has_lvan};
        my $updated = $db->do("UPDATE $table SET attuale=0 WHERE id_stazione=? AND $date=? AND correlato=1 AND attuale=1",
            undef, @$params{qw(station_code day)});
        $ctx->log(info => "Risultati $table disattivati: $updated",
            operation => 'correlation_deletion_results', result_type => $table, updated => 0 + $updated);
    }
    $db->disconnect;
    return {success => 1, message => 'Correlazioni eliminate e risultati correlati disattivati'};
}

1;
