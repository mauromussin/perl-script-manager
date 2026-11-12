###############################################################################################
#
# Title:	VALIDA TRACCE
# Author:	Bartolomeo Telaro
# Date:		????-??-??
# Revision:  	2004-06-10  by  Matteo Giampaolo
# 
# Comment:	Controlla che una traccia abbia almeno 4 battute e che una battuta sia in un intorno 
#		dell'areoporto  ad una quota ragionevole
#		se si pone flay.validation_fl = 'Y'
#		se no pone flay.validation_fl = 'N' e pone ad A il campo validation di tutte le battute
#		della traccia.
#
# Table usate:		flay, battute, anagrafica.aeroporti 
#
###############################################################################################

if ($ARGV[0] eq '/help')
{
print 	"\n\n\n#########################################################################################
######												########
###### INPUT RICHIESTO A VIDEO: DATABASE; SIGLA_AEROPORTO; USERNAME; PASSWORD 	########
######										########
###### AGISCE SU flay where (validation_fl IS NULL)				########
######										########
###### PONE validation_fl='Y' o 'N' 						########
######										########
###### UNA TRACCIA E'NON VALIDA SE NON HA NEMMENO UNA BATTUTA A MENO DI 10km    ########
###### DI DISTANZA DAL CENTRO DELL'AEROPORTO E CONTEMPORANEAMENTE A MENO DI     ########
###### 1000m DI QUOTA SOPRA IL LIVELLO DELL'AEROPORTO.				########
######										########
########################################################################################\n\n\n";
die;
}

$db_radar;
$sel_on_flay;
$sel_flay_h;
$rv;
@row_Fl;
@row_Bt;

$offset_BGY = - 376; ## OFFSET da settare sull' aeropoerto di orio
print "\n ATTENZIONE SULLA Y DI ORIO E' SETTATO UN OFFSET = $offset\n se vuoi cambiare tale parametro edita la variabile corrispondente all'inizio dello script\n\n";


###############################################################################################

print "INSERIRE L'INDIRIZZO DELLA MACCHINA SU CUI RISIEDE IL DB (localhost se vuoto): ";
$IP=<STDIN>;
chomp($IP);
if ($IP eq '')
{$IP='localhost';}
print "INSERIRE IL NOME DEL DATABASE: ";
$db=<STDIN>;
chomp($db);
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


$db_radar = DBI->connect("DBI:mysql:$db:$IP", $nome_utente, $password) ||  
die "\n\n\n  -- FATAL ERROR :  Non mi posso connettere al database:$DBI::errstr\n\n\n";
  
$B = length($db);
print "\n\n\t\t";
for ($L=0; $L < $B; $L++){print"*";}
print "********************************************** \n";
print "\t\t****    CONNECTION TO DB '$db' SUCCESSFUL    **** \n\t\t";
for ($L=0; $L < $B; $L++){print"*";}
print "********************************************** \n\n\n\n\n\n";

#########################################################################


@data_ora=localtime(time);
$data_ora[4]=$data_ora[4]+1;
$data_ora[5]=$data_ora[5]+1900;

$nomefileOUT = "report\\03-Valida_Tracce_01\_$db\_$nome_utente\_$data_ora[3]-$data_ora[4]-$data_ora[5]\_$data_ora[2]-$data_ora[1]-$data_ora[0].log";
open(FILEOUTPUT,'>>',$nomefileOUT);
print "**** VALIDA_TRACCE *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n";

print (FILEOUTPUT "***** VALIDA TRACCE *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n");
print (FILEOUTPUT "\n\n\t\t");
for ($L=0; $L < $B; $L++){print(FILEOUTPUT "*");}
print (FILEOUTPUT "********************************************** \n");
print (FILEOUTPUT "\t\t****    CONNECTION TO DB '$db' SUCCESSFUL    **** \n\t\t");
for ($L=0; $L < $B; $L++){print(FILEOUTPUT "*");}
print (FILEOUTPUT "********************************************** \n\n\n\n");


$sel_on_aeroporti = "SELECT LONG_aerop,LAT_aerop,QUOTA_aerop FROM anagrafica.aeroporti WHERE nome_aerop = '$aeroporto'";
$errstr=$db_radar->errstr;
$sel_on_aeroporti_h = $db_radar->prepare($sel_on_aeroporti) || die "Can't prepare $statement: $errstr\n";
$errstr=$sel_on_aeroporti_h->errstr;
$rv1 = $sel_on_aeroporti_h->execute || die "can't execute the query: $errstr";

$row_aeroporti = $sel_on_aeroporti_h->fetchall_arrayref;
$X_aerop=$row_aeroporti->[0][0];
$Y_aerop=$row_aeroporti->[0][1];
$H_aerop=$row_aeroporti->[0][2];

if ($aeroporto eq LIME)
{
	$Y_aerop = $Y_aerop + $offset_BGY;
	print "\n ATTENZIONE SULLA Y DI ORIO E' SETTATO UN OFFSET = $offset_BGY";
}

