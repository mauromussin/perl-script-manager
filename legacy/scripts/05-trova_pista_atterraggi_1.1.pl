###############################################################################################
#
# Title:	trova pista atterraggi
# Author:	Bartolomeo Telaro, Matteo Giampaolo, Fabio Forfori
# Date:		perso nella notte dei tempo
# Revision:  	????-??-??  	Bartolomeo Telaro
# 		????-??-??	Matteo Giampaolo
#		2007-02-22	Bartolomeo Telaro
#		
# Comment:	Analizza le tracce (atterraggi) con validation_bt = 1 
#		(su cui ha girato positivamete il valida battute)
#		assegna la pista, se non riesca ad ssegnare la pista invalida la traccia, 
#		ponendo validation_fl = 'P' e validation_bt = 0
#		se assegna la pista assegna anche la sid
#
# Table usate:		flay, battute, anagrafica.aeroporti 
#
###############################################################################################

if ($ARGV[0] eq '/help')
{
print 	"\n\n\n################################################################################
######  									########
######  INPUT RICHIESTO A VIDEO: DATABASE; SIGLA_AEROPORTO; USERNAME; PASSWORD 	########
######  									########
######	ASSEGNA UNA PISTA ALLE TRACCE PRECEDENTEMENTE VALIDATE, 		########
######  UTILIZZANDO LE BATTUTE VALIDATE 					########
######  									########
######	                                                                        ########                                                                                                                                                             ########
######	Pone il campo 'PISTA' = '35L','35R','17L','17R','NA','N1','N2','N9'     ########                                                                                                                                               ########
######	Se le ultime due battute sono discordanti non assegna la traccia e pone ########
######  il campo 'pista' = 'NA'                                                 ########                                                                             ########
######	Se l'ultima battuta della traccia non rientra nel 'trapezio d'arrivo' o ########
######  è ad un quota superiore di 600 mt. rispetto a quella dell'aeroporto,    ########
######  pone il campo 'pista' = 'N2'                                            ########
######	Se la penultima battuta della traccia non rientra nel 'trapezio         ########
######  d'arrivo' o è ad un quota superiore di 600 mt. rispetto a quella dell'  ########
######  aeroporto, pone il campo 'pista' = 'N1'                                 ########
######  Nel caso il campo pista risulti invalidato (N1, N2, NA), ripete la      ########
######  procedura utilizzando la penultima e la terzultima battuta e pone, nel  ########
######  caso la pista assegnata sia valida, il campo 'validation' dell'ultima   ########
######  battuta = 'X'								########
######	Pone a 'P' il campo 'validation_fl' delle tracce precedentemente 	########
######  validate (Y o L)  nella tabella  'flay' se la pista è stata assegnata a ########
###### 'N9' o 'NA' o 'N1' o 'N2'                                                 ########
######  Produce un file di log con tutte le 'row_id' e le relative piste 	########
######  assegnate 								########
######                                                               		########                                                                                   ########
######  LINATE: Assegna alle tracce relative agli atterragi la pista 		########
######	presumibilmente utilizzata (36R, 18L) valutando il segno della 		########
######	differenza delle latitudini delle due ultime battute			########
######  (purchè queste siano sufficientemente vicine alla pista)		########
######  									########
######  ORIO: Assegna alle tracce relative agli atterragi la pista 		########
######	presumibilmente utilizzata (11, 29) valutando il segno della 		########
######	differenza delle longitudini delle due ultime battute			########
######  (purchè queste siano sufficientemente vicine alla pista)		########
######  									########
######  MONTICHIARI: ALGORITMO NON ANCORA IMPLEMENTATO				########
######  									########
########################################################################################\n\n\n";
die;
}
	
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

use DBI; # carica la libreria DBI per connetrsi con il DB

$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) || 
die "Non mi posso connettere al database:$DBI::errstr\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

  
$B = length($database);
print "\n\n\t\t";
for ($L=0; $L < $B; $L++){print"*";}
print "********************************************** \n";
print "\t\t****    CONNECTION TO DB '$database' SUCCESSFUL    **** \n\t\t";
for ($L=0; $L < $B; $L++){print"*";}
print "********************************************** \n\n\n\n\n\n";
 
