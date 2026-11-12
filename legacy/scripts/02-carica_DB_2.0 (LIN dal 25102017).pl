###############################################################################################
#
# Title:	CARICA DATI DB
# Date:		perso nella notte dei tempi
# Author:	Bartolomeo Telaro
# Revision:	2007-02-20	B.T.
# Revision:	2011-02-15	B.T.	sistemato un problema nelle battute spezzate alla mezzanotte	 intruducendo l'eguaglianza della flay operation
# Revision:	2013-03-07	R.P.	aggiunto shift y radar lin x il 2012
# Revision:	2016-02-10	R.P. aggiunta tabella battute_doppie da caricare nel ciclo relativo all'errore traccia doppia 1062 e conclusione elaborazione dopo inidividuazione di una traccia doppia
# Revision: 2018-02-02  R.P. modificate coordite centro radar dal 25 ottobre 2017
# Comment:	Carica a partire da un file .out i dati nel database
#		composto da 3 tabelle: flay, battute, battute_doppie
#
###############################################################################################

#####################  LIBRERIE ########################################################
use Time::Local;    # carica la libreria per gestire le date e i fusi orari
use DBI; # carica la libreria DBI per connetrsi con il DB

#####################  IMPUT UTENTE ####################################################

if ($ARGV[0] eq '/help')
{
print 	"\n\n\n########################################################################################
######										########
###### INPUT RICHIESTO A VIDEO: DATABASE; PERCORSO DIRECTORY DA VALIDARE; 	########
######				 USERNAME; PASSWORD				########
######										########
###### INSERISCE I DATI CONTENUTI NEI FILE *.OUT DELLA DIRECTORY SPECIFICATA	########
######										########
###### ASSEGNA UN VALORE AI CAMPI flay, data, ora, aircraft, airport_dep	########
###### 				  airport_arr. flay_operation 			########
###### DELLA TABELLA FLAY							########
######										########
###### ASSEGNA UN VALORE AI CAMPI flay, ora, flay_id, X_m, Y_m, H_m		########
###### DELLA TABELLA BATTUTE							########
######										########
###### MODIFICHE:								########
######										########
###### 2005-04-12 Aggiungo un NULL nello stamnet di insert (riga 97) per tenere	########
######		conto dell' aggiunta nella tabella flay				######## 
######		della colonna data_ora_arr				B.T.	########
######										########
###### 2006-08-23 Aggiunto il controllo =~ s/\W//g  nella funzione 		########
###### 		sub fIntTrac, per controllare che i campi letterali non 	########
######		contengano caretteri strani che mandano in errore l'inserimento	########
######		nel db, ad esmpio (')					B.T...	########
######										########
###### 2006-09-22  INZIO tentativi di velocizzazione dello script
###### 2006-10-15  utilizzato il LOAD DATA INFILE per inserire le battute, ovvero:
######			tutte i record della tabella battute vengoni scritti in un file
######			e si utilizza il comando LOAD DATA FILE per caricarli in maniera +
######			efficente nel DB, come suggerito nella manualistica di MySql
######    
########################################################################################\n\n\n";
die;
}
	
###############################################################################################
print "INSERIRE IL NOME DEL DATABASE: ";
$database = <STDIN>;
chomp($database);
print "INSERIRE IL PERCORSO DELLA DIRECTORY DA PROCESSARE: ";
$percorso = <STDIN>;
$percorso = qq{$percorso};
print "$percorso \n";
chomp($percorso);
print "INSERIRE IL NOME UTENTE: ";
$nome_utente = <STDIN>;
chomp($nome_utente);
print "INSERIRE LA PASSWORD (VISUALIZZATA IN CHIARO!): ";
$password = <STDIN>;
chomp($password);
print "INSERIRE IL NOME DELL' AEROPORTO CODICE (ICAO): ";
$aeroporto = <STDIN>;
chomp($aeroporto);
$aeroporto = uc $aeroporto;


$db_radar = DBI->connect("DBI:mysql:$database:localhost", $nome_utente, $password) ||  
die "\n\n\n  -- FATAL ERROR :  Non mi posso connettere al database:$DBI::errstr\n\n\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";
####################

@data_ora=localtime(time);
$data_ora[4]=$data_ora[4]+1;
$data_ora[5]=$data_ora[5]+1900;

