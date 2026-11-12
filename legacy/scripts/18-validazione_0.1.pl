#$|=1;
###############################################################################################
#
# Title:	Validazione dati
# Author:	 mauro mussin
# Date:		2007-09-19 fake+1
# Revisione: 0.0
#
#		
# Comment:	assegna i valori di validazione ai dati LVAj
#               NOTA per un errore il codice 0 deve essere trasformato in 1
#					il codice 1 deve essere trasformato in 3
#					il codice 2 non deve essere trasformato
#					il codice 3 deve essere trasformato in  0
# Table usate:	
#NOTA: 
# 		le varie chiamate ai database devono essere rilasciate; in genere vanno inserite nelle apposite sub utilizzando la sub collegati;
#		l'esportazione per il SIDRA deve essere fatta per tutte le centraline->altro script esporta indici
###############################################################################################

use DBI; #Carica in memoria il modulo DBI.
use DBI qw(:sql_types); #carica le costanti SQL
#use Statistics::Descriptive;   #Carica il modulo di statistica descrittiva
use Acme::Comment type =>'C++', own_line=>1; # commenti multiriga stile C++
use DateTime; #pacchetto molto efficace di calcolo del tempo
###########  costanti e variabili  ############################################################
@validita=('0','0','0','0','0','0','0','0','0','0','0');
$cls="\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n";


#############################################################
#####################  INPUT UTENTE ##############################
#############################################################

open (FILELOG ,'>','valida.log');
print (FILELOG DateTime->now);
print "$cls\t\t\tVALIDAZIONE DI LVAj-LVA\n\n";
print "lo script esegue LA VALIDAZIONE degli indici LVAj in base ai dati già correlati\n";
print "oppure la validazione e il calcolo dell'LVA annuale per una singola stazione\n";
print "assicurati di avere tutti idati necessari per procedere!\n\n\n";
print "INSERIRE L'INDIRIZZO IP DEL SERVER: ";
$IP=<STDIN>;
chomp($IP);
print "INSERIRE IL NOME DEL DATABASE: ";
$database = <STDIN>;
chomp($database);
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
print "INSERIRE IL CODICE STAZIONE : ";
$c_cab = <STDIN>;
chomp($c_cab);
print (FILELOG "\n$IP\t$database\t$nome_utente\t$aeroporto\t$c_cab\n");
##############################################################
#  				COLLEGAMENTO AI TRE DATABASE DI INTERESSE					#
#############################################################

print "Connessione ai database in corso...";
print "\n\n";

$db_ana=collegati('anagrafica',$IP,$nome_utente,$password);
$db_bruma=collegati('bruma',$IP,$nome_utente,$password);
$db_radar=collegati($database,$IP,$nome_utente,$password);