@data_ora=localtime(time);
$data_ora[4]=$data_ora[4]+1;
$data_ora[5]=$data_ora[5]+1900;

$nomefileOUT = "report\\05pistaatterraggi-$database\_$nome_utente\_$data_ora[3]-$data_ora[4]-$data_ora[5]\_$data_ora[2]-$data_ora[1]-$data_ora[0].log";
open(FILEOUTPUT,'>>',$nomefileOUT);
print "\n\n**** TROVA PISTA ATTERRAGGI *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n";
print (FILEOUTPUT "***** TROVA PISTA ATTERRAGGI *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n");

print (FILEOUTPUT "\n\n\t\t");
for ($L=0; $L < $B; $L++){print(FILEOUTPUT "*");}
print (FILEOUTPUT "********************************************** \n");
print (FILEOUTPUT "\t\t****    CONNECTION TO DB '$database' SUCCESSFUL    **** \n\t\t");
for ($L=0; $L < $B; $L++){print(FILEOUTPUT "*");}
print (FILEOUTPUT "********************************************** \n\n\n\n");


$sel_track = "SELECT row_id FROM flay WHERE flay_operation = 'A' AND validation_bt = 1 AND pista IS NULL";
$errstr=$db_radar->errstr;
$selTh = $db_radar->prepare($sel_track) || die "Can't prepare $statement: $errstr\n";
$errstr=$selTh->errstr;
$rv = $selTh->execute || die "can't execute the query: $errstr\n";
$rv == 0 && die "\n non ci sono tracce non assegnate \n ";

$sel_batt = "SELECT X_m, Y_m, H_m , row_id FROM battute WHERE flay_id = ? AND validation = 'Y' ORDER BY time_italy";
$errstr=$db_radar->errstr;
$selBh = $db_radar->prepare($sel_batt) || die "Can't prepare $statement: $errstr\n";


#**************************************************************************************************************
#************************************* ALGORITMO PER MALPENSA *************************************************
#**************************************************************************************************************