$nomefileOUT = "report\\02carica_DB_02-$database\_$nome_utente\_$data_ora[3]-$data_ora[4]-$data_ora[5]\_$data_ora[2]-$data_ora[1]-$data_ora[0].log";
$nomefiledata = "D:/file_carica_dati$database\_$nome_utente\_$data_ora[3]_$data_ora[4]_$data_ora[5]\_$data_ora[2]_$data_ora[1]_$data_ora[0].txt";
$nomefiledata2 = "D:/file_battute_doppie$database\_$nome_utente\_$data_ora[3]_$data_ora[4]_$data_ora[5]\_$data_ora[2]_$data_ora[1]_$data_ora[0].txt";
open(FILEOUTPUT,'>>',$nomefileOUT);
open(FILEDATA,'>>',$nomefiledata);
open(FILEDATA2,'>>',$nomefiledata2);
print "**** CARICA_DB *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\nDB: $database\tUTENTE: $nome_utente\n\n";
print (FILEOUTPUT "**** CARICA_DB START *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\nDB: $database\nUTENTE: $nome_utente\n");
print (FILEOUTPUT "$percorso\n\n");

$double_track = 0;
$k = 0;

if ($percorso) 		#esistenza del parametro "path della directory da processare"
{
	@nomefile = `dir $percorso /B`;
	if ($nomefile[0] eq '')
	{
		die "Non ci sono file da processare nella directory specificata\n";
	}

	$InsRadar_tracce = $db_radar->prepare(q{INSERT INTO flay (flay,data,ora,aircraft,airport_dep,airport_arr,flay_operation,data_ora_italy)
				  VALUES(?,?,?,?,?,?,?,?)});

	$SeleTrack_double = $db_radar->prepare(q{SELECT row_id, flay FROM flay WHERE flay = ? AND data = ? AND ora = ?});

	foreach $nomefile (@nomefile)
	{
		$nomefile=~ /OUT$/ || $nomefile=~ /out$/ || next;
		$iCount++;
		$path_nomefile=$percorso.'\\'.$nomefile;
		##############   print"path:\t$path_nomefile\n";    
		open(FILEINPUT,$path_nomefile);
		print "ANALIZZO IL FILE $nomefile \n\n";
		trkAnalisys: while (!eof(FILEINPUT))
		{
			$riga = <FILEINPUT>;
			$Lriga = length($riga);
			if ($riga ne "\n")
			{
				@INTTRAC = &fIntTrac ($riga, $aeroporto);
				$data_original = $INTTRAC[1];
				#$statement = "INSERT INTO flay VALUES(NULL,'$INTTRAC[0]','$INTTRAC[1]','$INTTRAC[2]','$INTTRAC[3]','$INTTRAC[4]','$INTTRAC[5]','$INTTRAC[6]',NULL,NULL,NULL,'$INTTRAC[7]',NULL,NULL)";

				#$InsRadar = $db_radar->prepare($statement) || die "Can't prepare $statement: $db_radar->errstr\n";
				$rv = $InsRadar_tracce->execute($INTTRAC[0],$INTTRAC[1],$INTTRAC[2],$INTTRAC[3],$INTTRAC[4],$INTTRAC[5],$INTTRAC[6],$INTTRAC[7]);  # || die "can't execute the query: $InsRadar->errstr";
				$errore = $InsRadar_tracce->errstr;
				$err_code= $InsRadar_tracce->err;
				if (!$err_code)
				{
					$k++;
					$track_id = $InsRadar_tracce->{'mysql_insertid'};
					$FltId = $INTTRAC[0];
					#######	print "\t row_id =  $track_id -- inserita $k righa\n";	
				}
				elsif ($err_code == 1062)
				{
					#@traccia_inserita = $db_radar->selectrow_array("SELECT row_id, flay FROM flay WHERE flay = '$INTTRAC[0]' AND data = '$INTTRAC[1]' AND ora = '$INTTRAC[2]'");
					$SeleTrack_double->execute($INTTRAC[0],$INTTRAC[1],$INTTRAC[2]);
					@traccia_inserita = $SeleTrack_double-> fetchrow_array;
					$track_id = $traccia_inserita[0];
					$FltId = $traccia_inserita[1];
					$double_track++;
					print (FILEOUTPUT "TRACK:\tcontrollare traccia doppia row_id = $track_id   flay = $FltId\n");
					$iPos = 34;
					$iLen = 24;
					@batt2;
					do
					{
					$battuta = substr ($riga, $iPos, $iLen);
					@batt2 = &fBattuta($battuta,$data_original);
					if ($batt2[0] == $batt_old[0] && $batt2[1] == $batt_old[1] && $batt2[2] == $batt_old[2] && $batt2[3] == $batt_old[3])
					{
						print (FILEOUTPUT "flay_id $FltId -> battuta doppia @batt2\n");
					}
					elsif ($batt2[3] > 0)		# se l' altezza è diversa da 0 valorizza nache il campo Z_m
					{
						print (FILEDATA2 "\\N,$batt2[0],$track_id,$batt2[1],$batt2[2],$batt2[3],$batt2[3],\\N,\\N,\\N,\\N,\\N,$batt2[4]\n");
					}
					else
					{
						print (FILEDATA2 "\\N,$batt2[0],$track_id,$batt2[1],$batt2[2],\\N,$batt2[3],\\N,\\N,\\N,\\N,\\N,$batt2[4]\n");
					}
					$iPos += $iLen;
					@batt_old = @batt2;
					}
				while ( $iPos + $iLen < $Lriga);
                next trkAnalisys;
				}
				else
				{
					die "\n\tEXIT ON ERROR\nerror code=$err_code\n$errore\n";
				}
				$iPos = 34;
				$iLen = 24;
				@batt1;
				do
				{
					$battuta = substr ($riga, $iPos, $iLen);
					@batt1 = &fBattuta($battuta, $data_original);
					if ($batt1[0] == $batt_old[0] && $batt1[1] == $batt_old[1] && $batt1[2] == $batt_old[2] && $batt1[3] == $batt_old[3])
					{
						print (FILEOUTPUT "flay_id $FltId -> battuta doppia @batt1\n");
					}
					elsif ($batt1[3] > 0)		# se l' altezza è diversa da 0 valorizza nache il campo Z_m
					{
						print (FILEDATA "\\N,$batt1[0],$track_id,$batt1[1],$batt1[2],$batt1[3],$batt1[3],\\N,\\N,\\N,\\N,\\N,$batt1[4]\n");
					}
					else
					{
						print (FILEDATA "\\N,$batt1[0],$track_id,$batt1[1],$batt1[2],\\N,$batt1[3],\\N,\\N,\\N,\\N,\\N,$batt1[4]\n");
					}
					$iPos += $iLen;
					@batt_old = @batt1;
				}
				while ( $iPos + $iLen < $Lriga);
			}
		}
		close (FILEINPUT);
		#print (FILEOUTPUT "\n\n$numero_voli\tVOLI INSERITI PER IL FILE $nomefile\n");
		#print (FILEOUTPUT "\n\n$battute_tot\tBATTUTE TOTALI INSERITE PER IL FILE $nomefile\n\n\n");
	}
	close (FILEDATA);
	#$InsRadar_battute_from_file = 
	$db_radar->do("LOAD DATA INFILE '$nomefiledata' INTO TABLE battute FIELDS TERMINATED BY ',' ") ||
	die print (FILEOUTPUT "FATAL ERROR lo script ha cercato di inserire una battuta doppia - Controllare i dati di input\n\n\n");
	close (FILEDATA2);
	#$InsRadar_battute_doppie_from_file = 
	$db_radar->do("LOAD DATA INFILE '$nomefiledata2' INTO TABLE battute_doppie FIELDS TERMINATED BY ',' ") ||
	die print (FILEOUTPUT "FATAL ERROR lo script ha cercato di inserire una battuta doppia - Controllare i dati di input\n\n\n");
}
else
{
	print "\t parametri insufficienti\n";
}
print "tracce multiple = $double_track\n";
print (FILEOUTPUT "tracce multiple = $double_track\n\n\n");