#############  estrae la row_id di tutte le tracce non ancora validate ####################################
$sel_on_flay = "SELECT row_id FROM flay where validation_fl IS NULL";
$errstr=$db_radar->errstr;
$sel_flay_h = $db_radar->prepare($sel_on_flay) || die "Can't prepare $statement: $errstr\n";
$errstr=$sel_flay_h->errstr;
$rv = $sel_flay_h->execute || die "can't execute the query: $errstr";
$rv == 0 && print (FILEOUTPUT "\nNON CI SONO TRACCE NON PROCESSATE");

############ per ogni traccia estrae del DB tutte le battute corrispondenti ###################
while(@row_Fl = $sel_flay_h->fetchrow_array)
{
	$fl_id = $row_Fl[0];
	print "traccia $fl_id\n";
	$sel_on_batt = "SELECT X_m,Y_M,H_m FROM battute WHERE flay_id = '$fl_id'";
	$errstr=$db_radar->errstr;
	$sel_batt_h = $db_radar->prepare($sel_on_batt) || die "Can't prepare $statement: $errstr\n";
	$errstr=$sel_batt_h->errstr;
	$rv1 = $sel_batt_h->execute || die "can't execute the query: $errstr";
	
	
	if ($rv1 < 4)
	{
		print "\n LA TRACCIA $fl_id ha meno di 4 battute\n";
		push(@flay_invalid,$fl_id); 
	}
	else ## controlla che la traccia abbia almeno una batutta nell'intorno dell'areoporto ad un altezza accettabile
	{
		$i=0;
		while ((@row_Bt = $sel_batt_h->fetchrow_array) && ((&distanza_aerop($row_Bt[0],$row_Bt[1]) > 10000) || ($row_Bt[2] > ($H_aerop+1000)) )) 
		{}
		
		if(@row_Bt == '') 	# salva in un array la row_id dell traccia non validata
		{
			push(@flay_invalid,$fl_id);
		}
		else {if ($i==0) {push(@flay_valid,$fl_id); $i++;}}
	}
	$sel_batt_h->finish;
}
$sel_flay_h->finish;

### fa un update di tutte le tracce analizzate

while ($flay_in = pop(@flay_valid) )
{
	$up_on_flay = "UPDATE flay SET validation_fl = 'Y' where row_id = '$flay_in'";
	$errstr=$db_radar->errstr;
	$up_on_flay_h = $db_radar->prepare($up_on_flay) || die "Can't prepare $statement: $errstr\n";
	$errstr=$up_on_flay_h->errstr;
	$rv = $up_on_flay_h->execute || die "can't execute the query: $errstr";
	$up_on_flay_h->finish;
	
	#print "VALIDATA TRACCIA N.\t$flay_in\n";
	#print (FILEOUTPUT "VALIDATA TRACCIA N.\t$flay_in\n");
}

while ($flay_in = pop(@flay_invalid) )
{
	$up_on_flay = "UPDATE flay SET validation_fl = 'N' where row_id = '$flay_in'"; ## nb validation_bt a 0 cosi su quete tracce non girerà  il valida battute
	$errstr=$db_radar->errstr;
	$rv = $db_radar->do($up_on_flay) || die "Can't prepare $statement: $errstr\n";
	
	$up_on_battute = "UPDATE battute SET validation = 'A' where flay_id = '$flay_in'";
	$errstr=$db_radar->errstr;
	$rv = $db_radar->do($up_on_battute) || die "Can't prepare $statement: $errstr\n";
	
	print "NON VALIDATA TRACCIA N.\t$flay_in\n";
	print (FILEOUTPUT "NON VALIDATA TRACCIA N.\t$flay_in\n");
}


$sel_report= "SELECT validation_fl, count(*) FROM flay WHERE validation_bt is NULL GROUP BY validation_fl";
$sel_report_h=$db_radar->prepare($sel_report);
$rv=$sel_report_h->execute;

while(@report=$sel_report_h->fetchrow_array)
{
	print "\nvalidation_fl:\n@report\n";
	print (FILEOUTPUT "VALIDATION_FL : @report\n");
}


$sel_report_h->finish;


@data_oraE=localtime(time);
$data_oraE[4]=$data_oraE[4]+1;
$data_oraE[5]=$data_oraE[5]+1900;

$secondidelta = (3600*$data_oraE[2] + 60*$data_oraE[1] + $data_oraE[0])-(3600*$data_ora[2] + 60*$data_ora[1] + $data_ora[0]);

print (FILEOUTPUT "$data_oraE[3]/$data_oraE[4]/$data_oraE[5]\t$data_oraE[2]:$data_oraE[1]:$data_oraE[0]\n**** CARICA_DB FINE *****\n");
print (FILEOUTPUT "secondi trascorsi =  $secondidelta\n");
print "secondi trascorsi $secondidelta\n";
close (FILEOUTPUT);

###########################################################################################################
########## funzione che calcola la distanza di un punto dal centro dell'aeroporto specificato #############

sub distanza_aerop
{
	my ($X,$Y,$distanza);
	($X,$Y) = @_;
	
	$distanza = ((($Y-$Y_aerop)**2+($X-$X_aerop)**2)**(0.5));
	return $distanza;
}
