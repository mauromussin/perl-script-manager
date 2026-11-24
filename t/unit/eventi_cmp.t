use Mojo::Base -strict, -signatures;
use Test::More;
use File::Temp 'tempdir';
use Mojo::File 'path';
use ScriptManager::Exception;
use ScriptManager::Service::EventiCMP;

my $root = path(tempdir(CLEANUP => 1));
local $ENV{SCRIPT_MANAGER_TXT_ROOT} = "$root";
my $service = ScriptManager::Service::EventiCMP->new;
my $header = 'Time (s);Duration (s);Durata (-10) (s);Contatore (n);Leq (dB);Leq (-10) (dB);SEL (dB);SEL (-10) (dB);LMax (dB);Simmetria (%)';
my $dir = $root->child('nested')->make_path;
my $file = $dir->child('eventi.txt');
$file->spew("Titolo\n$header\n2025-05-25 11:55:44;45.2;43;1;69.9;70.1;86.5;86.4;74.3;34\n");
my $files = $service->files;
is scalar(@$files), 1, 'scansione ricorsiva';
is $files->[0]{name}, 'nested/eventi.txt', 'percorso relativo';
is_deeply $service->read_events($files->[0]{name}, $files->[0]{sha256}),
    [['2025-05-25 11:55:44', 45, 69.9, 70.1, 86.5, 86.4, 74.3]], 'ora locale e colonne correttamente mappate';

my $old_hash = $files->[0]{sha256};
$file->spew("Titolo\n01/01/2025\n00:00:00\n$header\n10;45;43;1;69.9;70.1;86.5;86.4;74.3;34\n");
eval { $service->read_events('nested/eventi.txt', $old_hash) };
ok(ScriptManager::Exception->caught($@, 'txt_changed'), 'file modificato rifiutato');
$files = $service->files;
is_deeply $service->read_events($files->[0]{name}, $files->[0]{sha256}),
    [['2025-01-01 00:00:10', 45, 69.9, 70.1, 86.5, 86.4, 74.3]], 'formato legacy accettato';

$file->spew("Titolo\n30/03/2025\n03:00:00\n$header\n0;45;43;1;69.9;70.1;86.5;86.4;74.3;34\n");
$files = $service->files;
is $service->read_events($files->[0]{name}, $files->[0]{sha256})->[0][0],
    '2025-03-30 04:00:00', 'formato a secondi preserva il calcolo legacy nel cambio ora';

for my $case (
    ["Titolo\n$header\n2025-02-30 11:55:44;45;43;1;69.9;70.1;86.5;86.4;74.3;34\n", 'data inesistente'],
    ["Titolo\n$header\n2025-05-25 11:55:44;-0.1;43;1;69.9;70.1;86.5;86.4;74.3;34\n", 'durata negativa'],
    ["Titolo\n" . ($header =~ s/Leq \(dB\)/Wrong (dB)/r) . "\n2025-05-25 11:55:44;45;43;1;69.9;70.1;86.5;86.4;74.3;34\n", 'intestazione errata'],
    ["Titolo\n$header\n2025-05-25 11:55:44;45;43;1;*;70.1;86.5;86.4;74.3;34\n", 'valore non numerico'],
) {
    $file->spew($case->[0]);
    $files = $service->files;
    eval { $service->read_events($files->[0]{name}, $files->[0]{sha256}) };
    ok(ScriptManager::Exception->caught($@, 'txt_format'), $case->[1] . ' bloccata');
}
eval { $service->read_events('../eventi.txt', 'x') };
ok(ScriptManager::Exception->caught($@, 'invalid_txt_file'), 'path traversal rifiutato');

done_testing;
