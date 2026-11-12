###############################################################################################
#
# Title:	trova pista decolli
# Author:	Bartolomeo Telaro, Matteo Giampaolo, Fabio Forfori
# Date:		perso nella notte dei tempo
# Revision:  	2020-11-13  	Roberta Pollini con inserimento algoritmo per Montichiari
#		2007-02-22	Bartolomeo Telaro
#		
# Comment:	Analizza le tracce (decolli) con validation_bt = 1 (su cui ha girato positivamete il valida battute)
#		assegna la pista, se non riesca ad ssegnare la pista invalida la traccia, 
#		ponendo validation_fl = 'P' e validation_bt = 0
#
# Table usate:		flay, battute, anagrafica.aeroporti 
#
###############################################################################################

if ($ARGV[0] eq '/help')
{
print 	"\n\n\n#################################################################################################
######	ASSEGNA UNA PISTA ALLE TRACCE PRECEDENTEMENTE VALIDATE, UTILIZZANDO LE BATTUTE VALIDATE 	########
######	MALPENSA: Assegna alle tracce relative ai decolli la pista presumibilmente utilizzata  	########
######	(35L, 35R, 17L, 17R). L'algoritmo calcola la distanza della prima e della seconda		########
######	battuta della traccia radar dalle due piste e assegna la traccia alla pista piu' 		########
######  vicina, nel caso le due battute siano discordanti non assegna la traccia (NA).	 		########
######  Riconosce se il decollo avviene da nord o da sud confrontando la latitudine 		 	########
######	delle prime due battute.								 	########
######  LINATE: Assegna alle tracce relative ai decolli la pista presumibilmente utilizzata  		########
######	(36R, 18L) valutando il segno della differenza delle latitudini delle prime due battute 	########
######  (purchè queste siano sufficientemente vicine alla pista)					########
######  ORIO: Assegna alle tracce relative ai decolli la pista presumibilmente utilizzata  		########
######	(11, 29) valutando il segno della differenza delle longitudini delle prime due battute 		########
######  (purchè queste siano sufficientemente vicine alla pista)					########
################################################################################################################\n\n\n";
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

$db_radar = DBI->connect("DBI:mysql:$database:$IP",$nome_utente,$password) || 
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

$nomefileOUT = "report\\06pistadecolli-$database\_$nome_utente\_$data_ora[3]-$data_ora[4]-$data_ora[5]\_$data_ora[2]-$data_ora[1]-$data_ora[0].log";
open(FILEOUTPUT,'>>',$nomefileOUT);
print "\n\n**** TROVA PISTA DECOLLI*****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n";
print (FILEOUTPUT "***** TROVA PISTA DECOLLI *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n");

print (FILEOUTPUT "\n\n\t\t");
for ($L=0; $L < $B; $L++){print(FILEOUTPUT "*");}
print (FILEOUTPUT "********************************************** \n");
print (FILEOUTPUT "\t\t****    CONNECTION TO DB '$database' SUCCESSFUL    **** \n\t\t");
for ($L=0; $L < $B; $L++){print(FILEOUTPUT "*");}
print (FILEOUTPUT "********************************************** \n\n\n\n");

$sel_track = "SELECT row_id FROM flay WHERE flay_operation = 'D' AND validation_bt = 1 AND pista IS NULL";
$errstr=$db_radar->errstr;
$selTh = $db_radar->prepare($sel_track) || die "Can't prepare $statement: $errstr\n";
$errstr=$selTh->errstr;
$rv = $selTh->execute || die "can't execute the query: $errstr\n";
$rv == 0 && die "\n non ci sono tracce non assegnate \n ";

$sel_batt = "SELECT X_m, Y_m, H_m FROM battute WHERE flay_id = ? AND validation = 'Y' ORDER BY time_italy";
$selBh = $db_radar->prepare($sel_batt) || die "Can't prepare $statement: $db_radar->errstr\n";


$sel_on_aeroporti = "SELECT LONG_aerop,LAT_aerop,QUOTA_aerop FROM anagrafica.aeroporti WHERE nome_aerop = '$aeroporto'";
$errstr=$db_radar->errstr;
$sel_on_aeroporti_h = $db_radar->prepare($sel_on_aeroporti) || die "Can't prepare $statement: $errstr\n";
$errstr=$sel_on_aeroporti_h->errstr;
$rv1 = $sel_on_aeroporti_h->execute || die "can't execute the query: $errstr";

$row_aeroporti = $sel_on_aeroporti_h->fetchall_arrayref;
$X_aerop=$row_aeroporti->[0][0];
$Y_aerop=$row_aeroporti->[0][1];
$H_aerop=$row_aeroporti->[0][2];

#**************************************************************************************************************
#**************************************************************************************************************
#************************************* ALGORITMO PER MALPENSA *************************************************
#**************************************************************************************************************
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
		$pista = '';
		$fl_id = $row_T[0];

		$rv1 = $selBh->execute($fl_id) || die "can't execute the query: $selBh->errstr";
		$rv1 == 0 && print "\n non ci sono battute associate alla traccia $fl_id \n";

		$d_E1 =800;
		$d_W1 =800;

		$cont=0;

		@row1 = $selBh->fetchrow_array;

		# calcola la distanza della prima battuta radar dalla pista EST
		$d_E1 = &distance ($X1est, $Y1est,$X2est, $Y2est, $row1[0],$row1[1]);

		# calcola la distanza della prima battuta radar dalla pista OVEST
		$d_W1 = &distance ($X1ovest, $Y1ovest, $X2ovest, $Y2ovest, $row1[0],$row1[1]);

		if ((@row1 && $row1[2] < $H_aerop+2000)  && (&distanza_aerop($row1[0],$row1[1]) < 12000)) # se non sei arrivato alla fine delle battute 
		{
			if ($d_E1 < $d_W1) {$pista1 = 'EST';}
			elsif ($d_E1 > $d_W1) {$pista1 = 'WEST';}
			else {$pista1 = 'NA';}

			@row2 = $selBh->fetchrow_array;

			# calcola la distanza della seconda battuta dala pista EST
			$d_E2 = &distance ($X1est, $Y1est,$X2est, $Y2est, $row2[0],$row2[1]);

			# calcola la distanza della seconda battuta dalla pista OVEST
			$d_W2 = &distance ($X1ovest, $Y1ovest, $X2ovest, $Y2ovest, $row2[0],$row2[1]);

			if ($d_E2 < $d_W2)	{$pista2 = 'EST';}
			elsif ($d_E2 > $d_W2)	{$pista2 = 'WEST';}
			else {$pista2 = 'NA';}

			if ($pista1 eq $pista2)	{$pista = $pista1;}
			else {$pista = 'NA';}  # SE LE PRIME DUE BATTUTE DISCORDANO TRA DI LORO --> PISTA = 'NA'

			if ($pista eq 'EST')
			{
				if ($row1[1]<$row2[1])	{$pista = '35R';}
				else 			
				{
					$pista = '17L';
					if ($row1[0] > 1479860 && $row2[0] > 1479860 && $row1[1] > 5053558 && $row2[1] > 5053558)
					{$pista = '35R'}
				}
			}
		
			if ($pista eq 'WEST')
			{
				if ($row1[1]<$row2[1]) {$pista = '35L';}
				else 
				{
					$pista = '17R';
					if ($row1[0] < 1477801 && $row2[0] < 1477801 && $row1[1] > 5053077 && $row2[1] > 5053077)
					{$pista = '35L'}
				}
			}
		}
		else
		{
			$pista = 'N';
		}	# TRACCIA CON PRIMA BATTUTA DISTANTE PIU' DI 12 Km O AD ALTEZZA MAGGIORE DI 2000 Mt RISPETTO ALL'ALTEZZA DELL'AEROPORTO
		if (($row1[1] eq $row2[1]) && ($row1[1]<5055500 && $row1[1]>5050500 && $row1[0]<1480100 && $row1[0]>1477600)
	                             && ($row2[1]<5055500 && $row2[1]>5050500 && $row2[0]<1480100 && $row2[0]>1477600))
		{
			$pista = 'N1';	# TRACCIA CON LE PRIME 2 BATTUTE PERPENDICOLARE ALLA PISTA
		}
		
		# TROVA TRACCE CON BATTUTE SOLO IN MEZZO ALLE PISTE (pone PISTA = N2)
		$H = 0 ;

		@A_taxi=(1478955,5050890);
		@B_taxi=(1478202,5054817);
		@C_taxi=(1478830,5054817);
		@D_taxi=(1479537,5050890);

		$mAB_taxi=($A_taxi[1]-$B_taxi[1])/($A_taxi[0]-$B_taxi[0]);
		$mBC_taxi=($B_taxi[1]-$C_taxi[1])/($B_taxi[0]-$C_taxi[0]);
		$mCD_taxi=($C_taxi[1]-$D_taxi[1])/($C_taxi[0]-$D_taxi[0]);
		$mDA_taxi=($D_taxi[1]-$A_taxi[1])/($D_taxi[0]-$A_taxi[0]);

		$qAB_taxi=$B_taxi[1]-$mAB_taxi*$B_taxi[0];
		$qBC_taxi=$C_taxi[1]-$mBC_taxi*$C_taxi[0];
		$qCD_taxi=$D_taxi[1]-$mCD_taxi*$D_taxi[0];
		$qDA_taxi=$A_taxi[1]-$mDA_taxi*$A_taxi[0];
		while (@row3 = $selBh->fetchrow_array)
		{
			if (($row3[1]<$mAB_taxi*$row3[0]+$qAB_taxi) ||
			($row3[1]>$mBC_taxi*$row3[0]+$qBC_taxi) ||
			($row3[1]>$mCD_taxi*$row3[0]+$qCD_taxi) ||
			($row3[1]<$mDA_taxi*$row3[0]+$qDA_taxi))	                
			{$H++};
		}
		if ($H == 0)
		{
			$pista = 'N2';
		} #TRACCE CON BATTUTE SOLO IN MEZZO ALLE PISTE (pone PISTA = N2)
		print "flayid\t$fl_id\n";
		$rc = $selBh->finish;
		
		if ($pista eq '35L' || $pista eq '35R' || $pista eq '17L' || $pista eq '17R')
		{
			$up_track = "UPDATE flay SET pista = '$pista' WHERE row_id = '$fl_id'";
		}
		else
		{
			$up_track = "UPDATE flay SET pista = '$pista', validation_fl = 'P', validation_bt = 0 WHERE row_id = '$fl_id'";
			print (FILEOUTPUT "Non assegnata pista -> $pista  alla Traccia N. $fl_id\n");
		}
		$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $db_radar->errstr\n";
		$rv = $upTh->execute || die "can't execute the query: $upTh->errstr";
		$rc = $upTh->finish;
	}
}
#************************************* FINE ALGORITMO PER MALPENSA ********************************************
#**************************************************************************************************************