if ($aeroporto eq 'LIMC')
{
	$sel_on_piste = "SELECT p.LONG_pista,p.LAT_pista, a.QUOTA_aerop FROM anagrafica.aeroporti as a, anagrafica.piste as p WHERE a.nome_aerop = '$aeroporto' and a.row_id = p.id_aerop";
	$errstr=$db_radar->errstr;
	$sel_on_piste_h = $db_radar->prepare($sel_on_piste) || die "Can't prepare $statement: $errstr\n";
	$errstr=$sel_on_piste_h->errstr;
	$rv1 = $sel_on_piste_h->execute || die "can't execute the query: $errstr";
	
	$coord_piste = $sel_on_piste_h->fetchall_arrayref;
	
	$X1est=$coord_piste->[0][0];
	$Y1est=$coord_piste->[0][1];
	$X2est=$coord_piste->[1][0];
	$Y2est=$coord_piste->[1][1];
	
	$X1ovest=$coord_piste->[2][0];
	$Y1ovest=$coord_piste->[2][1];
	$X2ovest=$coord_piste->[3][0];
	$Y2ovest=$coord_piste->[3][1];
	
	$H_aerop=$coord_piste->[0][2];
	
	$sel_on_piste_h->finish;
	
	while(@row_T = $selTh->fetchrow_array)
	{

		$fl_id = $row_T[0];
		#print "traccia $fl_id\n";

		$errstr=$selBh->errstr;
		$rv1 = $selBh->execute($fl_id) || die "can't execute the query: $errstr";
		$rv1 == 0 && print "\n non ci sono battute associate alla traccia $fl_id \n";

		$table_battuta = $selBh->fetchall_arrayref; 

		$N_row = $#{$table_battuta};
		$j = $N_row;
		$k= 0; #contatore

		$d_E1 =800;
		$d_W1 =800;

		if ($j>0)
		{	
			@A_arr=(1480339,5040761);
			@B_arr=(1477436,5057332);
			@C_arr=(1478637,5058095);
			@D_arr=(1481816,5040946);

			$mAB_arr=($A_arr[1]-$B_arr[1])/($A_arr[0]-$B_arr[0]);
			$mBC_arr=($B_arr[1]-$C_arr[1])/($B_arr[0]-$C_arr[0]);
			$mCD_arr=($C_arr[1]-$D_arr[1])/($C_arr[0]-$D_arr[0]);
			$mDA_arr=($D_arr[1]-$A_arr[1])/($D_arr[0]-$A_arr[0]);
			#print"$mAB_arr\t$mBC_arr\t$mCD_arr\t$mDA_arr\n";

			$qAB_arr=$B_arr[1]-$mAB_arr*$B_arr[0];
			$qBC_arr=$C_arr[1]-$mBC_arr*$C_arr[0];
			$qCD_arr=$D_arr[1]-$mCD_arr*$D_arr[0];
			$qDA_arr=$A_arr[1]-$mDA_arr*$A_arr[0];


			#print "($table_battuta->[$j][0]\t$table_battuta->[$j][1]\t$row3[2]\n)";
			if (($table_battuta->[$j][1]>$mAB_arr*$table_battuta->[$j][0]+$qAB_arr) &&
			($table_battuta->[$j][1]<$mBC_arr*$table_battuta->[$j][0]+$qBC_arr) &&
			($table_battuta->[$j][1]<$mCD_arr*$table_battuta->[$j][0]+$qCD_arr) &&
			($table_battuta->[$j][1]>$mDA_arr*$table_battuta->[$j][0]+$qDA_arr) &&			
			($table_battuta->[$j][2] < $H_aerop+600))
			{	
				# calcola la distanza dell'ultima battuta radar dalla pista EST
				$d_E1 = &distance ($X1est, $Y1est,$X2est, $Y2est, $table_battuta->[$j][0],$table_battuta->[$j][1]);

				# calcola la distanza dell'ultima battuta radar dalla pista OVEST
				$d_W1 = &distance ($X1ovest, $Y1ovest, $X2ovest, $Y2ovest, $table_battuta->[$j][0],$table_battuta->[$j][1]);		

				if ($d_E1 < $d_W1)	{$pista1 = 'EST';}
				elsif ($d_E1 > $d_W1)	{$pista1 = 'WEST';}
				else			{$pista1 = 'NA';}
				
				$j--;
				
				if (($j >= 0) && 
				($table_battuta->[$j][1]>$mAB_arr*$table_battuta->[$j][0]+$qAB_arr) &&
				($table_battuta->[$j][1]<$mBC_arr*$table_battuta->[$j][0]+$qBC_arr) &&
				($table_battuta->[$j][1]<$mCD_arr*$table_battuta->[$j][0]+$qCD_arr) &&
				($table_battuta->[$j][1]>$mDA_arr*$table_battuta->[$j][0]+$qDA_arr) &&			
				($table_battuta->[$j][2] < $H_aerop+600))
				{
					# calcola la distanza della penultima battuta dala pista EST
					$d_E2 = &distance ($X1est, $Y1est,$X2est, $Y2est, $table_battuta->[$j][0],$table_battuta->[$j][1]);

					# calcola la distanza della penultima battuta dalla pista OVEST
					$d_W2 = &distance ($X1ovest, $Y1ovest, $X2ovest, $Y2ovest, $table_battuta->[$j][0],$table_battuta->[$j][1]);

					if ($d_E2 < $d_W2)	{$pista2 = 'EST';}
					elsif ($d_E2 > $d_W2)	{$pista2 = 'WEST';}
					else			{$pista2 = 'NA';}

					if ($pista1 eq $pista2)	{$pista = $pista1;}
					else			{$pista = 'NA';}
					
					if ($pista eq 'EST')
					{
						if ($table_battuta->[$j][1] > $table_battuta->[$j +1][1]) {$pista = '17L';}
						else {$pista = '35R';}
					}
					if ($pista eq 'WEST')
					{
						if ($table_battuta->[$j][1]>$table_battuta->[$j +1][1]) {$pista = '17R';}
						else {$pista = '35L';}
					}
				}
				else {$pista = 'N1';}  ### PENULTIMA BATTUTA FUORI DAL TRAPEZIO D'ARRIVO
			}
			else {$pista = 'N2';}   ### ULTIMA BATTUTA FUORI DAL TRAPEZIO D'ARRIVO
		}
		else {$pista = 'N9';} ### TRACCIA SENZA BATTUTE   in teoria qui non dovrebbe entraci mai
	  
		if (($pista eq 'N1') || ($pista eq 'NA') || ($pista eq 'N2'))  # TOLGO L'ULTIMA BATTUTA (POSTA = X) ALLE PISTE NON ASSEGNATE NA, N1, N2 e RILANCIO L'ASSEGNAZIONE
		{	
			if ($pista eq 'N2') {$j--}
		
			if (($table_battuta->[$j][1]>$mAB_arr*$table_battuta->[$j][0]+$qAB_arr) &&
			($table_battuta->[$j][1]<$mBC_arr*$table_battuta->[$j][0]+$qBC_arr) &&
			($table_battuta->[$j][1]<$mCD_arr*$table_battuta->[$j][0]+$qCD_arr) &&
			($table_battuta->[$j][1]>$mDA_arr*$table_battuta->[$j][0]+$qDA_arr) &&			
			($table_battuta->[$j][2] < $H_aerop+600))
			{	
				$d_E1 = &distance ($X1est, $Y1est,$X2est, $Y2est, $table_battuta->[$j][0],$table_battuta->[$j][1]);
				$d_W1 = &distance ($X1ovest, $Y1ovest, $X2ovest, $Y2ovest, $table_battuta->[$j][0],$table_battuta->[$j][1]);

				if ($d_E1 < $d_W1)	{$pista1 = 'EST';}
				elsif ($d_E1 > $d_W1)	{$pista1 = 'WEST';}
				else	{$pista1 = 'NA';}
				
				$j--;
				
				if (($j >= 0) && 
				($table_battuta->[$j][1]>$mAB_arr*$table_battuta->[$j][0]+$qAB_arr) &&
				($table_battuta->[$j][1]<$mBC_arr*$table_battuta->[$j][0]+$qBC_arr) &&
				($table_battuta->[$j][1]<$mCD_arr*$table_battuta->[$j][0]+$qCD_arr) &&
				($table_battuta->[$j][1]>$mDA_arr*$table_battuta->[$j][0]+$qDA_arr) &&			
				($table_battuta->[$j][2] < $H_aerop+600))
				{
					$d_E2 = &distance ($X1est, $Y1est,$X2est, $Y2est, $table_battuta->[$j][0],$table_battuta->[$j][1]);
					$d_W2 = &distance ($X1ovest, $Y1ovest, $X2ovest, $Y2ovest, $table_battuta->[$j][0],$table_battuta->[$j][1]);

					if ($d_E2 < $d_W2)	{$pista2 = 'EST';}
					elsif ($d_E2 > $d_W2)	{$pista2 = 'WEST';}
					else			{$pista2 = 'NA';}

					if ($pista1 eq $pista2)	{$pista = $pista1;}
					else 			{$pista = 'NA';}
					
					if($pista eq 'EST')
					{
						$up_on_batt_N= "UPDATE battute SET validation = 'X' WHERE flay_id = '$fl_id' AND row_id = '$table_battuta->[$j+2][3]'";
						$up_on_batt_h_N = $db_radar->prepare($up_on_batt_N) || die "Can't prepare $statement: $db_radar->errstr\n";;
						$rv = $up_on_batt_h_N->execute || die "can't execute the query: $up_on_flay_h->errstr";
						$up_on_batt_h_N->finish;
						
						if ($table_battuta->[$j][1] > $table_battuta->[$j +1][1]) {$pista = '17L';}
						else	{$pista = '35R';}
					}
					if ($pista eq 'WEST')
					{
						$up_on_batt_N= "UPDATE battute SET validation = 'X' WHERE flay_id = '$fl_id' AND row_id = '$table_battuta->[$j+2][3]'";
						$up_on_batt_h_N = $db_radar->prepare($up_on_batt_N) || die "Can't prepare $statement: $db_radar->errstr\n";;
						$rv = $up_on_batt_h_N->execute || die "can't execute the query: $up_on_flay_h->errstr";
						$up_on_batt_h_N->finish;
						if ($table_battuta->[$j][1]>$table_battuta->[$j +1][1]) {$pista = '17R';}
						else {$pista = '35L';}
					}
				}
				#else {$pista = 'N3';}  ### TERZULTIMA BATTUTA FUORI DAL TRAPEZIO D'ARRIVO
			}
			#else {$pista = 'N4';}   ### PENULTIMA BATTUTA FUORI DAL TRAPEZIO D'ARRIVO
		}	
		print "flayid\t$fl_id\n";	
		$rc = $selBh->finish;
		
		if ($pista eq '35L' || $pista eq '35R' || $pista eq '17L' || $pista eq '17R')
		{
			$up_track = "UPDATE flay SET pista = '$pista', sid = '$pista' WHERE row_id = '$fl_id'";
		}
		else
		{
			$up_track = "UPDATE flay SET pista = '$pista', validation_fl = 'P', validation_bt = 0 WHERE row_id = '$fl_id'";
			print (FILEOUTPUT "Non assegnata pista -> $pista  alla Traccia N. $fl_id\n");
		}
		$errstr=$db_radar->errstr;
		$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
		$errstr=$upTh->errstr;
		$rv = $upTh->execute || die "can't execute the query: $errstr\n";

		$rc = $upTh->finish;
	} 
}
#************************************* FINE ALGORITMO PER MALPENSA ********************************************
#**************************************************************************************************************


