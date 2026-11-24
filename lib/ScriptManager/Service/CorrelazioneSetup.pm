package ScriptManager::Service::CorrelazioneSetup;
use Mojo::Base -base, -signatures;

use Mojo::JSON ();
use ScriptManager::Exception;
use ScriptManager::Service::EventiCMP;

has eventi => sub { ScriptManager::Service::EventiCMP->new };
has 'repo';

my %IATA = (LIMC => 'mxp', LIML => 'lin', LIME => 'bgy', LIPO => 'vbs');
my %REFERENCES = (
    st_eventi_cmp => 'bgy_2024_bruma',
    battute_eventi_cmp => 'bgy_2024_bruma',
    st_lva => 'bgy_2024_bruma',
    st_lvan => 'bgy_2025_bruma',
);
my %COLUMNS = (
    st_eventi_cmp => [qw(row_id id_centralina_cmp Data_ora Sel)],
    battute_eventi_cmp => [qw(row_id flay_id battuta_id evento_cmp_id distance shift)],
    st_lva => [qw(row_id data_calc id_stazione data_lva correlato valore id_log attuale validita)],
    st_lvan => [qw(row_id data_calc id_stazione data_lvan correlato valore id_log attuale validita)],
);

sub validate_target ($self, $airport, $database) {
    my $iata = $IATA{$airport // ''};
    ScriptManager::Exception->throw('invalid_airport', 'Aeroporto non valido') unless defined $iata;
    ScriptManager::Exception->throw('invalid_database', 'Database non associato all aeroporto selezionato')
        unless defined $database && $database =~ /\A\Q$iata\E_[0-9]{4}_bruma\z/i;
    return;
}

sub databases ($self, $airport) {
    my $iata = $IATA{$airport // ''};
    ScriptManager::Exception->throw('invalid_airport', 'Aeroporto non valido') unless defined $iata;
    my $db = $self->eventi->connect('anagrafica');
    my $rows = $db->selectall_arrayref('SELECT SCHEMA_NAME FROM information_schema.SCHEMATA', {Slice => {}});
    $db->disconnect;
    return [sort grep { /\A\Q$iata\E_[0-9]{4}_bruma\z/i } map { $_->{SCHEMA_NAME} } @$rows];
}

sub schema ($self, $db, $database) {
    my (@missing, @errors);
    for my $table (sort keys %REFERENCES) {
        my $reference = $REFERENCES{$table};
        my $reference_columns = $db->selectall_arrayref(
            'SELECT COLUMN_NAME, COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?',
            {Slice => {}}, $reference, $table);
        my %reference_columns = map { lc($_->{COLUMN_NAME}) => lc($_->{COLUMN_TYPE}) } @$reference_columns;
        my $columns = $db->selectall_arrayref(
            'SELECT COLUMN_NAME, COLUMN_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?',
            {Slice => {}}, $database, $table);
        for my $name (@{$COLUMNS{$table}}) {
            push @errors, "Riferimento $reference.$table non disponibile o incompleto"
                unless exists $reference_columns{lc $name};
        }
        unless (@$columns) {
            push @missing, $table;
            next;
        }
        my %columns = map { lc($_->{COLUMN_NAME}) => lc($_->{COLUMN_TYPE}) } @$columns;
        for my $name (@{$COLUMNS{$table}}) {
            next unless exists $reference_columns{lc $name};
            push @errors, "Colonna $table.$name mancante o incompatibile con $reference"
                unless exists $columns{lc $name} && $columns{lc $name} eq $reference_columns{lc $name};
        }
    }
    return {missing => \@missing, errors => \@errors};
}

sub preview ($self, $airport, $database) {
    $self->validate_target($airport, $database);
    my $db = $self->eventi->connect($database);
    my $schema = $self->schema($db, $database);
    my $stations = $self->eventi->stations($db, $airport);
    $db->disconnect;
    my @stations = grep { defined $_->{aeroporto} && $_->{aeroporto} eq $airport } @$stations;
    my $server = join ':', lc($ENV{MYSQL_HOST}), 0 + ($ENV{MYSQL_PORT} // 3306), '';
    my $defaults = $self->repo->correlation_defaults($airport, $server);
    for my $station (@stations) {
        $station->{defaults} = $defaults->{$station->{row_id} . ':' . ($station->{c_cab} // '')}
            // {shift => 1, mti => -90, mta => 100, mdi => 5000};
    }
    return {schema => $schema, stations => \@stations};
}

sub prepare ($self, $airport, $database, $confirmed) {
    $self->validate_target($airport, $database);
    my $db = $self->eventi->connect($database);
    my $target = join ':', lc($ENV{MYSQL_HOST}), 0 + ($ENV{MYSQL_PORT} // 3306), $database;
    my $guard = $self->repo->lock_database_for_schema($target);
    ScriptManager::Exception->throw('database_busy',
        'Database occupato o con esecuzioni in coda: riprovare al termine')
        unless $guard;
    my $schema = $self->schema($db, $database);
    ScriptManager::Exception->throw('mysql_schema', join('; ', @{$schema->{errors}})) if @{$schema->{errors}};
    my @expected = sort @$confirmed;
    ScriptManager::Exception->throw('mysql_schema_changed', 'Tabelle mancanti cambiate: verificare nuovamente')
        unless @expected && join(',', @expected) eq join(',', @{$schema->{missing}});
    for my $table (@expected) {
        my $target = $db->quote_identifier($database, $table);
        my $reference = $db->quote_identifier($REFERENCES{$table}, $table);
        $db->do("CREATE TABLE $target LIKE $reference");
    }
    $db->disconnect;
    return;
}

sub form_input ($self, $form) {
    my @stations;
    for my $value (@{$form->every_param('selected_station')}) {
        my ($id, $code) = ($value // '') =~ /\A([1-9]\d*):(\d+)\z/;
        if (!defined $id) {
            push @stations, $value;
            next;
        }
        push @stations, join ':', $id, $code, map { $form->param("${_}_$id") // '' } qw(shift mti mta mdi);
    }
    return {
        map({ $_ => scalar $form->param($_) } qw(airport database date_from date_to)),
        stations => \@stations,
        confirm_parameters => ($form->param('confirm_parameters') // '') eq '1' ? Mojo::JSON::true : Mojo::JSON::false,
        confirm_replacement => ($form->param('confirm_replacement') // '') eq '1' ? Mojo::JSON::true : Mojo::JSON::false,
    };
}

1;