#**************************************************************************************************************
#************************************* ALGORITMO PER LINATE   *************************************************
#**********************************(non considera la pista ovest)**********************************************
#**************************************************************************************************************
if ($aeroporto eq 'LIML')
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
	
	$H_aerop=$coord_piste->[0][2];
	
	$sel_on_piste_h->finish;
	
	while(@row_T = $selTh->fetchrow_array)
	{
		$fl_id = $row_T[0];
		#print "traccia $fl_id\n";
		
		$rv1 = $selBh->execute($fl_id) || die "can't execute the query: $selBh->errstr";
		$rv1 == 0 && print "\n non ci sono battute associate alla traccia $fl_id \n";
		
		$cont= 0; #contatore
		$d_E1 =300;
		#### cerco la prima battute vicina alla pista (cosi da eliminare eventuali battute taxi che potrebbero assegnare la pista in maniera non corretta)
		while ((@row1 = $selBh->fetchrow_array) && ($d_E1 > 120) && ($row1[2] < $H_aerop+300))
		{
			# calcola la distanza dell' ultima battuta radar dalla pista EST
			$d_E1 = &distance ($X1est, $Y1est,$X2est, $Y2est, $row1[0],$row1[1]);
			$cont++;
		}

		if (@row1 && $row1[2] < $H_aerop+2000)
		{		
			@row2 = $selBh->fetchrow_array;
			if (@row2 eq '')
			{
				next;
				print "la traccia $fl_id ha una sola battuta prossima alla pista\n";
			}
			if ($row1[1]<$row2[1])	{$pista = '36R';}
			else			{$pista = '18L';
			
			if ($row1[1] > 5034500 && $row2[1] > 5034500)
			{$pista = '36R'}
			}
		}
		else	{$pista = 'NA';}
		$rc = $selBh->finish;
		print "flayid\t$fl_id\n";
		if ($pista eq '36R' || $pista eq '18L')
		{
			$up_track = "UPDATE flay SET pista = '$pista' WHERE row_id = '$fl_id'";
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
#************************************* FINE ALGORITMO PER LINATE   ********************************************
#**************************************************************************************************************


#**************************************************************************************************************
#************************************* ALGORITMO PER ORIO *****************************************************
#**************************************************************************************************************

if ($aeroporto eq 'LIME')
{
	print "\n******  ATTENZIONE E' IMPOSTATO UN OFFSET SULLA LATITUDINE DELLE PISTE \n******  CONTINUARE? (Y,N)\n";
	$risposta=<STDIN>;
	chomp($risposta);
	if ($risposta ne 'Y' && $risposta ne 'y') {die "per cambiare l' offest digita lo script o contatta Fabio\n\n";}

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

	while(@row_T = $selTh->fetchrow_array)
	{
		$fl_id = $row_T[0];
		#print "traccia $fl_id\n";
		
		$rv1 = $selBh->execute($fl_id) || die "can't execute the query: $selBh->errstr";
		$rv1 == 0 && print "\n non ci sono battute associate alla traccia $fl_id \n";
		
		$cont= 0; #contatore
		$d_E1 =600;
		
		#### cerco la prima battute vicina alla pista (cosi da eliminare eventuali battute taxi che potrebbero assegnare la pista in maniera non corretta)
		while ((@row1 = $selBh->fetchrow_array) && ($d_E1 > 500) && ($row1[2] < $H_aerop+450))
		{
			# calcola la distanza dell' ultima battuta radar dalla pista EST
			$d_E1 = &distance ($X11, $Y11,$X29, $Y29, $row1[0],$row1[1]);
			$cont++;
		}
		if (@row1 && $row1[2] < $H_aerop+800)
		{		
			@row2 = $selBh->fetchrow_array;
			if (@row2 eq '')
			{
				next;
				print "la traccia $fl_id ha una sola battuta prossima alla pista\n";
			}
			if ($row1[0]<$row2[0])	{$pista = '11';}
			else			{$pista = '29';}
		}
		else {$pista = 'NA';}
		$rc = $selBh->finish;

		print "flayid\t$fl_id\n";
		if ($pista eq '29' || $pista eq '11')
		{
			$up_track = "UPDATE flay SET pista = '$pista' WHERE row_id = '$fl_id'";
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
#************************************* ALGORITMO PER MONTICHIARI *****************************************************
#**************************************************************************************************************

if ($aeroporto eq 'LIPO')
{
	$sel_on_piste = "SELECT p.LONG_pista,p.LAT_pista, a.QUOTA_aerop FROM anagrafica.aeroporti as a, anagrafica.piste as p WHERE a.nome_aerop = '$aeroporto' and a.row_id = p.id_aerop";
	$errstr=$db_radar->errstr;
	$sel_on_piste_h = $db_radar->prepare($sel_on_piste) || die "Can't prepare $statement: $errstr\n";
	$errstr=$sel_on_piste_h->errstr;
	$rv1 = $sel_on_piste_h->execute || die "can't execute the query: $errstr";
	$coord_piste = $sel_on_piste_h->fetchall_arrayref;
	$X14=$coord_piste->[0][0];
	$Y14=$coord_piste->[0][1];
	$X32=$coord_piste->[1][0];
	$Y32=$coord_piste->[1][1];
	$H_aerop=$coord_piste->[0][2];
	$sel_on_piste_h->finish;

	while(@row_T = $selTh->fetchrow_array)
	{
		$fl_id = $row_T[0];
		#print "traccia $fl_id\n";
		
		$rv1 = $selBh->execute($fl_id) || die "can't execute the query: $selBh->errstr";
		$rv1 == 0 && print "\n non ci sono battute associate alla traccia $fl_id \n";
		
		$cont= 0; #contatore
		$d_E1 =600;
		
		#### cerco la prima battute vicina alla pista (cosi da eliminare eventuali battute taxi che potrebbero assegnare la pista in maniera non corretta)
		while ((@row1 = $selBh->fetchrow_array) && ($d_E1 > 500) && ($row1[2] < $H_aerop+450))
		{
			# calcola la distanza dell' ultima battuta radar dalla pista EST
			$d_E1 = &distance ($X14, $Y14,$X32, $Y32, $row1[0],$row1[1]);
			$cont++;
		}
		if (@row1 && $row1[2] < $H_aerop+800)
		{		
			@row2 = $selBh->fetchrow_array;
			if (@row2 eq '')
			{
				next;
				print "la traccia $fl_id ha una sola battuta prossima alla pista\n";
			}
			if ($row1[0]<$row2[0])	{$pista = '14';}
			else			{$pista = '32';}
		}
		else {$pista = 'NA';}
		$rc = $selBh->finish;

		print "flayid\t$fl_id\n";
		if ($pista eq '32' || $pista eq '14')
		{
			$up_track = "UPDATE flay SET pista = '$pista' WHERE row_id = '$fl_id'";
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

$sel_report= "SELECT pista, count(*) FROM flay WHERE flay_operation='D' AND pista IS NOT NULL AND sid IS NULL GROUP BY pista";
$sel_report_h=$db_radar->prepare($sel_report);
$rv=$sel_report_h->execute;
	
	print "\n\n\n";
	print (FILEOUTPUT "\n\n\n");
	
while(@report=$sel_report_h->fetchrow_array)
{

	print "\t@report\n";
	print (FILEOUTPUT "\t@report\n");
}

####################################  AGGIRNA IL CAMPO VALIDATION_FL della TABELLA FLAY #################

@data_oraE=localtime(time);
$data_oraE[4]=$data_oraE[4]+1;
$data_oraE[5]=$data_oraE[5]+1900;
$secondidelta = (3600*$data_oraE[2] + 60*$data_oraE[1] + $data_oraE[0])-(3600*$data_ora[2] + 60*$data_ora[1] + $data_ora[0]);
print (FILEOUTPUT "$data_oraE[3]/$data_oraE[4]/$data_oraE[5]\t$data_oraE[2]:$data_oraE[1]:$data_oraE[0]\n***** TROVA_PISTA_decolli FINE*****\n");
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

sub distanza_aerop
{
	my ($X,$Y,$distanza);
	($X,$Y) = @_;
	$distanza = ((($Y-$Y_aerop)**2+($X-$X_aerop)**2)**(0.5));
	return $distanza;
}
