###############################################################################################
#
# Title:	normalizza quote
# Author:	Bartolomeo Telaro
# Date:		perso nella notte dei tempo
# Revision: 	2020-09-07	Roberta Pollini inserita centralina Ferno al posto di Lonate
#		
# Comment:	Analizza tutte le tracce con validation_bt = 2, cioè su cui hanno girato 
#		correttamente tutti gli script di validazione  quello di rettifica delle quote
#		cerca il dato meteo corrispondente alla traccia e se le trova coregge l' altezza
#
# Table usate:		flay, battute, meteo
#
###############################################################################################

use DBI; #Carica in memoria il modulo DBI.

###########  costanti ##################################################################
$P0 = 1013.25;
$T0 = 288.15;
$GdivR0T = 5.2525;
$gamma = 0.0065;
$Z_LIMC_cgp = 216.5;
$Z_LIMC_lonate = 205;
$Z_LIMC_ferno = 215;
$Z_LIML_juvara = 122;   # altezza centralina juvara;
$Z_LIME_trezzo = 187;

$frequenza_LIMC_cgp = 30;
$frequenza_LIMC_lonate = 60;
$frequenza_LIMC_ferno = 60;
$frequenza_LIML_juvara = 60;
$frequenza_LIME_trezzo = 60;

$battute_normalizzate =  0;
#####################  IMPUT UTENTE #####################################################

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

if ($aeroporto eq 'LIMC')
{
	print "CHE CENTRALINA STAI CARICANDO:?\n";
	print "CGP\t1\n";
	print "Ferno\t2\n";
	$centralina = <STDIN>;
	chomp $centralina;
	if ($centralina == 1)
	{
		$table_meteo = 'meteo_cgp';
		$Zcentralina = $Z_LIMC_cgp;
		$freq_dato_meteo = $frequenza_LIMC_cgp 
	}
	elsif ($centralina == 2)
	{
		$table_meteo = 'meteo';
		$Zcentralina = $Z_LIMC_ferno;
		$freq_dato_meteo = $frequenza_LIMC_ferno;
	}
	else
		{die print "Non hai digitato correttamente il numero della centralina\n";}
}
elsif ($aeroporto eq 'LIML')
{
	$table_meteo = 'meteo';
	$Zcentralina = $Z_LIML_juvara;
	$freq_dato_meteo = $frequenza_LIML_juvara;
}
elsif ($aeroporto eq 'LIME')
{
	$table_meteo = 'meteo';
	$Zcentralina = $Z_LIME_trezzo;
	$freq_dato_meteo = $frequenza_LIME_trezzo;
}

else
	{die print "Ma che cavolo di aeroporto hai scelto TALOTA!!\n";}

$db_mxp = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) ||  
die "\n\n\n  -- FATAL ERROR :  Non mi posso connettere al database:$DBI::errstr\n\n\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

################# FILE DI LOG ##########################################################
@data_ora=localtime(time);
$data_ora[4]=$data_ora[4]+1;
$data_ora[5]=$data_ora[5]+1900;

$nomefileOUT = "report\\10-correggi_quote-normalizza_quote_nulle\_$database\_$nome_utente\_$data_ora[3]-$data_ora[4]-$data_ora[5]\_$data_ora[2]-$data_ora[1]-$data_ora[0].log";
open(FILEOUTPUT,'>>',$nomefileOUT);
print "\n\n**** NORMALIZZA QUOTE *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n";
print (FILEOUTPUT "***** NORMALIZZA QUOTE *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n");
############### Selezione le traccie valide##############################################

$sel_traccia = "SELECT row_id,data_ora_arr,flay_operation FROM flay WHERE validation_bt = 2";
$selTh = $db_mxp->prepare($sel_traccia);
$errDB1 = $db_mxp->errstr;
if (!$selTh) {die "Can't prepare $selTh: $errDB1\n";}
$rv = $selTh->execute;
$errTH1 = $selTh->errstr;
if (!$rv) {die "can't execute the query: $errTH1";}
$rv == 0 && die "\n non ci sono tracce  validate \n ";

$up_flay = "UPDATE FLAY SET validation_bt = 3  WHERE row_id = ?";
$up_flay_h = $db_mxp->prepare($up_flay) || die "Can't prepare $statement: $db_radar->errstr\n";

