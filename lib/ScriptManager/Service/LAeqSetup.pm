package ScriptManager::Service::LAeqSetup;
use Mojo::Base -base, -signatures;

use ScriptManager::Exception;
use ScriptManager::Service::CorrelazioneSetup;
use ScriptManager::Service::EventiCMP;

has 'repo';
has eventi => sub { ScriptManager::Service::EventiCMP->new };
has correlazione => sub { ScriptManager::Service::CorrelazioneSetup->new };

sub schema ($self, $db, $database) {
    my @columns = qw(row_id id_stazione data_laeq tr valore_laeq);
    my @schemas;
    for my $name ('mxp_2024_bruma', $database) {
        my $rows = $db->selectall_arrayref(
            'SELECT COLUMN_NAME, COLUMN_TYPE, EXTRA FROM information_schema.COLUMNS '
            . 'WHERE TABLE_SCHEMA=? AND TABLE_NAME=?',
            {Slice => {}}, $name, 'st_laeq');
        push @schemas, {map { lc($_->{COLUMN_NAME}) => $_ } @$rows};
    }
    my ($reference, $target) = @schemas;
    my @errors;
    for my $column (@columns) {
        push @errors, "Riferimento mxp_2024_bruma.st_laeq incompleto: $column"
            unless exists $reference->{$column};
    }
    push @errors, 'Riferimento mxp_2024_bruma.st_laeq senza identificatore auto_increment'
        if exists $reference->{row_id} && $reference->{row_id}{EXTRA} !~ /auto_increment/i;
    if (keys %$target) {
        for my $column (@columns) {
            next unless exists $reference->{$column};
            push @errors, "Colonna st_laeq.$column mancante o incompatibile con il riferimento"
                unless exists $target->{$column}
                && lc($target->{$column}{COLUMN_TYPE}) eq lc($reference->{$column}{COLUMN_TYPE});
        }
        push @errors, 'Identificatore st_laeq senza auto_increment'
            if exists $target->{row_id} && $target->{row_id}{EXTRA} !~ /auto_increment/i;
    }
    return {missing => keys(%$target) ? 0 : 1, errors => \@errors};
}

sub preview ($self, $airport, $database) {
    $self->correlazione->validate_target($airport, $database);
    my $db = $self->eventi->connect($database);
    my $schema = $self->schema($db, $database);
    my $stations = $self->eventi->stations($db, $airport);
    $db->disconnect;
    return {schema => $schema,
        stations => [grep { defined $_->{aeroporto} && $_->{aeroporto} eq $airport } @$stations]};
}

sub prepare ($self, $airport, $database) {
    $self->correlazione->validate_target($airport, $database);
    my $db = $self->eventi->connect($database);
    my $target = join ':', lc($ENV{MYSQL_HOST}), 0 + ($ENV{MYSQL_PORT} // 3306), $database;
    my $guard = $self->repo->lock_database_for_schema($target);
    ScriptManager::Exception->throw('database_busy', 'Database occupato o con esecuzioni in coda')
        unless $guard;
    my $schema = $self->schema($db, $database);
    ScriptManager::Exception->throw('mysql_schema', join('; ', @{$schema->{errors}}) ) if @{$schema->{errors}};
    ScriptManager::Exception->throw('mysql_schema_changed', 'La tabella st_laeq non e piu mancante')
        unless $schema->{missing};
    my $destination = $db->quote_identifier($database, 'st_laeq');
    my $reference = $db->quote_identifier('mxp_2024_bruma', 'st_laeq');
    $db->do("CREATE TABLE $destination LIKE $reference");
    $db->disconnect;
    return;
}

1;
