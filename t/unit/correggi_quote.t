use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use Mojo::File 'path';
use ScriptManager::Command::CorreggiQuote;

my $source = path($FindBin::Bin, '..', '..', 'legacy', 'scripts',
    '10-correggi_quote_1.0+lipo.pl')->slurp;
$source =~ s/\r\n/\n/g;
$source =~ /^(\s*\$P_aereo = [^\n]+)/m or die 'Pressione ISA legacy non trovata';
my $pressure = $1;
$source =~ /^(\s*\$Z_real\s*= [^\n]+)/m or die 'Normalizzazione legacy non trovata';
my $height = $1;
my $legacy = eval 'sub {
    my ($Z_st, $P_arp, $temperature, $Zcentralina) = @_;
    my ($P0, $T0, $GdivR0T, $gamma) = (1013.25, 288.15, 5.2525, 0.0065);
    my ($P_aereo, $Z_real);
    my $T_arp = $temperature + 273.15;
    ' . $pressure . $height . '
    return $Z_real;
}';
die $@ unless $legacy;

subtest 'caratterizzazione della formula 10 originale' => sub {
    cmp_ok abs($legacy->(0, 1013.25, 15, 0)), '<', 0.000001, 'riferimento ISA al livello del mare';
    cmp_ok abs($legacy->(1000, 1013.25, 15, 0) - 1000), '<', 0.000001, 'ISA ricostruisce la quota standard';
    cmp_ok abs($legacy->(1000, 1013.25, 15, 233.782) - 1233.782), '<', 0.000001, 'quota della sorgente aggiunta';
    cmp_ok $legacy->(1000, 990, 5, 233.782), '<', $legacy->(1000, 1013.25, 5, 233.782),
        'pressione inferiore alla sorgente riduce la quota calcolata';
    cmp_ok $legacy->(0, 990, 5, 0), '<', 0, 'quote risultanti negative non troncate nel legacy';
};

subtest 'formula migrata identica con quota ARP, senza correzioni arbitrarie' => sub {
    for my $fixture ([0, 1013.25, 15, 0], [1000, 990, 5, 233.782],
        [1000, 1013.25, 15, 107.594], [2000, 1000, -5, 229.439], [0, 990, 5, 108.509]) {
        cmp_ok abs(ScriptManager::Command::CorreggiQuote->normalize(@$fixture) - $legacy->(@$fixture)), '<', 0.000001;
    }
    cmp_ok(ScriptManager::Command::CorreggiQuote->normalize(0, 990, 5, 0), '<', 0,
        'preserva risultati negativi fisicamente possibili');
};

subtest 'dati fuori dominio falliscono esplicitamente prima del salvataggio' => sub {
    for my $fixture ([undef, 990, 5, 100], ['NaN', 990, 5, 100], [1000, 0, 5, 100],
        [1000, 990, -273.15, 100], [45000, 990, 5, 100], [1000, 990, 5, undef]) {
        eval { ScriptManager::Command::CorreggiQuote->normalize(@$fixture) };
        ok(ScriptManager::Exception->caught($@, 'invalid_height'));
    }
};

done_testing;