@data_oraE=localtime(time);
$data_oraE[4]=$data_oraE[4]+1;
$data_oraE[5]=$data_oraE[5]+1900;

$secondidelta = (3600*$data_oraE[2] + 60*$data_oraE[1] + $data_oraE[0])-(3600*$data_ora[2] + 60*$data_ora[1] + $data_ora[0]);

print (FILEOUTPUT "**** CARICA_DB FINE *****\n");
print (FILEOUTPUT "$data_oraE[3]/$data_oraE[4]/$data_oraE[5]\t$data_oraE[2]:$data_oraE[1]:$data_oraE[0]\n");
print (FILEOUTPUT "secondi trascorsi =  $secondidelta\n");
print "secondi trascorsi $secondidelta\n";


############################ INIZIA CORREZIONE TRACCE SPEZZATE  A CAVALLO DELLA MEZZANOTTE ######################
#################################################################################################################
print "**** UNISCI TRACCE_MEZZANOTTE *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n";
print (FILEOUTPUT "***** UNISCI TRACCE MEZZANOTTE SPEZZATE *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n");
print (FILEOUTPUT "\n\t\t");

$sel_str = "SELECT row_id, flay, data, flay_operation FROM flay WHERE ora < '00:10:00' and validation_fl IS NULL";  # seleziona tutte le tracce che iniziano al massimo 20 secondi dopo la mezzanotte
$sel_h = $db_radar->prepare($sel_str) ||
	chomp($errstr=$sel_h->errstr) &&
	die "Can't prepare $statement: $errstr\n";
