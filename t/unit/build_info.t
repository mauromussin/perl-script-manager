use Mojo::Base -strict, -signatures;
use Test::More;
use File::Temp 'tempdir';
use Mojo::File 'path';
use Mojo::Util 'encode';
use ScriptManager;

my $dir = path(tempdir(CLEANUP => 1));
is_deeply ScriptManager::_build_info($dir), {}, 'missing metadata is not inferred from the host';
$dir->child('commit')->spew("abc123\n");
$dir->child('message')->spew(encode('UTF-8', "Correzione \x{e8}\n\nDettagli\n"));
is_deeply ScriptManager::_build_info($dir),
    {commit => 'abc123', message => "Correzione \x{e8}\n\nDettagli"},
    'commit and complete UTF-8 message are read from the image';
$dir->child('message')->spew('');
is_deeply ScriptManager::_build_info($dir), {commit => 'abc123'}, 'empty metadata is unavailable';

done_testing;