##############################################################
#	separazione ciclo validazione giornaliera da calcolo LVA							#
##############################################################
$CosaFare=0;
while ($CosaFare<9){
	print $cls;
	print "SELEZIONA UNA DELLE OPERAZIONI:\n";
	print "\t 1: validazione delle tre settimane, calcolo dell'LVA ANNUALE e sua validaz.\n";
	print "\t 2: calcolo e validazione dell'LVA annuale dai dati presenti nel database $database\n";
	print "\t 3: validazione di un periodo dalla data alla data\n";
	print "\t 4: inserimento della scelta delle tre settimane nel database bruma\n\n";
	print "\t 9: esci dalla validazione\n"; 
	print "la tua scelta ->";
	$CosaFare=<STDIN>;
	chomp($CosaFare);
	print (FILELOG "operazione selezionata: $CosaFare\n");
	if($CosaFare==1){
		############################################################
		#	1 -	VALIDAZIONE SETTIMANE E CALCOLO LVA ANNUALE					     #
		############################################################
		print (FILELOG "Blocco scelta 1\n");
		$SelSett=$db_bruma->prepare(qq{select * from st_settimane where NomeDatabase=?});
		$ex=$SelSett->execute($database);
		@S=$SelSett->fetchrow_array; #contiene la riga selezionata
		@DataLva=('','','');
		print (FILELOG "S-> $S[3],$S[4],$S[5] \n");
		for ($ii=3;$ii<6;$ii++){
			$ti=DateTime->new(year=>substr($S[$ii],0,4),
								month=>substr($S[$ii],5,2),
								day=>substr($S[$ii],8,2));
#			$data_fine_validazione=DateTime->new();
			$tf=$ti;
			$data_inizio_validazione=$ti->ymd;
			$tf->add(  days => 6 );
			$data_fine_validazione=$tf->ymd;
			$DataLva[$ii-3]=$data_inizio_validazione;
			print (FILELOG "$S[$i]: $data_inizio_validazione<->$data_fine_validazione\n");
			&valida_periodo($data_inizio_validazione,$data_fine_validazione);
			print (FILELOG $ii);
		}
		#estraggo tutti i dati LVAj relativi al periodo di LVA e calcolo
		print "i->>>---$i\n";
		@LVA=&calcola_LVA_annuale(@DataLva);
		
	}
	######################################################
	#	2 -	CALCOLO LVA											#
	######################################################
	elsif ($CosaFare==2){
		$SelSett=$db_bruma->prepare(qq{select * from st_settimane where NomeDatabase=?});
		$ex=$SelSett->execute($database);
		@S=$SelSett->fetchrow_array; #contiene la riga selezionata;
		@DataLva=('','','');
		for ($i=3;$i<6;$i++){
			$ti=DateTime->new(year=>substr($S[$i],0,4),
								month=>substr($S[$i],5,2),
								day=>substr($S[$i],8,2));
#			$data_fine_validazione=DateTime->new();
			$data_inizio_validazione=$ti->ymd;
			$DataLva[$i-3]=$data_inizio_validazione;
			print (FILELOG "$S[$i]: $data_inizio_validazione<->$data_fine_validazione\n");
		}
		
		@LVA=&calcola_LVA_annuale(@DataLva);
	}
	elsif($CosaFare==3){
	######################################################
	#	3 -	VALIDAZIONE DI UN PERIODO GENERICO					#
	######################################################
		print "INSERIRE la data di inizio YYYY-MM-DD\t";
		$datainizio=<STDIN>;
		chomp($datainizio);
		print "INSERIRE la data di fine YYYY-MM-DD\t";
		$datafine=<STDIN>;
		chomp($datafine);
		&valida_periodo($datainizio,$datafine);
	}
	elsif($CosaFare==4){
	############################################################
	#	4 - INSERIMENTO TRE SETTIMANE IN BRUMA		  					#
	###########################################################
		@L=('','','','');
		@N=(0,0,0,0);
		@T=('Tracce Radar','Dati Gestore','Elaborazione','Altro');
		print "\nAnno di riferimento:->";
		$anno=<STDIN>;
		chomp($anno);
	
		for ($i=0;$i<3;$i++){
			print "\nPeriodo $i+1: \nInserisci data di inizio->";
			$data_periodo=<STDIN>;
			chomp($data_periodo);
			$t=DateTime->new(year=>substr($data_periodo,0,4),
													month=>substr($data_periodo,5,2),
													day=>substr($data_periodo,8,2));
			$L[$i]=$t->strftime('%Y-%d-%m %H:%M:%S');
			print "\nInserisci numero di operazioni->";
			$N[$i]=<STDIN>;
			chomp($N[$i]);
		}
		#manca controllo su input utente!!!
		print "\nModalità di definizione:\n";
		for ($i=0;$i<4;$i++)		{
			print "\t$i: $T[$i]\n";
		}
		print "La tua scelta->";
		$jj=<STDIN>;
		chomp($jj);
		print "\nEventuali note:";
		$note=<STDIN>;
		print "Inserimento dato in corso...";
		#mettere query per trovare codice aeroporto
	
		$InsSett=$db_bruma->prepare(qq{insert into st_settimane (NomeDatabase,
																AnnoRiferimento,
																S1,S2,S3,N1,N2,N3,
																Tipo,
																Note,
																Aeroporto) 
														values ('$database',
																'$anno',
																$L[0],$L[1],$L[2],
																$N[0],$N[1],$N[2],
																'$note',
																'$aeroporto')});
		$is=$InsSett->execute;
		$InsSett->finish();
		
		print "...OK!";
	}
		elsif($CosaFare==9){
		die "Elaborazione terminata\n"
	}
}
print (FILELOG  DateTime->now);
close(FILELOG);
###########################################################
########			SUB			##############################
##########################################################
sub valida_periodo{
###########################################################
# Valida_periodo accetta in ingresso due date: inizio e fine e procede alla validazione di quel periodo
#viene usata tre volte per la validazione di LVA annuale
###########################################################
#NOTA c'è un po' di ambiguità nell'uso di $datainizio: nel ciclo LVA è usata come datacorrente
local $datainizio,$datafine,$datafine1;
$datainizio=@_[0];
$datafine=@_[1];
#controllo se la differenza è meno di 86400 secondi uso la data finale del giorno successivo
$datafine1=$datafine.' 23:59:59';
print "Verranno validati i dati di LVAj da $datainizio a $datafine1\n";
print (FILELOG  "Verranno validati i dati di LVAj da $datainizio a $datafine1\n");
###################################################
#                                                           parte di validità						#
###################################################
#query di selezione degli lvaj correlati
$Calc_LVA ="
select data_lva,valore from st_lva where
data_lva between '$datainizio' and '$datafine1'
and id_stazione=$c_cab
and correlato=1 and attuale=1
order by data_lva
";
#query di selezione degli lvaj non correlati
$Calc_LVA_nc="
select data_lva,valore from st_lva where
 data_lva between '$datainizio' and '$datafine1'
and id_stazione=$c_cab
and correlato=0 and attuale=1
order by data_lva";
# collegamento a db_radar

$errstr=$db_radar->errstr;
$selLVA = $db_radar->prepare($Calc_LVA);
$selLVA_nc = $db_radar->prepare($Calc_LVA_nc);
$rv = $selLVA->execute;
$rv1=$selLVA_nc->execute;
$num_rows=$selLVA->rows;
$num_rows_nc=$selLVA_nc->rows;
if($num_rows!=$num_rows_nc){die "errore di incoerenza righe LVAj\n"
}
if($num_rows==0){die "ERRORE: operazione interrotta per mancanza di dati\n"
}
#################################################################
# 							VALIDAZIONE GENERALE							#
#################################################################
print"FASE 1: definizione dello stato della stazione $c_cab\n nel periodo $datainizio <-> $datafine\n\n";
print "Vediamo la CERTIFICAZIONE SIT\n";
	$corretta=0;
	   while($corretta==0){	   
		   print "Definisci il valore per tutti i dati del periodo\n";
		   print "\t 0: nessuna valutazione di validità\n";
		   print "\t 1: certificazione assente o inesistente \n";
		   print "\t 2: certificazione marginalmente conforme \n";
		   print "\t 3: certificazione valida\n";
		   print"la tua scelta->";
		   $fnc= <STDIN>;
		   print"\n";
		   chomp($fnc);
		   if($fnc==0||$fnc==1||$fnc==2||$fnc==3){$corretta=1
			  }
		   else{print"risposta non prevista: prego ripetere\n\n\n"}
		   }
	$validita[10]=$fnc;
print "Passiamo alle VERIFICHE EFFETTUATE da ARPA\n";
print "riguardo localizzazione, ostacoli, ecc.\n";

$corretta=0;
	   while($corretta==0){	   
		   print "Definisci il valore per tutti i dati del periodo\n";
		   print "\t 0: nessuna valutazione di validità\n";
		   print "\t 1: esistono elementi di difformità dalla DGR 808  \n";
		   print "\t 2: DGR 808 rispettata solo in parte \n";
		   print "\t 3: DGR 808 rispettata\n";  
		   print"la tua scelta->";
		   $fnc= <STDIN>;
		   print"\n";
		   chomp($fnc);
		   if($fnc==0||$fnc==1||$fnc==2||$fnc==3){$corretta=1
			  }
		   else{print"risposta non prevista: prego ripetere\n\n\n"}
		   }
	$validita[9]=$fnc;	
print "Passiamo alle CALIBRAZIONI \n";
print "manuali e periodiche automatiche in numero sufficiente\n";
print "e con esito positivo\n";

$corretta=0;
	   while($corretta==0){	   
		   print "Definisci il valore per tutti i dati del periodo\n";
		   print "\t 0: nessuna valutazione di validità\n";
		   print "\t 1: esistono elementi di difformità dalla DGR 808  \n";
		   print "\t 2: DGR 808 rispettata solo in parte \n";
		   print "\t 3: DGR 808 rispettata\n";
		   print"la tua scelta->";
		   $fnc= <STDIN>;
		   print"\n";
		   chomp($fnc);
		   if($fnc==0||$fnc==1||$fnc==2||$fnc==3){$corretta=1
			  }
		   else{print"risposta non prevista: prego ripetere\n\n\n"}
		   }
	$validita[8]=$fnc;	
print "Passiamo al FUNZIONAMENTO \n";
print "in termini di ore di funzionamento nel periodo considerato\n";
print "ATTENZIONE: questa validazione ha senso solo per una valutazione annuale\n";
print "in caso di dubbio selezionare il caso 3\n";

$corretta=0;
	   while($corretta==0){	   
		   print "Definisci il valore per tutti i dati del periodo\n";
		   print "\t 0: nessuna valutazione di validità\n";
		   print "\t 1: esistono elementi di difformità dalla DGR 808  \n";
		   print "\t 2: DGR 808 rispettata solo in parte \n";
		   print "\t 3: DGR 808 rispettata\n";   
		   print"la tua scelta->";
		   $fnc= <STDIN>;
		   print"\n";
		   chomp($fnc);
		   if($fnc==0||$fnc==1||$fnc==2||$fnc==3){$corretta=1
			  }
		   else{print"risposta non prevista: prego ripetere\n\n\n"}
		   }
	$validita[7]=$fnc;	
	$val_temp=valida(@validita);
	print "La validità attuale è:$val_temp\n\n\n";
#################################################################
#							VALIDAZIONE CORRELAZIONI						#
#################################################################
print"FASE 2: attribuzione della validità  per le elaborazioni\n";
print "CALCOLO del valore Nc/N per il periodo $datainizio <-> $datafine\n\n";
 #Per calcolare Nc
	  $CalcolaNc=$db_radar->prepare(qq{select distinct flay_id  from battute_eventi_cmp as be join flay as fl on fl.row_id=be.flay_id
	  where fl.data_ora_arr between '$datainizio' and '$datafine1'})|| die "Preparazione query Nc fallita\n";
	  $rvc=$CalcolaNc->execute;
	  #Per calcolare N
	  $CalcolaN=$db_radar->prepare(qq{select distinct row_id  from  flay as fl
	  where fl.data_ora_arr between '$datainizio' and '$datafine1'})|| die "Preparazione query N fallita\n";
	  $rv=$CalcolaN->execute;
	  $num_rows=$CalcolaN->rows;
	  $num_rows_nc=$CalcolaNc->rows;
      $Nc_over_N=$num_rows_nc/$num_rows;
	  print "per la stazione $c_cab Nc/N vale: $Nc_over_N\n";
	  print "VALIDAZIONE PER Nc/N\n";
	  $corretta=0;
	   while($corretta==0){	   
		   print "Definisci il valore per tutti i dati del periodo\n";
		   print "\t 0: nessuna valutazione di validità\n";
		   print "\t 1: dato non valido\n";
		   print "\t 2: validità marginale\n";
		   print "\t 3: dato valido\n";	   
		   print"la tua scelta->";
		   $fnc_n= <STDIN>;
		   print"\n";
		   chomp($fnc_n);
		   if($fnc_n==0||$fnc_n==1||$fnc_n==2||$fnc_n==3){$corretta=1
			  }
		   else{print"risposta non prevista: prego ripetere\n\n\n"}
		   }
	   $validita[0]=$fnc_n;
#ciclo sui singoli giorni del periodo
print "\nCiclo sui singoli giorni per la validazione singola\n";
#print("LVA correlato/nc \t stazione  \tper il giorno : \t dBA \n");
LVA:while (@L=$selLVA->fetchrow_array){	   #@L contiene i valori di LVA
	   @L_nc=$selLVA_nc->fetchrow_array; #@L_nc contiene i valori LVA non correlato
	   $datainizio=$L[0]; #uso spregiudicato della stessa variabile
	   $datafine1=$datainizio.' 23:59:59';
	   #NOTA: affinchè funzioni, la query successiva deve avere a disposizione una differenza tra i dati con correlato=0 e correlato=1
	   #prima: conto gli eventi del giorno;
	   #poi conto gli eventi in join con battute_eventi
	   $sel_eventi = "select correlato,count(*) from st_eventi_cmp as s
	where s.id_centralina_cmp=$c_cab and s.data_ora between '$datainizio' and '$datafine1'
	group by correlato
	order by correlato asc";	
	$errstr=$db_radar->errstr;
	$selEV = $db_radar->prepare($sel_eventi) || die "Can't prepare $statement: $errstr\n";
	$selEV->execute;
	$tot_ev=0;
	EV:while (@E=$selEV->fetchrow_array){	   #@L contiene i valori dei dati correlati
		$tot_ev+=$E[1];
		if($E[0]=1){
			$ev_corr=$E[1]
		}
	}
    ################################
	#	CALCOLO DI PARAMETRI DEL GIORNO
	################################
	# calcolo la percentuale di eventi correlati
		$perc=$ev_corr/$tot_ev;
	# calcolo delta LVAj 
	   $delta_LVAj=$L_nc[1]-$L[1];  
	#calcolo il valore Nc/N giornaliero
	#Per calcolare Nc
	  $CalcolaNc=$db_radar->prepare(qq{select distinct flay_id  from battute_eventi_cmp as be join flay as fl on fl.row_id=be.flay_id
	  where fl.data_ora_arr between '$datainizio' and '$datafine1'})|| die "Preparazione query Nc fallita\n";
	  $rvc=$CalcolaNc->execute;
	#Per calcolare N
	  $CalcolaN=$db_radar->prepare(qq{select distinct row_id  from  flay as fl
	  where fl.data_ora_arr between '$datainizio' and '$datafine1'})|| die "Preparazione query N fallita\n";
	  $rv=$CalcolaN->execute;
	  $num_rows=$CalcolaN->rows;
	  $num_rows_nc=$CalcolaNc->rows;
      $Nc_over_N=$num_rows_nc/$num_rows;
	##############
	#fase8: Delta LVAj
	##############
	 $corretta=0;
	   while($corretta==0){	   
		   print "per la stazione $c_cab  il giorno  $datainizio  la DIFFERENZA LVAj e' $delta_LVAj \n\n";
		   print "\t 0: non mi interessa\n";		   
		   print "\t 1: troppo elevata, il dato non è valido\n";
		   print "\t 2: un po' elevata, dato marginalmente valido\n";
		   print "\t 3: tutto OK, il dato è valido\n\n";		   
		   
		   print"la tua scelta->";
		   $fpi= <STDIN>;
		   chomp($fpi);
		   if($fpi==0||$fpi==1||$fpi==2||$fpi==3){$corretta=1
			  }
			else{print"risposta non prevista: prego ripetere\n\n\n"}
		}
	$validita[4]=$fpi;
	##################
	#fase 9: CORRELAZIONI
	##################
	 $corretta=0;
	   while($corretta==0){	   
		   print "per la stazione $c_cab  il giorno  $datainizio   la % DI CORRELAZIONE e' $perc \n\n";
		   print "\t 0: non mi interessa\n";		   
		   print "\t 1: troppo scarsa, il dato non è valido\n";
		   print "\t 2: un po' scarsa, dato marginalmente valido\n";
		   print "\t 3: tutto OK, il dato è valido\n\n";		   
		   
		   print"la tua scelta->";
		   $fpi= <STDIN>;
		   chomp($fpi);
		   if($fpi==0||$fpi==1||$fpi==2||$fpi==3){
			$corretta=1
			}
			else{print"risposta non prevista: prego ripetere\n\n\n"}
		}
		$validita[3]=$fpi;	
	##########################################
	#fase 4: chiedo se per il giorno in esame esistono falsi negativi influenti
	##########################################
	   $corretta=0;		 
	   while($corretta==0){	   
		   print "per la stazione $c_cab  il giorno  $datainizio   esistono FALSI NEGATIVI ?\n\n";
		   print "\t 0: non ho controllato\n";
		   print "\t 1: si', esistono e influenzano il calcolo di LVAj\n";
		   print "\t 2: non sembrano  evidenti\n";
		   print "\t 3: ho controllato: non esistono oppure non sono influenti\n";
		   print"NOTA: i falsi negativi sono eventi aeronautici che non sono stati \n";
		   print"      identificati o correlati; se il valore di Nc/N e' basso e il valore \n";
		   print"      di LVAj e' anomalo rispetto agli altri giorni potrebbe darsi che ci siano..\n\n\n";
		   print"la tua scelta->";
		   $fni= <STDIN>;
		   print"\n";
		   chomp($fni);
		   if($fni==0||$fni==1||$fni==2||$fni==3){
			$corretta=1
			  }
		   else{print"risposta non prevista: prego ripetere\n\n\n"}
		   }
		   $validita[1]=$fni;
	   
	#fase 5: chiedo se per il giorno in esame esistono falsi positivi influenti
	   $corretta=0;
	   while($corretta==0){	   
		   print "per la stazione $c_cab  il giorno  $datainizio   esistono FALSI POSITIVI  ?\n\n";
		   print "\t 0: non ho controllato\n";		   
		   print "\t 1: si', esistono e influenzano il calcolo di LVAj\n";
		   print "\t 2: non sembrano evidenti\n";
		   print "\t 3: ho controllato: non esistono oppure non sono influenti\n";		   
		   print"NOTA: i falsi positivi sono eventi non aeronautici che sono stati \n";
		   print"      erroneamente correlati o identificati; se il valore di Nc/N e' \n";
		   print"      basso e il valore di LVAj non correlato e' anomalo rispetto agli \n";
		   print"      altri giorni potrebbe darsi che ci siano...\n\n";
		   print"la tua scelta->";
		   $fpi= <STDIN>;
		   chomp($fpi);
		   if($fpi==0||$fpi==1||$fpi==2||$fpi==3){$corretta=1
			  }
			else{print"risposta non prevista: prego ripetere\n\n\n"}
		}
		$validita[2]=$fpi;
	#################
	# fase 6: INTERFERENZE
	################
	 $corretta=0;
	   while($corretta==0){	   
		   print "per la stazione $c_cab  il giorno  $datainizio   esistono INTERFERENZE  ?\n\n";
		   print "\t 0: non ho controllato\n";		   
		   print "\t 1: si', esistono e influenzano il calcolo di LVAj\n";
		   print "\t 2: non sembrano evidenti\n";
		   print "\t 3: ho controllato: non esistono oppure non sono influenti\n\n";		   
		   
		   print"la tua scelta->";
		   $fpi= <STDIN>;
		   chomp($fpi);
		   if($fpi==0||$fpi==1||$fpi==2||$fpi==3){$corretta=1
			  }
			else{print"risposta non prevista: prego ripetere\n\n\n"}
		}
	$validita[6]=$fpi;
	#################
	#fase 7: SINGOLARITA'
	#################
	 $corretta=0;
	   while($corretta==0){	   
		   print "per la stazione $c_cab  il giorno  $datainizio   esistono SINGOLARITA'  ?\n\n";
		   print "\t 0: non ho controllato\n";		   
		   print "\t 1: si', esistono e influenzano il calcolo di LVAj\n";
		   print "\t 2: non sembrano evidenti\n";
		   print "\t 3: ho controllato: non esistono oppure non sono influenti\n\n";		   
		   
		   print"la tua scelta->";
		   $fpi= <STDIN>;
		   chomp($fpi);
		   if($fpi==0||$fpi==1||$fpi==2||$fpi==3){$corretta=1
			  }
			else{print"risposta non prevista: prego ripetere\n\n\n"}
		}
	$validita[5]=$fpi;
	
		#posso inserire il valore di lvaj
		$validita_totale="";
		for ($k=0;$k<11;$k++){
			$validita_totale=$validita_totale.$validita[$k];
		}
		$vv=&valida(@validita);
		print "$clsrisultati per il giorno $datainizio e la stazione $c_cab\n";
		print "\tLVAj\tvalidita'\n";
		print "\t$L[1]\t$validita_totale\n";
		&inserisci_LVAj($L[1],$datainizio,$validita_totale,$perc);
		#update del campo validita nel database selezionato
		#CAUTION: se ci sono più di un dato con attuale=1 viene assegnata la stessa validità
		$UpLVAj=$db_radar->prepare(qq{update st_lva set validita=? where
										data_lva=? and correlato=1 and attuale=1});
		$uu=$UpLVAj->execute($validita_totale,$datainizio);
		print "nel complesso il dato ha validita': $vv\n";
	} 
}
###################################fine sub Valida_periodo###########################
sub trim($){
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}
sub adesso($){
my @ora=localtime(time);
$y=$ora[5]+1900;
$m='0'.$ora[4];
$d='0'.$ora[3];
$h='0'.$ora[2];
$mi='0'.$ora[1];
$s='0'.$ora[0];
$dd= $y.'-'.substr($m,-2.,2).'-'.substr($d,-2,2).' '.substr($h,-2,2).':'.substr($mi,-2,2).':'.substr($s,-2,2);
return $dd;
}
########################################################
sub valida(@){
########################################################
# la funzione attribuisce un valore di validità complessivo sulla base della lista che viene passata
#copio quello che mi viene passato nella lista @entra
@entra=@_;
@singolo=(0,0,0,0);
for ($i=0;$i<=10;$i++){
	$singolo[$entra[$i]]++;
}
$v=3; #di default il dato è valido
#caso tutti 0						=> la validità è 0
if($singolo[0]==11){
	$v=0
}
#caso uno o più 0 (escluso il caso precedente)	=> la validità è 2
if($singolo[0]>0 && $singolo[0]<11){
	$v=2
}
#caso almeno un 1						=> la validità è 1
if ($singolo[1]>0){
	$v=1
}
#caso tre o più 2						=> la validità è 1
if($singolo[2]>=3){
	$v=1
}
#caso meno di tre 2					=> la validità è 2
elsif ($singolo[2]>0){
	$v=2
}

#altri casi							=> la validità è 3

return $v;
}
sub collegati{
#la funzione agisce associando a $db_radar il database collegato
#tutte le variabili sono locali!!!
#in realtà ritorna un HASH
local $database,$db_radar,$IP,$nome_utente,$password;
$database=@_[0];
$IP=@_[1];
$nome_utente=@_[2];
$password=@_[3];
print "Connessione al database $database in corso...";
$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) || 
die "Non mi posso connettere al database:$DBI::errstr\n";
print "fatto!\n";
return $db_radar;
}

