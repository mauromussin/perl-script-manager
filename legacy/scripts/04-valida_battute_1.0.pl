###############################################################################################
#
# Title:	VALIDA TRACCE
# Author:	Fabio Forfori
# Date:		perso nella notte dei tempo
# Revision:  	????-??-??  	Bartolomeo Telaro
# 		????-??-??	Matteo Giampaolo
#		2007-02-22	Bartolomeo Telaro
#		
# Comment:	Analizza le tracce che hanno validation_fl = 'Y' e validation_bt NULL
#		controllando battuta per battuta
#		Aggiorna il campo data_ora_arr della tabella flay
#
# Table usate:		flay, battute, anagrafica.aeroporti 
#
###############################################################################################

if ($ARGV[0] eq '/help')
{
print 	"\n\n\n########################################################################################
######										########
###### INPUT RICHIESTO A VIDEO: DATABASE; SIGLA_AEROPORTO; USERNAME; PASSWORD 	########
######										########
###### MODIFICA IL CAMPO validation DELLA TABELLA battute			########
###### AGISCE SOLO SUI RECORD PER CUI validation IS NULL			########
######										########
###### LE BATTUTE VALIDATE SONO CONTRASSEGNATE DAL VALORE 'Y' DI validation	########
###### LE BATTUTE NON VALIDATE SONO CONTRASSEGNATE DAI VALORI 
######	'N'
######	'A' 
######	'S'
######	'T'									########
###### DI validation								########
######										########
###### PONE AD 'A' (ALL) TUTTE LE BATTUTE APPARTENENTI A TRACCE NON VALIDATE	########
######										########
###### SE TRA DUE BATTUTE CONSECUTIVE INTERCORRONO PIU' DI 60 SECONDI, LA	########
###### TRACCIA VIENE DETTA 'SPEZZATA' E IL CAMPO validation DI TUTTE LE BATTUTE ########
###### SUCCESSIVE (PRECEDENTI) VIENE POSTO A 'S' NEL CASO IL VOLO SIA UN DECOLLO########
###### (ATTERRAGGIO)								########
######										########
###### SE LA VELOCITA' DELL'AEROMOBILE E' MINORE DI 100 km/h IL CAMPO 		########
###### validation VIENE POSTO A 'T' (TAXI)					########
######										########
########################################################################################\n\n\n";
die;
}

$tot_battute_YES = 0;	#  contatote delle battute valide
$tot_battute_NO = 0;	# contatote battute invalide

#########################################################################################

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

@data_ora=localtime(time);
$data_ora[4]=$data_ora[4]+1;
$data_ora[5]=$data_ora[5]+1900;

$nomefileOUT = "report\\04-valida_battute_1.0.pl\_$db\_$nome_utente\_$data_ora[3]-$data_ora[4]-$data_ora[5]\_$data_ora[2]-$data_ora[1]-$data_ora[0].log";
open(FILEOUTPUT,'>>',$nomefileOUT);
print "**** VALIDA_BATTUTE *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n";

print (FILEOUTPUT "***** VALIDA_BATTUTE *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n");
print (FILEOUTPUT "***** VALIDA TRACCE *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n");
print (FILEOUTPUT "\n\n\t\t");
for ($L=0; $L < $B; $L++){print(FILEOUTPUT "*");}
print (FILEOUTPUT "********************************************** \n");
print (FILEOUTPUT "\t\t****    CONNECTION TO DB '$db' SUCCESSFUL    **** \n\t\t");
for ($L=0; $L < $B; $L++){print(FILEOUTPUT "*");}
print (FILEOUTPUT "********************************************** \n\n\n\n");


##########################################################################
##########################################################################

$sel_on_flay = "SELECT row_id, flay_operation FROM flay WHERE validation_bt IS NULL AND validation_fl = 'Y'";  
$sel_flay_h = $db_radar->prepare($sel_on_flay) || die "Can't prepare $statement: $db_radar->errstr\n";
$rv = $sel_flay_h->execute || die "can't execute the query: $sel_flay_h->errstr";

$soglia=500;	####	SOGLIA SULLA VELOCITA'	####

##########################################################################
##########################################################################
##### 	INIZIO CICLO PRINCIPALE: SCORRE LE BATTUTE DI CIASCUNA TRACCIA ###
##########################################################################
##########################################################################

