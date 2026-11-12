###############################################################################################
#
# Title:	carica dati meteo
# Author:	bartolomeo telaro
# Date:		perso nella notte dei tempo
# Revision: 	2020-09-07	Roberta Pollini(meteo ferno non più lonate)
#				2021_04_06  R.Pollini aggiunto Montichiari 'LIPO'
#
#		
# Comment:	carica i dati meteo nelle tabella meteo (o meteo_cgp, meteo_ferno, meteo_somma)
#		ferno OK !!!
#		SAN GIORGIO Ok !!!
#		
#
# Table usate:	meteo
#
###############################################################################################

use DBI; #Carica in memoria il modulo DBI.

###########  costanti e variabili  ############################################################

$righeInt = 0;
$separatoreCampo = ';';
$centralina = 'nomecentralina';

#####################  IMPUT UTENTE ###########################################################

################# FILE DI LOG ##########################################################
@data_ora=localtime(time);
$data_ora[4]=$data_ora[4]+1;
$data_ora[5]=$data_ora[5]+1900;

$nomefileOUT = "report\\09-carica_dati_mete-$database\_$nome_utente\_$data_ora[3]-$data_ora[4]-$data_ora[5]\_$data_ora[2]-$data_ora[1]-$data_ora[0].log";
open(FILEOUTPUT,'>>',$nomefileOUT);
print "\n\n**** CARICA DATI METEO *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n";
print (FILEOUTPUT "***** CARICA DATI METEO *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n");
############### Selezione le traccie valide##############################################

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
$separatoreCampo = <STDIN>;
chomp ($separatoreCampo);

if ($aeroporto eq 'LIMC')
{
	print "CHE CENTRALINA STAI CARICANDO:?\n";
	print "CGP\t1\n";
	print "Ferno\t2\n";
	print "Somma\t3\n";
	$centralina = <STDIN>;
	chomp $centralina;
	if ($centralina == 1)
		{$table_meteo = 'meteo_cgp';}
	elsif ($centralina == 2)
		{$table_meteo = 'meteo';}
	elsif ($centralina == 3)
		{$table_meteo = 'meteo';}
	else
		{die print "Non hai digitato correttamente il numero della centralina\n";}
}
elsif ($aeroporto eq 'LIML' || $aeroporto eq 'LIME' || $aeroporto eq 'LIPO')
{
	$table_meteo = 'meteo'
}
else
	{die print "Ma che cavolo di aeroporto hai scelto TALOTA!!\n";}

#########################################################################

$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) ||  
die "\n\n\n  -- FATAL ERROR :  Non mi posso connettere al database:$DBI::errstr\n\n\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";
##########################################################################

$InsMeteo = $db_radar->prepare(qq{INSERT INTO $table_meteo (data_ora,precipitazione_mm,temperatura_C,direzione_vento1,direzione_vento2,velocita_vento, umidita_relativa, radiazione_netta, radiazione_globale, pressione_hpa) VALUES(?,?,?,?,?,?,?,?,?,?) });

##########################################################################


open(FILEINPUT,$nomefile);
print "ANALIZZO IL FILE $nomefile \n\n";
$j =1;
while (!eof(FILEINPUT))
{
	$riga = <FILEINPUT>;
		chomp $riga;
	$riga =~  s/ //g;  ################  elimina tutti gli spazi dalla riga del file
		if ($j > $righeInt) ########## salto le righe di intestazione
	{
		my $v = 0;
		@VALORI = split($separatoreCampo,$riga);
				foreach (@VALORI)
		{
			$VALORI[$v] =~  s/\,/\./g;	  ######### sostituisce in tutti i campi la virgola con il punto
			$v++;
		}
		print "\n VALO22 = @VALORI \n";
		print "@VALORI\n";
		my @valori2DB = &convertiStringa($aeroporto,$centralina,@VALORI);
		
		$rv = $InsMeteo->execute(@valori2DB);
		$errore =$InsMeteo->errstr;
		if (!$rv) {print "can't execute the query: $errore\n";}
		#print "inserita riga $j++\n";
	}
	$j++
}
print "inserite $j\n";
sub convertiData
{
	my (@dataIn,$giorno,$year,$mese,$ora,$dataOut);
	@dataIn = split ('/', $_[0] );
	$giorno  = $dataIn[0];
	$mese = $dataIn[1];
	$year = $dataIn[2];
	$ora = $_[1];
	if ($_[1] eq '24:00:00') {$ora = '23:59:59'; } 
	$dataOut = "$year-$mese-$giorno $ora";
		return $dataOut;
}