sub calcola_LVA_annuale(@){
#calcola l'LVA annuale del database selezionato (che è il 4° elemento della lista)
#->seleziono gli LVAj (db_radar è quella globale e quindi del database...)
@DateDaCalcolare=@_;
print(FILELOG "$DateDaCalcolare[0] + $DateDaCalcolare[1] +$DateDaCalcolare[2]\n");
$EstraiLVAj=$db_radar->prepare(qq{select valore,validita from st_lva where id_stazione='$c_cab' and (data_lva between '$DateDaCalcolare[0]' and adddate('$DateDaCalcolare[0]',INTERVAL 8 DAY )
															or data_lva between '$DateDaCalcolare[1]' and adddate('$DateDaCalcolare[1]',INTERVAL 8 DAY )
															or data_lva between '$DateDaCalcolare[2]' and adddate('$DateDaCalcolare[2]',INTERVAL 8 DAY ))
															and attuale=1 and correlato=1});
$el=$EstraiLVAj->execute;
$num_lva=$EstraiLVAj->rows;
#uso di fetchall_arrayref()
my $results=$EstraiLVAj->fetchall_arrayref();
#ora posso disconnettermi
$EstraiLVAj->finish();
#->conto quanti sono
#->calcolo LVA
$LVA=0;
$stringa_val_LVA='';
$validita_LVA=0;
	foreach my $record(@$results){
		my ($LVAj,$valid_LVAj)=@$record;
		$LVA+=10**($LVAj/10);
		print "\tLVAj= $LVAj\tvalidita->$valid_LVAj\n";
		for ($jj=0,$jj<11,$jj++){
			$lista_valid_LVA[$jj]=substr ($valid_LVAj,$jj,1);
		}
		$stringa_val_LVA=$stringa_val_LVA.&valida(@lista_valid_LVA);	
	}
	$LVA=10* log($LVA/$num_lva)/log(10);
	print "il valore di LVA è $LVA,$num_lva e la validita è $stringa_val_LVA\n";
	#->attribuisco validità interagendo con l'utente
	print "inserisci validita per dato LVA->";
	$validita_LVA = <STDIN>;
	chomp ($validita_LVA);
	$anno=substr($DateDaCalcolare[0],0,4);
	@LVA_calcolato=($LVA,$num_lva,$validita_LVA);

&inserisci_LVA(@LVA_calcolato);
#inserimento nella tabella dgli lva calcolati

#->attribuisco validità interagendo con l'utente
} #################### fine sub Calcola_LVA_annuale ##################
sub inserisci_LVA{
#inserisce il dato dell'indice nel database bruma
$Validita_LVA=@_[2];
$Valore_LVA=@_[0];
$data_rif_LVA=DateTime->new(year   => $anno, month  => 1,day    => 1);
$d=$data_rif_LVA->strftime('%Y-%d-%m %H:%M:%S');
print "--->$database\t$Valore_LVA\t$Validita_LVA\t$data_rif_LVA\n";
print(FILELOG "inserito LVA $c_cab,$database,$d,$Valore_LVA,$Validita_LVA,@_[1]\n");
$Inserisci_LVA=$db_bruma->prepare(qq{insert update into st_indici (IdStazione,NomeDatabase,TipoIndice,DataRiferimento,Valore,Validita,PercentualeCorrelati) 
													values (?,?,18,?,?,?,?)});
$cc=$Inserisci_LVA->execute($c_cab,$database,$d,$Valore_LVA,$Validita_LVA,@_[1])||die "inserimento fallito\n";
$Inserisci_LVA->finish();
}
sub inserisci_LVAj{
#inserisce il dato dell'indice nel database bruma
#viene passato nell'ordine il valore,la data, la validità, la percentuale di eventi correlati
$Validita_LVAj=@_[2];
$Valore_LVAj=@_[0];
$data_rif_LVAj=DateTime->new(year=>substr(@_[1],0,4),
							month=>substr(@_[1],5,2),
							day=>substr(@_[1],8,2));
$d=$data_rif_LVAj->strftime('%Y-%d-%m %H:%M:%S');
print "INSERIMENTO IN BRUMA--->$database\t$Valore_LVAj\t$Validita_LVAj\t$data_rif_LVAj,@_[1]\n";
print (FILELOG "inserito LVAj $database\t$Valore_LVAj\t$Validita_LVAj\t$data_rif_LVAj,@_[1]\n");
$Inserisci_LVAj=$db_bruma->prepare(qq{insert ignore into st_indici (IdStazione,NomeDatabase,TipoIndice,
									DataRiferimento,Valore,Validita,PercentualeCorrelati) 
													values ('$c_cab','$database',17,?,?,?,?)});
$cc=$Inserisci_LVAj->execute($d,$Valore_LVAj,$Validita_LVAj,@_[3])||die "inserimento fallito\n";
$Inserisci_LVAj->finish();
}
