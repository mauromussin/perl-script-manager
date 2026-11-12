###############################################################################################
#
# Title:	rettifica quote nulle
# Author:	Fabio Forfori
# Date:		perso nella notte dei tempo
# Revision: 	2005-11-29	Bartolomeo Telaro
#		2007-02-22	Bartolomeo Telaro
#		
# Comment:	Analizza le tracce (decolli) con validation_bt = 1 e pista assegnata
#		cioè su cui hanno girato correttamente tutti gli script di validazione
#		e cerca di interpolare la battute la cui altezza è uguale a zero
#
# Table usate:		flay, battute
#
###############################################################################################

use DBI; # carica la libreria DBI per connettersi con il DB

#####################  VARIABILI ######################################################
$battute_interpolate =  0;

#######################################################################################

if ($ARGV[0] eq '/help')
{
print 	"\n\n\n#########################################################################
######										########
######  INPUT RICHIESTO A VIDEO: DATABASE; USERNAME; PASSWORD 			########
######										########
######	RETTIFICA I PUNTI PRIVI DI INFORMAZIONE SULLA QUOTA (H_m=0) 		########
######  INTERPOLANDO LA QUOTA TRA I PUNTI PRECEDENTE E SUCCESSIVO VALIDATI.	########
######										########
######  PONE A 'M' IL CAMPO hmod DI battute SE LA QUOTA E' STATA MODIFICATA, 	########
######  ALTRIMENTI LO LASCIA A NULL. 						########
######										########
######	IN OGNI CASO SCRIVE LA QUOTA CORRETTA O MODIFICATA NEL CAMPO Z_m	########
######										########
######	NON PROCESSA I PUNTI IN CUI IL CAMPO hmod E' GIA UGUALE A 'M'		########
######										########
########################################################################################\n\n\n";
die;
}

print "INSERIRE L'INDIRIZZO DELLA MACCHINA SU CUI RISIEDE IL DATABASE: ";
$IP=<STDIN>;
chomp($IP);
if ($IP eq '') {$IP='localhost';}

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


$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) || 
die "Non mi posso connettere al database:$DBI::errstr\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

@data_ora=localtime(time);
$data_ora[4]=$data_ora[4]+1;
$data_ora[5]=$data_ora[5]+1900;

$nomefileOUT = "report\\08rettifica_quote_nulle-$database\_$nome_utente\_$data_ora[3]-$data_ora[4]-$data_ora[5]\_$data_ora[2]-$data_ora[1]-$data_ora[0].log";
open(FILEOUTPUT,'>>',$nomefileOUT);
print "\n\n**** RETTIFICA_QUOTE_NULLE *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n";
print (FILEOUTPUT "***** RETTIFICA_QUOTE_NULLE *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n");

$sel_on_flay = "SELECT row_id FROM flay WHERE validation_bt = 1 AND pista IS NOT NULL";  # seleziono tutte le tracce che non sono invalidate
$sel_flay_h = $db_radar->prepare($sel_on_flay) || die "Can't prepare $statement: $db_radar->errstr\n";
$rv = $sel_flay_h->execute || die "can't execute the query: $sel_flay_h->errstr";

$up_flay = "UPDATE FLAY SET validation_bt = 2 WHERE row_id = ?";
$up_flay_h = $db_radar->prepare($up_flay) || die "Can't prepare $statement: $db_radar->errstr\n";

##########################################################################
##########################################################################
##### 	INIZIO CICLO PRINCIPALE: SCORRE LE BATTUTE DI CIASCUNA TRACCIA ###
##########################################################################
##########################################################################

