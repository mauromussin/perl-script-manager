###############################################################################################
#
# Title:	carica dati meteo
# Author:	bartolomeo telaro
# Date:		perso nella notte dei tempo
# Revision: 	2007-02-22	Bartolomeo Telaro
#
#		
# Comment:	carica i dati meteo nelle tabella meteo (o meteo_cgp, meteo_lonate, meteo_somma)
#		
#		
#
# Table usate:	meteo
#
###############################################################################################

use DBI; #Carica in memoria il modulo DBI.

###########  costanti e variabili  ############################################################

$righeInt = 0;
$separoreCampo = '';

#####################  IMPUT UTENTE ###########################################################

print "INSERIRE L'INDIRIZZO DELLA MACCHINA SU CUI RISIEDE IL DATABASE: ";
$IP=<STDIN>;
chomp($IP);
if ($IP eq '') {$IP='localhost';}

print "INSERIRE IL NOME DEL DATABASE: ";
$database = <STDIN>;
chomp($database);

print "INSERIRE IL NOME DELL' AEROPORTO CODICE (ICAO): ";
$aeroporto = <STDIN>;
chomp($aeroporto);
$aeroporto = uc $aeroporto;

print "INSERIRE IL CODICE DELLA CENTRALINA: ";
$id_centralina = <STDIN>;
chomp($id_centralina);

print "INSERIRE IL NOME UTENTE: ";
$nome_utente = <STDIN>;
chomp($nome_utente);

print "INSERIRE LA PASSWORD (VISUALIZZATA IN CHIARO!): ";
$password = <STDIN>;
chomp($password);

print "INSERIRE IL PERCORSO DELLA DIRECTORY DOVE SI TROVA IL FILE DA PROCESSARE: ";
$percorso = <STDIN>;
chomp($percorso);
$percorso = qq{$percorso};

print "INSERIRE IL NOME DEL FILE DA PROCESSARE: ";
$nomefile = <STDIN>;
$nomefile = qq{$nomefile};
print "$nomefile \n";
chomp($nomefile);
$nomefile = $percorso.'\\'.$nomefile;
print "FILE : $nomefile\n";

print "INSERIRE IL NUMERO DELLE RIGHE DI INTESTAZIONE: ";
$righeInt = <STDIN>;
chomp ($righeInt);

print "INSERIRE IL SEPARATORE DI ELENCO NB(non puo essere lo spazio): ";
$separoreCampo = <STDIN>;
chomp ($separoreCampo);

if ($aeroporto eq 'LIMC')
{
	
}
elsif ($aeroporto eq 'LIML' || $aeroporto eq 'LIME')
{

}
else
	{die print "Ma che cavolo di aeroporto hai scelto TALOTA!!\n";}

#########################################################################

$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) ||  
die "\n\n\n  -- FATAL ERROR :  Non mi posso connettere al database:$DBI::errstr\n\n\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";
##########################################################################

$InsEventi = $db_radar->prepare(qq{INSERT INTO st_eventi_cmp (id_centralina_cmp,data_ora,durata,Leq,Leq_10,Sel,Sel_10,Lmax) VALUES(?,?,?,?,?,?,?,?)});

##########################################################################

# controllo codice centralina

$rv = $db_radar->do("SELECT row_id FROM anagrafica.centraline_cmp WHERE row_id = $id_centralina");
if(!$rv)
{
	die "HAI INSERITO UN CODICE CENTRALINA INESISTENTE\n";
}


open(FILEINPUT,$nomefile);
print "ANALIZZO IL FILE $nomefile \n\n";
$j =1;
while (!eof(FILEINPUT))
{
	$riga = <FILEINPUT>;
	chomp $riga;
	$riga =~  s/ //g;  ################  eleimina tutti gli spazi dalla riga del file
	if ($j > $righeInt) ########## salto le righe di intestazione
	{
		my $v = 0;
		@VALORI = split($separoreCampo,$riga);
		foreach (@VALORI)
		{
			$VALORI[$v] =~  s/\,/\./g;	  ######### sostituisce in tutti i campi la virgola con il punto
			$v++;
		}
		
		print "@VALORI\n";
		my @valori2DB = &convertiStringa(@VALORI);
		
		$rv = $InsEventi->execute($id_centralina,@valori2DB);
		$errore = $InsEventi->errstr;
		if (!$rv) {print "can't execute the query: $errore\n";}
		#print "inserita riga $j++\n";
	}
	$j++
}
print "inserite $j\n";



################## FUNZIONI #####################

sub convertiData
{
	my (@dataIn,$giorno,$year,$mese,$ora,$dataOut);
	$data = substr($_[0],0,10);
	$ora = substr($_[0],10,8);
	
	@dataIn = split ('/', $data );
	$giorno  = $dataIn[0];
	$mese = $dataIn[1];
	$year = $dataIn[2];
	if ($_[1] eq '24:00:00') {$ora = '23:59:59';} 
	$dataOut = "$year-$mese-$giorno $ora";
	return $dataOut;
}

sub convertiStringa
{
	my @valori2DB;
	$valori2DB[0] = undef;		# data_ora
	$valori2DB[1] = undef;		# durata
	$valori2DB[2] = undef;	        # Leq
	$valori2DB[3] = undef;		# Leq-10
	$valori2DB[4] = undef;		# Sel
	$valori2DB[5] = undef;		# Sel-10
	$valori2DB[6] = undef;		# Lmax
	
	### data_oara
	$valori2DB[0] = &convertiData($_[0]);

	### durata
	if ($_[1] ne '*' && $_[1] ne '') 
	{$valori2DB[1] = $_[1];}

	### Leq
	if ($_[2] ne '*' && $_[2] ne '') 
	{$valori2DB[2] = $_[2];}

	### Leq-10
	if ($_[3] ne '*' && $_[3] ne '') 
	{$valori2DB[3] = $_[3];}

	### Sel
	if ($_[4] ne '*' && $_[4] ne '') 
	{$valori2DB[4] = $_[4];}

	### Sel-10
	if ($_[5] ne '*' && $_[5] ne '') 
	{$valori2DB[5] = $_[5];}
	
	### Lmax
	if ($_[6] ne '*' && $_[6] ne '') 
	{$valori2DB[6] = $_[6];}
	
	return @valori2DB;
}