#**************************************************************************************************************
#************************************* ALGORITMO PER LINATE ***************************************************
#**********************************(non considera la pista ovest)**********************************************
#**************************************************************************************************************

if ($aeroporto eq 'LIML')
{
	$sel_on_piste = "SELECT p.LONG_pista,p.LAT_pista, a.QUOTA_aerop FROM anagrafica.aeroporti as a, anagrafica.piste as p WHERE a.nome_aerop = '$aeroporto' and a.row_id=p.id_aerop";
	$errstr=$db_radar->errstr;
	$sel_on_piste_h = $db_radar->prepare($sel_on_piste) || die "Can't prepare $statement: $errstr\n";
	$errstr=$sel_on_piste_h->errstr;
	$rv1 = $sel_on_piste_h->execute || die "can't execute the query: $errstr";
	
	$coord_piste = $sel_on_piste_h->fetchall_arrayref;
	
	$X1est=$coord_piste->[0][0];
	$Y1est=$coord_piste->[0][1];
	$X2est=$coord_piste->[1][0];
	$Y2est=$coord_piste->[1][1];
	
	$H_aerop=$coord_piste->[0][2];
	
	$sel_on_piste_h->finish;
	
	while(@row_T = $selTh->fetchrow_array)
	{
		$fl_id = $row_T[0];
		#print "traccia $fl_id\n";
		
		$errstr=$selBh->errstr;
		$rv1 = $selBh->execute($fl_id) || die "can't execute the query: $errstr";
		$rv1 == 0 && print "\n non ci sono battute associate alla traccia $fl_id \n";

		$table_battuta = $selBh->fetchall_arrayref; 
		
		$N_row = $#{$table_battuta};
		$j = $N_row;
		$k= 0; #contatore
		
		$d_E1 =300;
		
		if ($j>=0)
		{
			while (($d_E1 > 120) && ($k < 8) && ($j >= 0) && ($table_battuta->[$j][2] < $H_aerop+300))
			{
				# calcola la distanza dell' ultima battuta radar dalla pista EST
				$d_E1 = &distance ($X1est, $Y1est,$X2est, $Y2est, $table_battuta->[$j][0],$table_battuta->[$j][1]);
				
				$k++;
				$j--;
			}
			
			if (($k < 9) && ($j >= -1) && $table_battuta->[$j][2] < $H_aerop+300)
			{
				if($j >= 0)
				{
					if ($table_battuta->[$j][1] > $table_battuta->[$j +1][1]) {$pista = '18L';}
					else {$pista = '36R';}
				}
			}
			else {$pista = 'NA';}
		}
		else {$pista = 'NA';}
		$rc = $selBh->finish;
		print "flayid\t$fl_id\n";
		if ($pista eq '36R' || $pista eq '18L')
		{
			$up_track = "UPDATE flay SET pista = '$pista', sid = '$pista' WHERE row_id = '$fl_id'";
		}
		else
		{
			$up_track = "UPDATE flay SET pista = '$pista', validation_fl = 'P', validation_bt = 0 WHERE row_id = '$fl_id'";
			print (FILEOUTPUT "Non assegnata pista -> $pista  alla Traccia N. $fl_id\n");
		}
		$errstr=$db_radar->errstr;
		$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
		$errstr=$upTh->errstr;
		$rv = $upTh->execute || die "can't execute the query: $errstr";
		#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
		$rc = $upTh->finish;
	}
}
#************************************* FINE ALGORITMO PER LINATE **********************************************
#**************************************************************************************************************