$rv = $sel_h->execute ||
	chomp($errstr=$sel_h->errstr) &&
	die "Can't prepare $statement: $errstr\n";

while(@row_Fl = $sel_h->fetchrow_array)
{
	$flay_id	= $row_Fl[0];
	$flay	= $row_Fl[1];
	$data	= $row_Fl[2];
	$flay_operation = $row_Fl[3];
	$sel_y_str = "SELECT row_id FROM flay WHERE ora > '23:00:00' and flay = '$flay' and data = date_add('$data', INTERVAL -1 DAY) AND flay_operation = '$flay_operation'"; #seleziona tutte le tracce che inziano dopo le 23 e per cui vi sia una traccia nel giorno successivo tra quelle precedentemente estratte
	$sel_y_h = $db_radar->prepare($sel_y_str) ||
		chomp($errstr=$sel_y_h->errstr) &&
		die "Can't prepare $statement: $errstr\n";
	$rv = $sel_y_h->execute ||
		chomp($errstr=$sel_y_h->errstr) &&
		die "Can't prepare $statement: $errstr\n";

	$ref_sel_y = $sel_y_h->fetchall_arrayref;
	if (@{$ref_sel_y} == 1)
	{
		$flay_id_y = $ref_sel_y->[0][0]; 
		$update_str = "UPDATE battute SET flay_id = $flay_id_y WHERE flay_id = $flay_id";
		$rv = $db_radar->do($update_str) ||
			chomp($errstr=$sel_h->errstr) &&
			die "Can't prepare $statement: $errstr\n";
		$rv = $db_radar->do("UPDATE flay SET validation_fl = 'M', validation_bt = 0 WHERE row_id = $flay_id") ||
			chomp($errstr=$sel_h->errstr) &&
			die "Can't prepare $statement: $errstr\n";
		print (FILEOUTPUT "$flay_id -> $flay_id_y\n");
	}
	elsif (@{$ref_sel_y} < 1)
	{
		
		print "$fl_id -> non è una traccia spezzata\n";
		print (FILEOUTPUT "$flay_id non inizia prima della mezanotte\n");
	}
	else
	{
		print "Ci sono dei problemi\n";
		print (FILEOUTPUT "$flay_id c'e' più di una traccia $flay che inzia prima della mezzanotte\n");
	}
}

@data_oraE=localtime(time);
$data_oraE[4]=$data_oraE[4]+1;
$data_oraE[5]=$data_oraE[5]+1900;

$secondidelta = (3600*$data_oraE[2] + 60*$data_oraE[1] + $data_oraE[0])-(3600*$data_ora[2] + 60*$data_ora[1] + $data_ora[0]);

print (FILEOUTPUT "\n***** SCRIPT FINE ******\n");
print (FILEOUTPUT "$data_oraE[3]/$data_oraE[4]/$data_oraE[5]\t$data_oraE[2]:$data_oraE[1]:$data_oraE[0]\n");
print (FILEOUTPUT "secondi trascorsi =  $secondidelta\n");
print "secondi trascorsi $secondidelta\n";

close (FILEOUTPUT);

###################################################################################
#                         FUNZIONI                                                #
###################################################################################

# fIntTrac prende in imput una riga contenete l'intestazione della traccia radar (codofica ENAV)
# e restituisce un array con: 
# codice volo,data,ora,tipo di areo,areoporto di partenza, areoporto di destinazione,operazione