ciclo1:
while(@row_Fl = $sel_flay_h->fetchrow_array)
{
	$fl_id = $row_Fl[0];
	print "tr $fl_id\n";
	$sel_on_batt = "SELECT row_id,X_m,Y_m,H_m,validation,hmod FROM battute 
			WHERE flay_id = '$fl_id' and validation != 'N' and validation != 'A' and validation != 'S'";
	$sel_batt_h = $db_radar->prepare($sel_on_batt) || die "Can't prepare $statement: $db_radar->errstr\n";
	$rv1 = $sel_batt_h->execute || die "can't execute the query: $sel_batt_h->errstr";

	$table_battuta=$sel_batt_h->fetchall_arrayref;
	
	$succ1=0;
	
	if ($#{$table_battuta}<2)
	{
		next;
	}
	
	#CONTROLLO DELLA PRIMA BATTUTA
	
	if ($table_battuta->[0][5] ne 'M' and $table_battuta->[0][3]==0) 	# processa solo le battute che hanno il campo hmod diverso 'M' ovverro su cui non ha gia girato questo script
	{
		#print "controllo prima battuta $table_battuta->[0][0]\n";
		# CERCA BATTUTA SUCCESSIVA VALIDATA
		for ($i=1; $i<=$#{$table_battuta}; $i++)
		{
			if ($table_battuta->[$i][3]!=0)
			{
				$z_succ1=$table_battuta->[$i][3];
				$s_succ1=&distanza2($table_battuta->[0][1],$table_battuta->[0][2],
						    $table_battuta->[$i][1],$table_battuta->[$i][2]);
				$succ1=$i;

				if(($i==$#{$table_battuta}) && ($succ1==0))
				{
					print (FILEOUTPUT "TUTTE LE BATTUTE DELLA TRACCIA $fl_id HANNO QUOTA NULLA!");
					die "TUTTE LE BATTUTE DELLA TRACCIA $fl_id HANNO QUOTA NULLA!";
				}

				$i=$#{$table_battuta};
			}
		}

		# CERCA ULTERIORE BATTUTA SUCCESSIVA VALIDATA
		for ($i=$succ1+1; $i<=$#{$table_battuta}; $i++)
		{
			if ($table_battuta->[$i][3]!=0)
			{
				$z_succ2=$table_battuta->[$i][3];
				$s_succ2=&distanza2($table_battuta->[$succ1][1],$table_battuta->[$succ1][2],
						    $table_battuta->[$i][1],$table_battuta->[$i][2]);
				$i=$#{$table_battuta};
			}
		}
		if ($s_succ2 != 0)
		{
			$z_nuova = $z_succ1-$s_succ1*(($z_succ2-$z_succ1)/($s_succ2));
		}
		else 
		{
			$row_id_strana = $table_battuta->[0][0];
			$z_nuova = $z_succ1;
			print (FILEOUTPUT "controlla battuta $row_id_strana\n");
		}
		if ($z_nuova < 0) {$z_nuova = 0};

		####	AGGIORNAMENTO DATABASE ####
		$battute_interpolate++;
		$rett_quota= "UPDATE battute SET Z_m = $z_nuova, hmod='M' WHERE row_id = $table_battuta->[0][0]";
		$rett_quota_h = $db_radar->prepare($rett_quota) || die "Can't prepare $statement: $db_radar->errstr\n";
		$rv = $rett_quota_h->execute || die "can't execute the query: $rett_quota_h->errstr";
		$rett_quota_h->finish;
	}	
	
	#CONTROLLO DELLE BATTUTE SUCCESSIVE
	for ($j=1; $j<=$#{$table_battuta}-1; $j++)
	{
		#print "controllo battue succesiva $table_battuta->[$j][0]\n";
		if ($table_battuta->[$j][5] ne 'M' and $table_battuta->[$j][3]==0)
		{	
			# CERCA BATTUTA PRECEDENTE VALIDATA
			for ($i=1; $i<=$j; $i++)
			{
				if ($table_battuta->[$j-$i][3]!=0)
				{
					$z_prec=$table_battuta->[$j-$i][3];
					$s_prec=&distanza2($table_battuta->[$j][1],$table_battuta->[$j][2],
							   $table_battuta->[$j-$i][1],$table_battuta->[$j-$i][2]);
					$i=$j+1; #esce dal ciclo for
				}
			}

			# CERCA BATTUTA SUCCESSIVA VALIDATA
			for ($i=1; $i<=$#{$table_battuta}-$j-1; $i++)
			{
				if ($table_battuta->[$j+$i][3]!=0)
				{
					$z_succ=$table_battuta->[$j+$i][3];
					$s_succ=&distanza2($table_battuta->[$j][1],$table_battuta->[$j][2],
							   $table_battuta->[$j+$i][1],$table_battuta->[$j+$i][2]);
					$i=$#{$table_battuta}-$j; #esce dal ciclo for
				}
			}
			$s_all = $s_succ + $s_prec;
			if ($s_all != 0)
			{
				$z_nuova=$z_prec+($s_prec/($s_succ+$s_prec))*($z_succ-$z_prec);
			}
			else
			{
				$z_nuova = $z_prec;
				$row_id_strana = $table_battuta->[$j][0];
				print (FILEOUTPUT "controlla battuta $row_id_strana\n");
			}
			if ($z_nuova < 0) {$z_nuova = 0};
			####	AGGIORNAMENTO DATABASE ####
			$battute_interpolate++;
			$rett_quota= "UPDATE battute SET Z_m = $z_nuova , hmod = 'M' WHERE row_id = $table_battuta->[$j][0]";
			$rett_quota_h = $db_radar->prepare($rett_quota) || die "Can't prepare $statement: $db_radar->errstr\n";
			$rv = $rett_quota_h->execute || die "can't execute the query: $rett_quota_h->errstr";
			$rett_quota_h->finish;
		}
	}
	
	$prec1=0;
	
	#CONTROLLO DELL'ULTIMA BATTUTA
	
	if ($table_battuta->[$#{$table_battuta}][5] ne 'M' and $table_battuta->[$#{$table_battuta}][3]==0)
	{

		# CERCA BATTUTA PRECEDENTE VALIDATA
		for ($i=1; $i<=$#{$table_battuta}; $i++)
		{
			if ($table_battuta->[$#{$table_battuta}-$i][3]!=0)
			{
				$z_prec1=$table_battuta->[$#{$table_battuta}-$i][3];
				$s_prec1=&distanza2($table_battuta->[$#{$table_battuta}][1],$table_battuta->[$#{$table_battuta}][2],
						    $table_battuta->[$#{$table_battuta}-$i][1],$table_battuta->[$#{$table_battuta}-$i][2]);
				$prec1=$i;

				if(($i==$#{$table_battuta}) && ($prec1==0))
				{
					die "TUTTE LE BATTUTE DELLA TRACCIA $fl_id HANNO QUOTA NULLA!";
				}

				$i=$#{$table_battuta};
			}
		}

		# CERCA ULTERIORE BATTUTA SUCCESSIVA VALIDATA
		for ($i=$prec1+1; $i<=$#{$table_battuta}; $i++)
		{
			if ($table_battuta->[$#{$table_battuta}-$i][3]!=0)
			{
				$z_prec2=$table_battuta->[$#{$table_battuta}-$i][3];
				$s_prec2=&distanza2($table_battuta->[$#{$table_battuta}-$prec1][1],$table_battuta->[$#{$table_battuta}-$prec1][2],
						    $table_battuta->[$#{$table_battuta}-$i][1],$table_battuta->[$#{$table_battuta}-$i][2]);
				$i=$#{$table_battuta};
			}
		}
		if ($s_prec2 != 0)
		{
			$z_nuova=$z_prec1+($s_prec1/($s_prec2))*($z_prec1-$z_prec2);
		}
		else
		{
			$z_nuova = $z_prec1;
			$row_id_strana = $table_battuta->[$j][0];
			print (FILEOUTPUT "controlla battuta $row_id_strana\n");
		}
		if ($z_nuova < 0) {$z_nuova = 0}
		####	AGGIORNAMENTO DATABASE ####
		$battute_interpolate++;
		$rett_quota="UPDATE battute SET Z_m=$z_nuova, hmod='M' WHERE row_id = $table_battuta->[$#{$table_battuta}][0]";
		$rett_quota_h = $db_radar->prepare($rett_quota) || die "Can't prepare $statement: $db_radar->errstr\n";
		$rv = $rett_quota_h->execute || die "can't execute the query: $rett_quota_h->errstr";
		$rett_quota_h->finish;		
	}
	$rv = $up_flay_h->execute($fl_id)|| die "can't execute the query: $up_flay_h->errstr";
}
$sel_flay_h->finish;

##########################################################################
##########################################################################
##### 	FINE CICLO PRINCIPALE ############################################
##########################################################################
##########################################################################

print "sono state modificate $battute_interpolate quote\n";
print (FILEOUTPUT "sono state modificate $battute_interpolate quote\n");

@data_oraE=localtime(time);
$data_oraE[4]=$data_oraE[4]+1;
$data_oraE[5]=$data_oraE[5]+1900;
$secondidelta = (3600*$data_oraE[2] + 60*$data_oraE[1] + $data_oraE[0])-(3600*$data_ora[2] + 60*$data_ora[1] + $data_ora[0]);
print (FILEOUTPUT "$data_oraE[3]/$data_oraE[4]/$data_oraE[5]\t$data_oraE[2]:$data_oraE[1]:$data_oraE[0]\n***** RETTIFICA QUOTE NULLE FINE*****\n");
print (FILEOUTPUT "secondi trascorsi =  $secondidelta\n");
print "secondi trascorsi $secondidelta\n";
close (FILEOUTPUT);

###############################  FUNZIONI ##################################

sub distanza2	### DISTANZA 2D	### 
{
	my ($X1, $Y1, $X2, $Y2, $distanza2);
	($X1,$Y1,$X2,$Y2) = @_;
	$distanza2=((($X1-$X2)**2+($Y1-$Y2)**2)**(0.5));
	return $distanza2;
}