#**************************************************************************************************************
#************************************* ALGORITMO PER ORIO *****************************************************
#**************************************************************************************************************

if ($aeroporto eq 'LIME')
{
	print "\n******  ATTENZIONE E' IMPOSTATO UN OFFSET SULLA LATITUDINE DELLE PISTE\n******  CONTINUARE? (Y,N)\n";
	$risposta=<STDIN>;
	chomp($risposta);
	if ($risposta ne 'Y' && $risposta ne 'y') {die "per cambiare l' offest digita lo script 03_valida_tracce e alle righe 440 e 442";}
	
	$sel_on_piste = "SELECT p.LONG_pista,p.LAT_pista, a.QUOTA_aerop FROM anagrafica.aeroporti as a, anagrafica.piste as p WHERE a.nome_aerop = '$aeroporto' and a.row_id = p.id_aerop";
	$errstr=$db_radar->errstr;
	$sel_on_piste_h = $db_radar->prepare($sel_on_piste) || die "Can't prepare $statement: $errstr\n";
	$errstr=$sel_on_piste_h->errstr;
	$rv1 = $sel_on_piste_h->execute || die "can't execute the query: $errstr";
	
	$coord_piste = $sel_on_piste_h->fetchall_arrayref;
	
	$X11=$coord_piste->[0][0];
	$Y11=$coord_piste->[0][1] - 376;
	$X29=$coord_piste->[1][0];
	$Y29=$coord_piste->[1][1] - 376;
	
	$H_aerop=$coord_piste->[0][2];
	
	$sel_on_piste_h->finish;
	
	#	$X11=1553790.646;
	#	$Y11=5057740.633-376;
	#	$X29=1556411.774;
	#	$Y29=5057071.234-376;
	#
	#	$H_aerop=237.439;
	
	
	while(@row_T = $selTh->fetchrow_array)
	{
		$fl_id = $row_T[0];
		#print "traccia $fl_id\n";
		
		$errstr=$selBh->errstr;
		$rv1 = $selBh->execute($fl_id) || die "can't execute the query: $errstr";
		$rv1 == 0 && print "\n non ci sono battute associate alla traccia $fl_id \n";
		
		$table_battuta = $selBh->fetchall_arrayref; 
		
		$N_row = $#{$table_battuta};
		$j = $N_row;
		$k= 0; #contatore
		
		$d_E1 =600;
		
		if ($j>=0)
		{
			while (($d_E1 > 500) && ($k < 8) && ($j >= 0) && ($table_battuta->[$j][2] < $H_aerop+2000) #450) modified teo
			)
			{
				# calcola la distanza dell' ultima battuta radar dalla pista EST
				$d_E1 = &distance ($X11, $Y11,$X29, $Y29, $table_battuta->[$j][0],$table_battuta->[$j][1]);

				$k++;
				$j--;
			}
	
			if (($k < 9) && ($j >= -1) && $table_battuta->[$j][2] < $H_aerop+2000) #450) modified teo
			{
				if($j >= 0)
				{
					if ($table_battuta->[$j][0] > $table_battuta->[$j +1][0]) {$pista = '29';}
					else	{$pista = '11';}
				}
			}
			else	{$pista = 'NA';}
		}
		else	{$pista = 'NA';}
		$rc = $selBh->finish;
		print "flayid\t$fl_id\n";
		if ($pista eq '29' || $pista eq '11')
		{
			$up_track = "UPDATE flay SET pista = '$pista', sid = '$pista' WHERE row_id = '$fl_id'";
		}
		else
		{
			$up_track = "UPDATE flay SET pista = '$pista', validation_fl = 'P', validation_bt = 0 WHERE row_id = '$fl_id'";
			print (FILEOUTPUT "Non assegnata pista -> $pista  alla Traccia N. $fl_id\n");
		}
		$errstr=$db_radar->errstr;
		$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
		$errstr=$upTh->errstr;
		$rv = $upTh->execute || die "can't execute the query: $errstr";
		#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
		$rc = $upTh->finish;
	}
}
#************************************* FINE ALGORITMO PER ORIO ************************************************
#**************************************************************************************************************