sub fIntTrac
{
	my ($Ora,$Ora,$FltId,$AcType,$ApFrom,$ApTo,$OpType,@aIntTrac);  
	$sRiga = @_[0];
	$aerop = @_[1];
	$Data = 	substr ($sRiga, 0, 8);
	$Ora =  	substr ($sRiga, 8, 6);
	$Anno = 	substr ($sRiga, 0, 4);
	$Mese = 	substr ($sRiga, 4, 2);
	$Giorno = 	substr ($sRiga, 6, 2);
	$hours =  	substr ($sRiga, 8, 2);
	$minutes =  	substr ($sRiga, 10, 2);
	$seconds =  	substr ($sRiga, 12, 2);
	if ($seconds == 60) {$seconds = 59;}
	$EpochTime = timegm ($seconds,$minutes,$hours,$Giorno,$Mese - 1,$Anno - 1900);
	($iSeconds,$iMinutes,$iHours,$iDay,$iMonth,$iYear,$aaa,$bbb,$ccc) = localtime ($EpochTime);
	$iMonth += 1;
	$iYear += 1900;
	$Date_time_Italy = "$iYear-$iMonth-$iDay $iHours:$iMinutes:$iSeconds";
	$delta_Hours = $iHours - $hours;
	$FltId = substr ($sRiga, 14, 7);
	$FltId  =~ s/\W//g;  # cancella dalla stringa tutti i caratteri non alfabetici A-Z  a-z  0-9 
	$AcType = substr ($sRiga, 22, 4);
	$AcType =~ s/\W//g; # cancella dalla stringa tutti i caratteri non alfabetici A-Z  a-z  0-9 
	$ApFrom = substr ($sRiga, 26, 4);
	$ApFrom  =~ s/\W//g;
	$ApTo = substr ($sRiga, 30, 4);
	$ApTo  =~ s/\W//g; 
	if ($ApFrom eq $aerop)
	{
		$OpType = 'D';
	}
	elsif ($ApTo eq $aerop)
	{
		$OpType = 'A';
	}
	else
	{
		$OpType = 'N';
	}
	@aIntTrac = ($FltId,$Data,$Ora,$AcType,$ApFrom,$ApTo,$OpType,$Date_time_Italy,$delta_Hours);     
	return @aIntTrac;
}

#  fBattuta  prende in imput una stringa contenente una singola battuta radar (codifica ENAV)
#  restituisce un array con:
#  ora, X, Y, Altitudine dove tutte le distanze sono espresse in metri.
#  X, Y sono le coordinate della battuta esperesse nel sistema GAUSBOAGA
#  nella stringa in imput la posizione della battute è espressa in cordinate (1/64 miglia nautiche)
#  con origine (45° 27' 40'', 9° 16' 50''), mentre l' Altitudine è in centinaia di piedi s.l.m.
#  (per INFO vedere il file tracce_radar_SEA.html in documenti sul server)

sub fBattuta
{
	my ($sBattuta,$time_gtm,$Data,$time_local,$d_local_gtm,$hours_gtm,$hours_local,$minutes,$seconds,$Xpos,$Ypos,$Alt);
	$sBattuta = @_[0];
	#$d_local_gtm = @_[1];
	$Data = @_[1];
	$time_gtm = 	substr ($sBattuta, 18, 6);
	$Anno = 	substr ($Data, 0, 4);
	$Mese = 	substr ($Data, 4, 2);
	$Giorno = 	substr ($Data, 6, 2);

	$hours =  	substr ($sBattuta, 18, 2);
	$minutes =  	substr ($sBattuta, 20, 2);
	$seconds =  	substr ($sBattuta, 22, 6);
	if ($seconds == 60) {$seconds = 59;}
	$EpochTime = timegm ($seconds,$minutes,$hours,$Giorno,$Mese - 1,$Anno - 1900);
	($iSeconds,$iMinutes,$iHours,$iDay,$iMonth,$iYear,$aaa,$bbb,$ccc) = localtime ($EpochTime);
	$iMonth += 1;
	$iYear += 1900;
	$Date_time_Italy = "$iYear-$iMonth-$iDay $iHours:$iMinutes:$iSeconds";
	$Xpos = substr($sBattuta, 0, 6);
	$Xpos = $Xpos/64;
	$Xpos = ($Xpos*1852.2)+1521961.05;
	$Ypos = substr($sBattuta, 6, 6);
	$Ypos = $Ypos/64;
	$Ypos = ($Ypos*1852.2)+5034234.14;
	$Alt = substr($sBattuta, 12, 6);
	$Alt = $Alt*100*0.3048;
	@aBattuta = ($time_gtm,$Xpos,$Ypos,$Alt,$Date_time_Italy);
	return @aBattuta;
}
