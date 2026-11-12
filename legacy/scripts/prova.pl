use DBI;
print "INSERIRE L'INDIRIZZO DELLA MACCHINA SU CUI RISIEDE IL DB (localhost se vuoto): ";
$IP=<STDIN>;
chomp($IP);
if ($IP eq '')
{$IP='localhost';}
 
print "INSERIRE IL NOME DEL DATABASE: ";
$database=<STDIN>;
chomp($database);

print "INSERIRE LA SIGLA DELL'AEROPORTO: ";
$aeroporto=<STDIN>;
chomp($aeroporto);
$aeroporto = uc $aeroporto;

print "INSERIRE IL NOME UTENTE: ";
$nome_utente=<STDIN>;
chomp($nome_utente);

print "INSERIRE LA PASSWORD (VISUALIZZATA IN CHIARO!): ";
$password=<STDIN>;
chomp($password);
$db_mxp = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) ||  
die "\n\n\n  -- FATAL ERROR :  Non mi posso connettere al database:$DBI::errstr\n\n\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

################# FILE DI LOG ##########################################################

$nomefileOUT = "report_normalizza_quote_10";
open(FILEOUTPUT,'>',$nomefileOUT);

	
$sel_press = "SELECT pressione_hpa,temperatura_C FROM meteo_cgp WHERE data_ora between '2003-10-15 08:15:00' AND '2003-10-15 08:45:00'";
$selPrh = $db_mxp->prepare($sel_press) || die "Can't prepare $statement: $db_radar->errstr\n";
$rv1 = $selPrh->execute || die "can't execute the query: $selPrh->errstr";
if ($rv1 == 0)
{
	print "$fl_id: non ci sono dati di pressione il $data\n";
	
}
	

@row2 = $selPrh->fetchrow_array;
$P_arp = $row2[0];
print "trovate righe $rv1\n";
print "pressione = $P_arp\n";
if (!$P_arp)
{
	print "$fl_id: il dato di pressione  non e' valido\n";
	
}