#**************************************************************************************************************
#************************************* ALGORITMO PER MONTICHIARI **********************************************
#**************************************************************************************************************

if ($aeroporto eq 'LIPO')
{
	print "\n******  ATTENZIONE E' IMPOSTATO UN OFFSET SULLA LATITUDINE DELLE PISTE\n******  CONTINUARE? (Y,N)\n";
	$risposta=<STDIN>;
	chomp($risposta);
	if ($risposta ne 'Y' && $risposta ne 'y') {die "per cambiare l' offest digita lo script 02_valida_tracce e alle righe 386 e 389";}
	
	$sel_on_piste = "SELECT p.LONG_pista,p.LAT_pista, a.QUOTA_aerop FROM anagrafica.aeroporti as a, anagrafica.piste as p WHERE a.nome_aerop = '$aeroporto' and a.row_id = p.id_aerop";
	$errstr=$db_radar->errstr;
	$sel_on_piste_h = $db_radar->prepare($sel_on_piste) || die "Can't prepare $statement: $errstr\n";
	$errstr=$sel_on_piste_h->errstr;
	$rv1 = $sel_on_piste_h->execute || die "can't execute the query: $errstr";
	
	$coord_piste = $sel_on_piste_h->fetchall_arrayref;
	
	$X14=$coord_piste->[0][0];
	$Y14=$coord_piste->[0][1] - 2515;
	$X32=$coord_piste->[1][0];
	$Y32=$coord_piste->[1][1] - 2515;
	
	$H_aerop=$coord_piste->[0][2];
	
	$sel_on_piste_h->finish;
	
	#	$X14=1603284.48;
	#	$Y14=5032351.40;
	#	$X32=1605086.28;
	#	$Y32=5030613.12;
	#
	#	$H_aerop=108.509;
	
	
	while(@row_T = $selTh->fetchrow_array)
	{
		$fl_id = $row_T[0];
		#print "traccia $fl_id\n";
		
		$errstr=$selBh->errstr;
		$rv1 = $selBh->execute($fl_id) || die "can't execute the query: $errstr";
		$rv1 == 0 && print "\n non ci sono battute associate alla traccia $fl_id \n";
		
		$table_battuta = $selBh->fetchall_arrayref; 
		
		$N_row = $#{$table_battuta};
		$j = $N_row;
		$k= 0; #contatore
		
		$d_E1 =600;
		
		if ($j>=0)
		{
			while (($d_E1 > 500) && ($k < 8) && ($j >= 0) && ($table_battuta->[$j][2] < $H_aerop+2000) #450) modified teo
			)
			{
				# calcola la distanza dell' ultima battuta radar dalla pista EST
				$d_E1 = &distance ($X14, $Y14,$X32, $Y32, $table_battuta->[$j][0],$table_battuta->[$j][1]);

				$k++;
				$j--;
			}
	
			if (($k < 9) && ($j >= -1) && $table_battuta->[$j][2] < $H_aerop+2000) #450) modified teo
			{
				if($j >= 0)
				{
					if ($table_battuta->[$j][0] > $table_battuta->[$j +1][0]) {$pista = '32';}
					else	{$pista = '14';}
				}
			}
			else	{$pista = 'NA';}
		}
		else	{$pista = 'NA';}
		$rc = $selBh->finish;
		print "flayid\t$fl_id\n";
		if ($pista eq '32' || $pista eq '14')
		{
			$up_track = "UPDATE flay SET pista = '$pista', sid = '$pista' WHERE row_id = '$fl_id'";
		}
		else
		{
			$up_track = "UPDATE flay SET pista = '$pista', validation_fl = 'P', validation_bt = 0 WHERE row_id = '$fl_id'";
			print (FILEOUTPUT "Non assegnata pista -> $pista  alla Traccia N. $fl_id\n");
		}
		$errstr=$db_radar->errstr;
		$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
		$errstr=$upTh->errstr;
		$rv = $upTh->execute || die "can't execute the query: $errstr";
		#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
		$rc = $upTh->finish;
	}
}
#************************************* FINE ALGORITMO PER MONTICHIARI *****************************************
#**************************************************************************************************************