ciclo1:
while(@row_Fl = $sel_flay_h->fetchrow_array)
{
	$fl_id = $row_Fl[0];
	$operation = $row_Fl[1];
	my @batt_invalid;
	my @batt_valid;
	
	#**********************************************************************
	#**** PULISCE LE BATTUTE A TERRA  (controllo sulle velocità)***********
	#**********************************************************************

	$sel_on_batt = "SELECT row_id, UNIX_TIMESTAMP(time_italy), X_m, Y_m FROM battute WHERE flay_id = '$fl_id'";
	$sel_batt_h = $db_radar->prepare($sel_on_batt) || die "Can't prepare $statement: $db_radar->errstr\n";
	$rv1 = $sel_batt_h->execute || die "can't execute the query: $sel_batt_h->errstr";

	$table_battuta=$sel_batt_h->fetchall_arrayref;

	for ($j=1; $j<=$#{$table_battuta}; $j++)	
	{
		$deltaT=abs($table_battuta->[$j][1]-$table_battuta->[$j-1][1]);
		$dist=&distanza2($table_battuta->[$j][2],$table_battuta->[$j][3],
				 $table_battuta->[$j-1][2],$table_battuta->[$j-1][3]);

		if ($deltaT==0 || $dist/$deltaT<28)  #  28 metri/sec  ---> 100 km/h
		{
			push(@batt_terra,$table_battuta->[$j][0]);
			if ($j==1)
			{
				push(@batt_terra,$table_battuta->[$j-1][0]);
			}
		}
	}

	while ($batt_terra = pop(@batt_terra))
	{
		$up_batt_terra= "UPDATE battute SET validation = 'T' WHERE row_id = '$batt_terra'";
		$up_batt_terra_h = $db_radar->prepare($up_batt_terra) || die "Can't prepare $statement: $db_radar->errstr\n";;
		$rv = $up_batt_terra_h->execute || die "can't execute the query: $up_on_flay_h->errstr";
		$up_batt_terra_h->finish;
	}

	$sel_batt_h->finish;
	#**********************************************************************
	#**********************************************************************

	
	############################################################################################
	#####	CONTROLLO DELLE TRACCE "SPEZZATE"###################################################
	############################################################################################
	
	if ($operation eq 'D')  	### SE DECOLLO  ORDINA PER ROW_ID CRESCENTE #######
	{
		$sel_on_batt = "SELECT row_id,UNIX_TIMESTAMP(time_italy) FROM battute WHERE flay_id = '$fl_id' AND validation IS NULL order by time_italy";
	}
	if ($operation eq 'A')		### SE ATTERRAGGIO ORDINA PER ROW_ID DECRESCENTE #######	
	{
		$sel_on_batt = "SELECT row_id,UNIX_TIMESTAMP(time_italy) FROM battute WHERE flay_id = '$fl_id' AND validation IS NULL order by time_italy desc";
	}
	
	$sel_batt_h = $db_radar->prepare($sel_on_batt) || die "Can't prepare $statement: $db_radar->errstr\n";
	$rv1 = $sel_batt_h->execute || die "can't execute the query: $sel_batt_h->errstr";
	
	### SE DUE BATTUTE DISTANO PIU' DI 60 SEC PONE VALIDATION='S' ######################
	### PER TUTTE LE BATTUTE SUCCESSIVE                           ######################
	
	$table_battuta = $sel_batt_h->fetchall_arrayref;
	for ($i=1; $i<=$#{$table_battuta}; $i++)
	{
	
	##############  NB  si potrebbe migliorare chiedendo di ivalidare le tracce prima o dopo a seconda della posizione della battuta spezzata
	####################   es se in un decollo la pezzatura avviene dopo 4 battute, magari vanno invalidate le battutre perima e non quelle dopo
	
		if(abs($table_battuta->[$i][1]-$table_battuta->[$i-1][1])>60)
		{	
			for ($j=$i; $j<=$#{$table_battuta}; $j++)
			{
				$up_on_batt= "UPDATE battute SET validation = 'S' 
					      WHERE row_id = '$table_battuta->[$j][0]'";
				$up_on_batt_h = $db_radar->prepare($up_on_batt) 
					      || die "Can't prepare $statement: $db_radar->errstr\n";;
				$rv = $up_on_batt_h->execute 
					      || die "can't execute the query: $up_on_flay_h->errstr";
				$up_on_batt_h->finish;
			}
			$i=$#{$table_battuta};
		}
	}
	$sel_batt_h->finish;								####
	####################################################################################
	
	
	############################################################################################
	#####	FINE CONTROLLO DELLE TRACCE "SPEZZATE"##############################################
	############################################################################################
	
	
	
	print "Traccia $fl_id\n";
	$sel_on_batt = "SELECT row_id,UNIX_TIMESTAMP(time_italy),X_m,Y_m,H_m FROM battute 
	                WHERE flay_id = '$fl_id' and validation IS NULL";
	$sel_batt_h = $db_radar->prepare($sel_on_batt) || die "Can't prepare $statement: $db_radar->errstr\n";
	$rv1 = $sel_batt_h->execute || die "can't execute the query: $sel_batt_h->errstr";
	
	$table_battuta=$sel_batt_h->fetchall_arrayref;
	
	#######################################################################################
	####	CONTROLLO PER LA VALIDAZIONE DELLA PRIMA BATTUTA	#######################
	#######################################################################################

	for ($m=0; $m<=$#{$table_battuta}-4; $m++)		
	{
		for ($i=$m+1; $i<=$#{$table_battuta}-3; $i++) 	
		{
			### PER OGNI PUNTO CERCA, TRA TUTTE LE BATTUTE SUCCESSIVE,  ###
			### UN GRUPPO DI TRE BATTUTE SUCCESSIVE TRA LORO E "VICINE" ###

			$deltaT0=$table_battuta->[$i][1]-$table_battuta->[$m][1];

			$deltaT1=$table_battuta->[$i+1][1]-$table_battuta->[$i][1];
			$deltaT2=$table_battuta->[$i+2][1]-$table_battuta->[$i+1][1];
			$deltaT3=$table_battuta->[$i+3][1]-$table_battuta->[$i+2][1];

			$dist_1=&distanza2($table_battuta->[$i][2],$table_battuta->[$i][3],
					   $table_battuta->[$i+1][2],$table_battuta->[$i+1][3]);
			$dist_2=&distanza2($table_battuta->[$i+1][2],$table_battuta->[$i+1][3],
					   $table_battuta->[$i+2][2],$table_battuta->[$i+2][3]);
			$dist_3=&distanza2($table_battuta->[$i+2][2],$table_battuta->[$i+2][3],
					   $table_battuta->[$i+3][2],$table_battuta->[$i+3][3]);

			####### BATTUTE SUCCESSIVE COINCIDENTI (AEREO FERMO) ###############
			if (($i==$m+1)&&($table_battuta->[$m][2]==$table_battuta->[$i][2])&&
					($table_battuta->[$m][3]==$table_battuta->[$i][3])&&
					($table_battuta->[$m][4]==$table_battuta->[$i][4]))
			{
				push(@batt_invalid,$table_battuta->[$m][0]);
				$i=$#{$table_battuta}-2;
			}
			####################################################################

			else
			{
				#### SE LE TRE BATTUTE INDIVIDUATE SONO 'VICINE' ####
				if (($deltaT1*$deltaT2*$deltaT3*$deltaT0>0)&&(($dist_1/$deltaT1)<$soglia)
				     &&(($dist_2/$deltaT2)<$soglia)&&(($dist_3/$deltaT3)<$soglia))
				{
					$dist_0=&distanza2($table_battuta->[$m][2],$table_battuta->[$m][3],
							   $table_battuta->[$i][2],$table_battuta->[$i][3]);

					### BATTUTA NON VALIDATA ####
					if (($dist_0/$deltaT0)>$soglia)
					{
						push(@batt_invalid,$table_battuta->[$m][0]);
						$i=$#{$table_battuta}-2;
					}

					### BATTUTA VALIDATA - ESCE DAI CICLI FOR ####
					else 
					{
						$prima_batt=$table_battuta->[$m][0];

						push (@batt_valid,$table_battuta->[$m][0]);

						$i=$#{$table_battuta}-2;
						$m=$#{$table_battuta}-3;
					}
				}

				####	FINE CICLO SENZA ESITO POS	####
				if ($i==$#{$table_battuta}-3)  
				{
					for ($n=0, $n<=$#{$table_battuta}, $n++)
					{
						push(@batt_invalid,$table_battuta->[$n][0]);
					}
				}
			}
		}
	}							

	#######################################################################################
	####	FINE CONTROLLO PER LA VALIDAZIONE DELLA PRIMA BATTUTA	#######################
	#######################################################################################

	$stop=1;
	$cosrs=0;
	$valid=0;

	$non_val=0;		### DIVERSO DA ZERO SE LE non_val BATTUTE PRECEDENTI NON SONO STATE VALIDATE
	$non_val_old=0;		### "DISTANZA " TRA L'ULTIMA E LA PENULTIMA BATTUTA VALIDATA

	###############################################################################################
	####	CONTROLLO PER LA VALIDAZIONE DELLA BATTUTE SUCCESSIVE	###############################
	###############################################################################################

	for ($j=1; $j<=$#{$table_battuta}; $j++)	
	{	
		#### CONDIZIONE CHE INIZIA IL CONTROLLO QUANDO TROVA LA PRIMA BATTUTA VALIDATA	####
		if ($table_battuta->[$j-1][0]==$prima_batt) 
		{
			$stop=0;
		}
		next if $stop; 
		####################################################################################

		$deltaT=$table_battuta->[$j][1]-$table_battuta->[$j-(1+$non_val)][1];

		if ($deltaT==0)		####	RECORD CONSECUTIVI DUPLICATI	#####
		{
			push(@batt_invalid,$table_battuta->[$j][0]);
			$non_val++;
		}

		else
		{
			####### BATTUTE SUCCESSIVE COINCIDENTI (AEREO FERMO) ###############
			if (&distanza2($table_battuta->[$j][2],$table_battuta->[$j][3],
			    $table_battuta->[$j-(1+$non_val)][2],$table_battuta->[$j-(1+$non_val)][3])==0) 
			{
				push(@batt_invalid,$table_battuta->[$j][0]);		
				$non_val++;
			}
			####################################################################

			else
			{
				### BATTUTE A QUOTA ***NON*** NULLA ---> DISTANZA 3D	#########
				if ($table_battuta->[$j][4]>0)		
				{
					$dist=&distanza3($table_battuta->[$j][2],$table_battuta->[$j][3],
							 $table_battuta->[$j][4],
							 $table_battuta->[$j-(1+$non_val)][2],
							 $table_battuta->[$j-(1+$non_val)][3],
							 $table_battuta->[$j-(1+$non_val)][4]);
				}

				### BATTUTE A QUOTA NULLA ---> DISTANZA 2D	#################
				if ($table_battuta->[$j][4]==0)		
				{
					$dist=&distanza2($table_battuta->[$j][2],$table_battuta->[$j][3],
							 $table_battuta->[$j-(1+$non_val)][2],
							 $table_battuta->[$j-(1+$non_val)][3]);
				}

				####################################################################################
				#### CONTROLLO SULLA VELOCITA' E SULLA VARIAZIONE DI DIREZIONE 		############
				#### (necessita di due punti gia' validati --> parte se, oltre 		############	
				#### alla prima battuta, e' gia' stato validato almeno un punto)	############
				####################################################################################

				if ($valid==1)
				{
					### COSENI DIRETTORI  ###
					$cosxr=(($table_battuta->[$j-(1+$non_val)][2]-$table_battuta->[$j-(1+$non_val)-(1+$non_val_old)][2])/
					       (&distanza2($table_battuta->[$j-(1+$non_val)][2],$table_battuta->[$j-(1+$non_val)][3],
						$table_battuta->[$j-(1+$non_val)-(1+$non_val_old)][2],$table_battuta->[$j-(1+$non_val)-(1+$non_val_old)][3])));
					$cosyr=(($table_battuta->[$j-(1+$non_val)][3]-$table_battuta->[$j-(1+$non_val)-(1+$non_val_old)][3])/
					       (&distanza2($table_battuta->[$j-(1+$non_val)][2],$table_battuta->[$j-(1+$non_val)][3],
					       $table_battuta->[$j-(1+$non_val)-(1+$non_val_old)][2],$table_battuta->[$j-(1+$non_val)-(1+$non_val_old)][3])));
					$cosxs=(($table_battuta->[$j][2]-$table_battuta->[$j-(1+$non_val)][2])/
					       (&distanza2($table_battuta->[$j][2],$table_battuta->[$j][3],
						$table_battuta->[$j-(1+$non_val)][2],$table_battuta->[$j-(1+$non_val)][3])));
					$cosys=(($table_battuta->[$j][3]-$table_battuta->[$j-(1+$non_val)][3])/
					       (&distanza2($table_battuta->[$j][2],$table_battuta->[$j][3],
						$table_battuta->[$j-(1+$non_val)][2],$table_battuta->[$j-(1+$non_val)][3])));

					$cosrs=$cosxr*$cosxs+$cosyr*$cosys;

					if (($cosrs<0.5)||(($dist/$deltaT)>$soglia))		#BATTUTE NON VALIDE
					{	
						push(@batt_invalid,$table_battuta->[$j][0]);		
						$non_val++;
					}

					else 							#BATTUTE VALIDE
					{
						push (@batt_valid,$table_battuta->[$j][0]);
						$valid=1;
						$non_val_old=$non_val;
						$non_val=0;
					}

				}
				#### NESSUNA BATT. PRECEDENTEMENTE VALID. --> NON FA IL CONTROLLO SULLA DIREZ. ####
				else
				{
					if (($dist/$deltaT)>$soglia)					#BATTUTE NON VALIDE
					{
						push(@batt_invalid,$table_battuta->[$j][0]);		
						$non_val++;
					}

					else 								#BATTUTE VALIDE
					{
						push (@batt_valid,$table_battuta->[$j][0]);
						$valid=1;
						$non_val_old=$non_val;
						$non_val=0;
					}
				}

				####################################################################################
				#### FINE CONTROLLO SULLA VELOCITA' E SULLA VARIAZIONE DI DIREZIONE 	############
				####################################################################################
			}
		}
	}

	###############################################################################################
	####	FINE CONTROLLO PER LA VALIDAZIONE DELLA BATTUTE SUCCESSIVE	#######################
	###############################################################################################
	

	####	AGGIORNAMENTO DATABASE ####
	
	$string_battute_invalide = join (',',@batt_invalid);
	$string_battute_valide = join (',',@batt_valid);
	
	if(@batt_invalid > 0)
	{
		$db_radar->do("UPDATE battute SET validation = 'N' WHERE row_id in ($string_battute_invalide)") || die "Can't prepare $statement: $db_radar->errstr\n";
	}
	#while ($batt_in = pop(@batt_invalid))
	#{
	#	$up_on_batt= "UPDATE battute SET validation = 'N' WHERE row_id = '$batt_in'";
	#	$up_on_batt_h = $db_radar->prepare($up_on_batt) || die "Can't prepare $statement: $db_radar->errstr\n";;
	#	$rv = $up_on_batt_h->execute || die "can't execute the query: $up_on_flay_h->errstr";
	#	$up_on_batt_h->finish;
	#}
	
	
	if (@batt_valid == 0)
	{
		$db_radar->do("UPDATE FLAY SET validation_fl = 'D',validation_bt = 0 WHERE row_id = '$fl_id'") || die "Can't prepare $statement: $db_radar->errstr\n";
	}
	elsif (@batt_valid < 4)
	{
		$string_battute_valide = join (',',@batt_valid);
		$db_radar->do("UPDATE battute SET validation = 'D' WHERE row_id in ($string_battute_valide)") || die "Can't prepare $statement: $db_radar->errstr\n";
		$db_radar->do("UPDATE FLAY SET validation_fl = 'D',validation_bt = 0 WHERE row_id = '$fl_id'") || die "Can't prepare $statement: $db_radar->errstr\n";
	}
	elsif(@batt_valid < 8)
	{
		$string_battute_valide = join (',',@batt_valid);
		$db_radar->do("UPDATE battute SET validation = 'Y' WHERE row_id in ($string_battute_valide)") || die "Can't prepare $statement: $db_radar->errstr\n";
		$db_radar->do("UPDATE FLAY SET validation_fl = 'L', validation_bt = 1 WHERE row_id = '$fl_id'") || die "Can't prepare $statement: $db_radar->errstr\n";
	}
	else
	{
		print "\n\n*** tracce con + di 8 battute valide ***********\n\n";
		$db_radar->do("UPDATE battute SET validation = 'Y' WHERE row_id in ($string_battute_valide)") || die "Can't prepare $statement: $db_radar->errstr\n";
		$db_radar->do("UPDATE FLAY SET validation_bt = 1 WHERE row_id = '$fl_id'") || die "Can't prepare $statement: $db_radar->errstr\n";
	}
	$sel_batt_h->finish;
	
	$tot_battute_YES = $tot_battute_YES + @batt_valid;
	$tot_battute_NO = $tot_battute_NO + @batt_invalid;
}
$sel_flay_h->finish;

###############################################################################################
################################### AGGIORNA CAMPO DATA ORA ARR ###############################

$up_data_ora_arr_str = "UPDATE flay SET data_ora_arr = ? where row_id =  ?";
$up_data_arr_arr_h = $db_radar->prepare($up_data_ora_arr) || die "can't execute the query: $db_radar->errstr";

$rv = $db_radar->do("CREATE TEMPORARY TABLE tempD (flay_id double, data_ora datetime)") || die "can't execute the query: $db_radar->errstr";
$rv = $db_radar->do("INSERT INTO tempD 
	SELECT	flay_id, MIN(time_italy) 
	from flay, battute 
	WHERE battute.flay_id = flay.row_id 
	AND flay.flay_operation = 'D' 
	AND validation_bt = 1
	AND validation in ('Y','L')
	AND data_ora_arr is NULL
	GROUP BY flay_id") || die "can't execute the query: $db_radar->errstr";
$rv = $db_radar->do("UPDATE flay, tempD SET data_ora_arr = tempD.data_ora WHERE row_id = flay_id") || die "can't execute the query: $db_radar->errstr";
print "aggiornata data_ora_arr per $rv decolli\n";

$rv = $db_radar->do("CREATE TEMPORARY TABLE tempA (flay_id double, data_ora datetime)") || die "can't execute the query: $db_radar->errstr";
$rv = $db_radar->do("INSERT INTO tempA 
	SELECT	flay_id, MAX(time_italy) 
	from flay, battute 
	WHERE battute.flay_id = flay.row_id 
	AND flay.flay_operation = 'A' 
	AND validation_bt = 1
	AND validation in ('Y','L')
	AND data_ora_arr is NULL
	GROUP BY flay_id") || die "can't execute the query: $db_radar->errstr";
$rv = $db_radar->do("UPDATE flay, tempA SET data_ora_arr = tempA.data_ora WHERE row_id = flay_id") || die "can't execute the query: $db_radar->errstr";
print "aggiornata data_ora_arr per $rv atterraggi\n";

@data_oraE=localtime(time);
$data_oraE[4]=$data_oraE[4]+1;
$data_oraE[5]=$data_oraE[5]+1900;

$secondidelta = (3600*$data_oraE[2] + 60*$data_oraE[1] + $data_oraE[0])-(3600*$data_ora[2] + 60*$data_ora[1] + $data_ora[0]);

print (FILEOUTPUT "$data_oraE[3]/$data_oraE[4]/$data_oraE[5]\t$data_oraE[2]:$data_oraE[1]:$data_oraE[0]\n**** CARICA_DB FINE *****\n");
print (FILEOUTPUT "secondi trascorsi =  $secondidelta\n");
print "secondi trascorsi $secondidelta\n";
print (FILEOUTPUT "battute validate =   $tot_battute_YES \n");
print (FILEOUTPUT "battute invalidate = $tot_battute_NO \n");
##########################################################################
##########################################################################
##### 	FINE CICLO PRINCIPALE ############################################
##########################################################################
##########################################################################

$sel_report= "SELECT validation,count(*) FROM battute GROUP BY validation";
$sel_report_h=$db_radar->prepare($sel_report);
$rv=$sel_report_h->execute;
while(@report=$sel_report_h->fetchrow_array)
{
	print "@report\n";
	print (FILEOUTPUT "stato complessivo validazione battute DB:");
	print (FILEOUTPUT "@report\n");
}

@data_ora=localtime(time);
$data_ora[4]=$data_ora[4]+1;
$data_ora[5]=$data_ora[5]+1900;

print (FILEOUTPUT "\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n***** VALIDA_BATTUTE *****\n");

close (FILEOUTPUT);
$sel_report_h->finish;

###############################################################################
#########################################   FUNZIONI ##########################
###############################################################################
sub distanza3  	### DISTANZA 3D	###
{
	my ($X1, $Y1, $H1, $X2, $Y2, $H2, $distanza3);
	($X1,$Y1,$H1,$X2,$Y2,$H2) = @_;
	$distanza3=((($X1-$X2)**2+($Y1-$Y2)**2+($H1-$H2)**2)**(0.5));
	return $distanza3;
}

sub distanza2	### DISTANZA 2D	###
{
	my ($X1, $Y1, $X2, $Y2, $distanza2);
	($X1,$Y1,$X2,$Y2) = @_;
	$distanza2=((($X1-$X2)**2+($Y1-$Y2)**2)**(0.5));
	return $distanza2;
}