$up_battute = "UPDATE battute SET A_m = ? WHERE row_id = ?";
$upBh = $db_mxp->prepare($up_battute) || die "Can't prepare $statement: $db_radar->errstr\n";

##########################################################################
##########################################################################
##### 	INIZIO CICLO PRINCIPALE: SCORRE LE BATTUTE DI CIASCUNA TRACCIA ###
##########################################################################
##########################################################################

while(@row_T = $selTh->fetchrow_array)
{
	$fl_id = $row_T[0];
	$data = $row_T[1];
	$operazione = $row_T[2];
	print "FLAY_ID = $fl_id \t"; #$data --$operazione\n";
	
	##########  selezione la pressione misurata dalla centralina di rilevamento all' ora e data della prima battuta della traccia
	
	$sel_press = "SELECT pressione_hpa,temperatura_C FROM $table_meteo WHERE data_ora between '$data' AND DATE_ADD('$data',INTERVAL +$freq_dato_meteo MINUTE) AND pressione_hpa IS NOT NULL AND temperatura_C IS NOT NULL";
	$selPrh = $db_mxp->prepare($sel_press) || die "Can't prepare $statement: $db_radar->errstr\n";
	$rv1 = $selPrh->execute || die "can't execute the query: $selPrh->errstr";
	if ($rv1 == 0)
	{
		print (FILEOUTPUT "$fl_id: non ci sono dati di pressione il $data\n");
		next;
	}
	@row2 = $selPrh->fetchrow_array;
	$P_arp = $row2[0];
	$T_arp = $row2[1];
	$T_arp += 273.15;    #trasformo in farenaith	
	if (!$P_arp || $P_arp == 0)
	{
		print (FILEOUTPUT "$fl_id: il dato di pressione il $data alle $ora non e' valido\n");
		print "$fl_id: il dato di pressione il $data alle $ora non e' valido\n";
		next;
	}
        ###### Selezione tutte le altezze delle varie battute della traccia e ricalcola l' altezza reale
        
	$sel_batt = "SELECT row_id,Z_m FROM battute WHERE flay_id = '$fl_id' AND validation != 'N' and validation != 'A' and Z_m is not null and A_m is null";
	$selBh = $db_mxp->prepare($sel_batt) || die "Can't prepare $statement: $db_radar->errstr\n";
	$rv1 = $selBh->execute || die "can't execute the query: $selBh->errstr";
	$rv1 == 0 && print "\n non ci sono battute associate alla traccia $fl_id \n";
	
	while (@row3 = $selBh->fetchrow_array)
	{
		$row_Id_Batt = @row3[0]; 
		$Z_st = @row3[1];
		$P_aereo = $P0*(1-($Z_st*$gamma)/$T0)**$GdivR0T;
		#print "batt:$row_Id_Batt - Zst: $Z_st - Paereo: $P_aereo - Zreale: $Z_real\n";
		#print "GAMMA = $gamma\nP_ARO = $P_arp\nGDVIROT = $GdivR0T\nTO = $T0\n";
		$Z_real  = $Zcentralina + ($T_arp/$gamma)*(1-($P_aereo/$P_arp)**(1/$GdivR0T));
		$rv = $upBh->execute($Z_real,$row_Id_Batt) || die "can't execute the query: $upTh->errstr";
	}
	$rv = $up_flay_h->execute($fl_id) || die "can't execute the query: $up_flay_h->errstr";
	$battute_normalizzate++;
}

print "sono state modificate $battute_normalizzate quote\n";
print (FILEOUTPUT "sono state modificate $battute_normalizzate quote\n");

@data_oraE=localtime(time);
$data_oraE[4]=$data_oraE[4]+1;
$data_oraE[5]=$data_oraE[5]+1900;
$secondidelta = (3600*$data_oraE[2] + 60*$data_oraE[1] + $data_oraE[0])-(3600*$data_ora[2] + 60*$data_ora[1] + $data_ora[0]);
print (FILEOUTPUT "$data_oraE[3]/$data_oraE[4]/$data_oraE[5]\t$data_oraE[2]:$data_oraE[1]:$data_oraE[0]\n***** RETTIFICA QUOTE NULLE FINE*****\n");
print (FILEOUTPUT "secondi trascorsi =  $secondidelta\n");
print "secondi trascorsi $secondidelta\n";
close (FILEOUTPUT);