if ($aeroporto ne 'LIMC' && $aeroporto ne 'LIML' && $aeroporto ne 'LIME' && $aeroporto ne 'LIPO')
{
	die "SIGLA AEROPORTO NON CORRETTA"
}


$sel_report= "SELECT pista, count(*) FROM flay WHERE flay_operation='A' AND pista IS NOT NULL  GROUP BY pista";
$sel_report_h=$db_radar->prepare($sel_report);
$rv=$sel_report_h->execute;

print "\n\n\n";
print (FILEOUTPUT "\n\n\n");

while(@report=$sel_report_h->fetchrow_array)
{

	print "\t@report\n";
	print (FILEOUTPUT "\t@report\n");
}

@data_oraE=localtime(time);
$data_oraE[4]=$data_oraE[4]+1;
$data_oraE[5]=$data_oraE[5]+1900;
$secondidelta = (3600*$data_oraE[2] + 60*$data_oraE[1] + $data_oraE[0])-(3600*$data_ora[2] + 60*$data_ora[1] + $data_ora[0]);
print (FILEOUTPUT "$data_oraE[3]/$data_oraE[4]/$data_oraE[5]\t$data_oraE[2]:$data_oraE[1]:$data_oraE[0]\n***** TROVA_PISTA_ATTERRAGGI FINE*****\n");
print (FILEOUTPUT "secondi trascorsi =  $secondidelta\n");
print "secondi trascorsi $secondidelta\n";
close (FILEOUTPUT);

###############################################################################
#########################################   FUNZIONI ##########################
###############################################################################

### DISTANZA DI UN PUNTO DA UNA RETTA (ASSEGNATA CON DUE PUNTI)
sub distance 
{
	my ($X1, $Y1, $X2, $Y2, $x, $y, $m, $q, $distance);
	($X1, $Y1, $X2, $Y2, $x, $y) = @_;
	$a=$Y2-$Y1;
	$b=$X1-$X2;
	$c=$X1*($Y1-$Y2)+$Y1*($X2-$X1);

	$distance = ($a*$x + $b*$y + $c)/(($a**2+$b**2)**0.5);
	$distance =abs($distance);
	return $distance;
}
