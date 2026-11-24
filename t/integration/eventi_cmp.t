use Mojo::Base -strict, -signatures;
use Test::More;
use DBI;
use File::Temp 'tempdir';
use Mojo::File 'path';
use ScriptManager::Command::CaricaEventiCMP;
use ScriptManager::Exception;

plan skip_all => 'Richiede un server MySQL isolato dedicato al test'
    unless ($ENV{TEST_EVENTI_ISOLATED_MYSQL} // '') eq '1';

{
    package EventiTestContext;
    use Mojo::Base -base, -signatures;
    has logs => sub { [] };
    sub log ($self, @args) { push @{$self->logs}, \@args }
    sub progress ($self, @args) { }
    sub check_cancel ($self) { }
}

my $dsn = 'DBI:MariaDB:host=' . ($ENV{MYSQL_HOST} // '') . ';port=' . ($ENV{MYSQL_PORT} // 3306);
my $db = DBI->connect($dsn, $ENV{MYSQL_USER}, $ENV{MYSQL_PASSWORD}, {RaiseError => 1, PrintError => 0});
my $schema = sprintf 'sm_eventi_test_%d_%d', $$, int rand 1_000_000;
my ($created_anagrafica, $created_schema) = (0, 0);
END {
    if ($db) {
        $db->do('DROP DATABASE ' . $db->quote_identifier($schema)) if $created_schema;
        $db->do('DROP DATABASE anagrafica') if $created_anagrafica;
        $db->disconnect;
    }
}
die "Il test richiede un server isolato senza database anagrafica\n"
    if $db->selectrow_array('SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = ?', undef, 'anagrafica');
$db->do('CREATE DATABASE anagrafica');
$created_anagrafica = 1;
$db->do('CREATE DATABASE ' . $db->quote_identifier($schema));
$created_schema = 1;
$db->do('CREATE TABLE anagrafica.aeroporti (row_id INT PRIMARY KEY, nome_aerop VARCHAR(4))');
$db->do('CREATE TABLE anagrafica.stazioni (row_id INT PRIMARY KEY, aeroporti_id INT, c_cab INT, name VARCHAR(25))');
$db->do("INSERT INTO anagrafica.aeroporti VALUES (1,'LIMC'),(2,'LIML')");
$db->do("INSERT INTO anagrafica.stazioni VALUES (1,1,227,'Stazione A'),(2,2,228,'Stazione B'),(3,NULL,229,'Non associata')");
$db->do('USE ' . $db->quote_identifier($schema));

my $dir = path(tempdir(CLEANUP => 1));
local $ENV{SCRIPT_MANAGER_TXT_ROOT} = "$dir";
my $header = 'Time (s);Duration (s);Durata (-10) (s);Contatore (n);Leq (dB);Leq (-10) (dB);SEL (dB);SEL (-10) (dB);LMax (dB);Simmetria (%)';
my $file = $dir->child('a.txt');
$file->spew("Titolo\n$header\n"
    . "2025-05-25 11:55:44;45;43;1;69.9;70.1;86.5;86.4;74.3;34\n"
    . "2025-05-25 11:55:44;45;43;2;69.9;71.1;87.5;87.4;75.3;34\n");
my $command = ScriptManager::Command::CaricaEventiCMP->new;
my $files = $command->eventi->files;
my $params = {database => $schema, airport => 'LIMC', files => [$files->[0]{name}],
    hashes => [$files->[0]{sha256}], stations => ['1:227']};

my $stations = $command->eventi->stations($db, 'LIMC');
is_deeply [sort map { $_->{row_id} } @$stations], [1, 3], 'solo aeroporto scelto e stazioni senza aeroporto';

for my $unique (1, 0) {
    $db->do('DROP TABLE IF EXISTS st_eventi_cmp');
    $db->do('CREATE TABLE st_eventi_cmp (row_id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, '
        . 'id_centralina_cmp INT NOT NULL, Data_ora DATETIME NOT NULL, Durata INT NOT NULL, '
        . 'Leq DOUBLE NOT NULL, Leq_10 DOUBLE, Sel DOUBLE, Sel_10 DOUBLE, LMax DOUBLE, Correlato TINYINT'
        . ($unique ? ', UNIQUE KEY EVENTI (id_centralina_cmp, Data_ora, Durata, Leq)' : '')
        . ') ENGINE=MyISAM');
    my $ctx = EventiTestContext->new;
    my $result = $command->run($ctx, $params);
    like $result->{message}, qr/inseriti: 1; duplicati ignorati: 1/, "duplicati saltati (indice=$unique)";
    is $db->selectrow_array('SELECT COUNT(*) FROM st_eventi_cmp'), 1, 'una sola riga inserita';
    my $row = $db->selectrow_arrayref('SELECT id_centralina_cmp, Data_ora, Durata, Leq, Leq_10 FROM st_eventi_cmp');
    is_deeply $row, [227, '2025-05-25 11:55:44', 45, 69.9, 70.1], 'salva c_cab, non row_id, e conserva la prima occorrenza';
    $result = $command->run($ctx, $params);
    like $result->{message}, qr/inseriti: 0; duplicati ignorati: 2/, 'riesecuzione idempotente';
    is $db->selectrow_array('SELECT COUNT(*) FROM st_eventi_cmp'), 1, 'nessun duplicato dopo riesecuzione';

    eval { $command->run($ctx, {%$params, stations => ['2:228']}) };
    ok(ScriptManager::Exception->caught($@, 'invalid_associations'), 'altra localita rifiutata');
    $file->spew($file->slurp . "\n");
    eval { $command->run($ctx, $params) };
    ok(ScriptManager::Exception->caught($@, 'txt_changed'), 'cambio del file rifiutato prima delle scritture');
    is $db->selectrow_array('SELECT COUNT(*) FROM st_eventi_cmp'), 1, 'nessuna scrittura dopo errore';
    $files = $command->eventi->files;
    $params->{hashes} = [$files->[0]{sha256}];
}

my $second = $dir->child('b.txt');
$second->spew("Titolo\n$header\n2025-02-30 11:55:44;45;43;1;69.9;70.1;86.5;86.4;74.3;34\n");
$files = $command->eventi->files;
my $both = {database => $schema, airport => 'LIMC',
    files => [map { $_->{name} } @$files], hashes => [map { $_->{sha256} } @$files], stations => ['1:227', '3:229']};
eval { $command->run(EventiTestContext->new, $both) };
ok(ScriptManager::Exception->caught($@, 'txt_format'), 'secondo file invalido blocca tutte le scritture');
is $db->selectrow_array('SELECT COUNT(*) FROM st_eventi_cmp'), 1, 'nessuna scrittura prima della verifica completa';
$second->spew("Titolo\n$header\n2025-05-25 11:55:44;45;43;1;69.9;70.1;86.5;86.4;74.3;34\n");
$files = $command->eventi->files;
$both->{hashes} = [map { $_->{sha256} } @$files];
my $result = $command->run(EventiTestContext->new, $both);
like $result->{message}, qr/inseriti: 1; duplicati ignorati: 2/, 'importa tutti i file con associazioni distinte';
is $db->selectrow_array('SELECT COUNT(*) FROM st_eventi_cmp WHERE id_centralina_cmp = 229'), 1,
    'evento importato con c_cab della stazione senza aeroporto';
$db->do('UPDATE anagrafica.stazioni SET c_cab=225 WHERE row_id=1');
eval { $command->run(EventiTestContext->new, $both) };
ok(ScriptManager::Exception->caught($@, 'invalid_associations'), 'codice c_cab modificato dopo la scelta rifiutato');
$db->do('UPDATE anagrafica.stazioni SET c_cab=227 WHERE row_id=1');
$db->do("INSERT INTO anagrafica.stazioni VALUES (4,1,227,'Codice duplicato')");
eval { $command->run(EventiTestContext->new, $both) };
ok(ScriptManager::Exception->caught($@, 'invalid_associations'), 'codice c_cab ambiguo rifiutato');
is $db->selectrow_array('SELECT COUNT(*) FROM st_eventi_cmp'), 2, 'nessuna scrittura con codice ambiguo';

done_testing;