sub convertiStringa
{
	my @valori2DB;
	$valori2DB[0] = undef;		# data_ora
	$valori2DB[1] = undef;		# precipitazione_mm
	$valori2DB[2] = undef;	    #temperatura_°C
	$valori2DB[3] = undef;      #dir_vento1
	$valori2DB[4] = undef;      #dir_vento2
	$valori2DB[5] = undef;      #vel_vento
	$valori2DB[6] = undef;      #umidità_relat
	$valori2DB[7] = undef;      #radiaz_netta
	$valori2DB[8] = undef;      #radiaz_globale
	$valori2DB[9] = undef;      #pressione hPa
	my $aeroporto = $_[0];
	my $centralina = $_[1];
	
	if ($aeroporto eq 'LIMC' && $centralina == 1)
	{
		
		### data_ora
		$valori2DB[0] = &convertiData($_[2],$_[3]);

		### precipitazione_mm
		if ($_[5] ne '*' && $_[5] ne '') 
		{$valori2DB[1] = $_[5];}
		
		### temperatura_C
		if ($_[4] ne '*' && $_[4] ne '') 
		{$valori2DB[2] = $_[4];}
		
		### pressione_hpa
		if ($_[7] ne '*' && $_[7] ne '') 
		{$valori2DB[9] = 1.3332*$_[7];}
	
		### velocita_vento
		if ($_[9] ne '*' && $_[9] ne '') 
		{$valori2DB[5] = $_[9];}
		
		###v direzione_vento1
		if ($_[10] ne '*' && $_[10] ne '') 
		{$valori2DB[3] = $_[10];}
	}
	elsif($aeroporto eq 'LIML')
	{
		### data_oara
		$valori2DB[0] = &convertiData($_[2],$_[3]);
		
		### precipitazione_mm
		if ($_[4] ne '*' && $_[4] ne '') 
		{$valori2DB[1] = $_[4];}

		### temperatura_C
		if ($_[5] ne '*' && $_[5] ne '') 
		{$valori2DB[2] = $_[5];}
		
		###v direzione_vento1
		if ($_[6] ne '*' && $_[6] ne '') 
		{$valori2DB[3] = $_[6];}
		
		###v direzione_vento2
		if ($_[7] ne '*' && $_[7] ne '') 
		{$valori2DB[4] = $_[7];}
		
		### velocita_vento
		if ($_[8] ne '*' && $_[8] ne '') 
		{$valori2DB[5] = $_[8];}

		### UMIDITA RELATIVA
		if ($_[9] ne '*' && $_[9] ne '') 
		{$valori2DB[6] = $_[9];}
	
		### RADIAZIONE GLOBALE
		if ($_[11] ne '*' && $_[11] ne '') 
		{$valori2DB[8] = $_[11];}

		### RADIAZIONE NETTA
		if ($_[10] ne '*' && $_[10] ne '') 
		{$valori2DB[7] = $_[10];}
		
		### pressione_hpa
		if ($_[12] ne '*' && $_[12] ne '') 
		{$valori2DB[9] = $_[12];}
	}
	elsif($aeroporto eq 'LIME' || ($aeroporto eq 'LIMC' && $centralina == 2) || $aeroporto eq 'LIPO')   
	{
		### data_ora
		$valori2DB[0] = &convertiData($_[2],$_[3]);
		
		### precipitazione_mm
		if ($_[4] ne '*' && $_[4] ne '') 
		{$valori2DB[1] = $_[4];}

		### temperatura_C
		if ($_[5] ne '*' && $_[5] ne '') 
		{$valori2DB[2] = $_[5];}
		
		###v direzione_vento1
		if ($_[6] ne '*' && $_[6] ne '') 
		{$valori2DB[3] = $_[6];}
		
		###v direzione_vento2
		if ($_[7] ne '*' && $_[7] ne '') 
		{$valori2DB[4] = $_[7];}
		#
		### velocita_vento
		if ($_[8] ne '*' && $_[8] ne '') 
		{$valori2DB[5] = $_[8];}

		### UMIDITA RELATIVA
		if ($_[9] ne '*' && $_[9] ne '') 
		{$valori2DB[6] = $_[9];}
	
		### RADIAZIONE NETTA
		if ($_[10] ne '*' && $_[10] ne '') 
		{$valori2DB[7] = $_[10];}
		
		### RADIAZIONE GLOBALE
		if ($_[11] ne '*' && $_[11] ne '') 
		{$valori2DB[8] = $_[11];}

		### pressione_hpa
		if ($_[12] ne '*' && $_[12] ne '') 
		{$valori2DB[9] = $_[12];}
	}
	elsif($aeroporto eq 'LIMC' && $centralina == 3)   ######### centralina di somma lombardo  NB non ha la pressione
	{
		### data_oara
		$valori2DB[0] = &convertiData($_[2],$_[3]);

		### precipitazione_mm
		if ($_[4] ne '*' && $_[4] ne '') 
		{$valori2DB[1] = $_[4];}

		### temperatura_C
		if ($_[5] ne '*' && $_[5] ne '') 
		{$valori2DB[2] = $_[5];}

		###v direzione_vento1
		if ($_[6] ne '*' && $_[6] ne '') 
		{$valori2DB[3] = $_[6];}

		###v direzione_vento2
		if ($_[7] ne '*' && $_[7] ne '') 
		{$valori2DB[4] = $_[7];}

		### velocita_vento
		if ($_[8] ne '*' && $_[8] ne '') 
		{$valori2DB[5] = $_[8];}

		### UMIDITA RELATIVA
		if ($_[9] ne '*' && $_[9] ne '') 
		{$valori2DB[6] = $_[9];}

		### RADIAZIONE NETTA
		if ($_[10] ne '*' && $_[10] ne '') 
		{$valori2DB[7] = $_[10];}

		### RADIAZIONE GLOBALE
		if ($_[11] ne '*' && $_[11] ne '') 
		{$valori2DB[8] = $_[11];}
	}
	return @valori2DB;
}
