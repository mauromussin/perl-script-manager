#$|=1;
###############################################################################################
#
# Title:	correla eventi cmp
# Author:	bartolomeo telaro, mauro mussin
# Date:		2007-03-22, 2008-03-10
# Revisione: 0.63 (modifiche delle condizioni per la correlazione)
#		fissato bug sulla funzione adesso
# Comment:	correla gli eventi della tabella st_eventi_cmp
#               
#		tiene conto dell possibile shift temporale degli eventi	
#		implementato l'intervallo asimmetrico di ricerca battute
#		aggiornato a MySQL5
#		aggiunto calcolo LVA e inserimento nelle tabelle st_lva
#		inserita attualizzazione
#       possibilità di correlare altri voli anche su sid diverse da quelle della tabella sid_stazioni
# Table usate:	
#NOTA: in questa versione gli eventi devono essere codificati con il codice c_cab e non con quello interno id_stazione
#	    anche nel file di input deve essere specificato c_cab
# 
###############################################################################################

use DBI; #Carica in memoria il modulo DBI.
 use DBI qw(:sql_types); #carica le costanti SQL
#use Statistics::Descriptive;   #Carica il modulo di statistica descrittiva
use Acme::Comment type =>'C++', own_line=>1; # commenti multiriga stile C++

###########  costanti e variabili  ############################################################

############## variabili correlazione di default#############

$max_distance = 3800;
$delta_time = 18;

#####################  INPUT UTENTE ###########################################################
# i dati di input vengono presi dal file $ARGV[0] (cfr doc.per keywords)		      #
###############################################################################################
$fileini=$ARGV[0];
print "\nI DATI VERRANNO PRESI DAL FILE $fileini\n";
open(FILEINPUT,$fileini);
$filelog='correla.log'	 ;
open(FILELOG,'>',$filelog);

while (<FILEINPUT>) {
	$currentLine='';
	@lista='';
	my $currentLine = $_;
	# Process each line of the file in $currentLine ...
    $r=index($currentLine,'#');
    #print "-->$currentLine\n";
    #print "---->>>@lista\n";
    if ($r<0){
   		#non è un commento in INPUT
        my @lista=split  /\t/,$currentLine;
        $cond=$lista[0];
        $var=$lista[1];
        chomp($var);  #elimina \n
        $var=trim($var);
        #print "\nlista1->$var<<-\t$var2";
        if ($cond eq 'ip'){
        	$IP=$var;
			if ($IP eq '') {$IP='localhost';}
        }
        elsif ($cond eq 'db'){
		    $database=$var;
	    }
        elsif ($cond eq 'arp'){
			$aeroporto=$var;
			$aeroporto = uc $aeroporto;
		}
		elsif ($cond eq 'stz'){
			$id_centralina=$var;
        }
        elsif ($cond eq 'datin'){
            $datainizio=$var;
        }
        elsif($cond eq 'datfi'){
          	$datafine=$var;
		}
        elsif($cond eq 'shi'){
			$shift=$var;
            if ($shift eq '') {$shift = 0;}
        }
        elsif($cond eq 'usr'){
            $nome_utente=$var;
        }
        elsif($cond eq 'pwd') {
            $password=$var;
        }
        elsif($cond eq 'mti'){
            $delta_time_rew=$var;
        }
        elsif($cond eq 'mdi'){
            $max_distance=$var;
        }
        elsif($cond eq 'mta'){
            $delta_time_adv=$var;
        }
        elsif($cond eq 'cond'){
			$condizione=$var;
			}	
		else
            {
            die print "\KEYWORD ERRATA!->$lista[0]\n";
			}
	}
    else	
		{    
		#print "\n commento->$currentLine\n";
        }
}
close(FILEINPUT);
# VERIFICA INPUT
print "\nVERIFICA INPUT\n";
print "IP->$IP<-\n";
print "Database->$database<-\n";
print "Centralina->$id_centralina<-\n";
print "Data inizio->$datainizio<-\n";
print "Data fine->$datafine<-\n";
print "Aeroporto->$aeroporto<-\n";
print "Limite inferiore correlazione->$delta_time_rew\n";
print "Limite superiore correlazione->$delta_time_adv\n";
print "Distanza massima-> $max_distance\n";
print "Ulteriore condizione-> $condizione";
#print "Premi ENTER  per continuare CTRL+C per terminare\n";
#c$= <STDIN>;

###########################
# questa if è del tutto inutile
#############################
print "\nAEROPORTO $aeroporto\n";
if ($aeroporto eq 'LIMC')
{
print "\nHAI SCELTO MALPENSA\n";
}
elsif ($aeroporto eq 'LIML' || $aeroporto eq 'LIME'||$aeroporto eq 'LIPO'||$aeroporto eq 'LIRA')
{
print "\HAI SCELTO UN ALTRO AEROPORTO, NON MALPENSA\n";
}
else
	{die print "Ma che cavolo di aeroporto hai scelto TALOTA!!\n";}

print(FILELOG adesso($o));
print (FILELOG "\n");
############# connessione al DB ######################################################
$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) || 
die "Non mi posso connettere al database:$DBI::errstr\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

#   cancellazione eventuali correlazioni già esistenti
print("Prepare statement...");
$delete_CORR = "delete corr from battute_eventi_cmp as corr,st_eventi_cmp as st
where
st.id_centralina_cmp= ? and
corr.evento_cmp_id=st.row_id and
st.data_ora between ? and ?";
$errstr=$db_radar->errstr;
$delCORR = $db_radar->prepare($delete_CORR) || die "Can't prepare $statement: $errstr\n";
print("done!\n");
#####################################
#    cancellazione battute temporanee
#####################################
print("Cancellazione battute temporanee e inserimento nuove battute...");
$delete_Batt_Tmp="delete from battute_tmp";
$errstr=$db_radar->errstr;
$deleteBattTmp=$db_radar->prepare($delete_Batt_Tmp);
$rv=$deleteBattTmp->execute || die "\nCancellazione Battute temporanee non riuscita!: $errstr\n";
####################################################
###   inserimento battute nella tabella temporanea
####################################################
$insert_Bat="insert into battute_tmp (row_id,ora,flay_id,X_m,Y_m,Z_m,H_m,A_m,path,vel,hmod,validation,time_italy) 
select bt.row_id,bt.ora,bt.flay_id,bt.X_m,bt.Y_m,bt.Z_m,bt.H_m,bt.A_m,bt.path,bt.vel,bt.hmod,bt.validation,bt.time_italy
 from battute as bt left join flay as fl on bt.flay_id=fl.row_id where
fl.data_ora_arr between date_add(?,INTERVAL $delta_time_rew SECOND) and 
date_add(?, INTERVAL $delta_time_adv SECOND)";
$InsertBat=$db_radar->prepare($insert_Bat) || die "Can't prepare $statement: $errstr\n";
$data_fi=$datafine.' 23:59:59';
$secondi=86400+$delta_time_adv;
$InsertBat->bind_param(1,$datainizio);
$InsertBat->bind_param(2,$data_fi);
$rv=$InsertBat->execute ||die "Inserimento Battute temporanee non riuscita!: $errstr\n";
print("...fatto!\n");
print("selezione dati stazione $id_centralina...");
################# QUERY SELEZIONE DATI CENTRALINA ####################################
# questa query serve solo ad estrarre l'ID della centralina: perchè ci siano due tabelle con gli stessi dati rimane un mistero
/*
$sel_cabina = "SELECT st.c_cab, st.X_m, st.Y_m, st.H_m 
		FROM anagrafica.stazioni as st,anagrafica.aeroporti as arp, anagrafica.centraline_cmp as cmp 
		WHERE st.aeroporti_id = arp.row_id 
		AND arp.nome_aerop = ?
		AND st.row_id = cmp.id_stazione
		AND cmp.row_id = ?";
*/
#questa è la nuova query che elimina l'uso della tabella centraline_cmp
$sel_cabina = "SELECT st.c_cab, st.X_m, st.Y_m, st.H_m 
		FROM anagrafica.stazioni as st,anagrafica.aeroporti as arp 
		WHERE st.aeroporti_id = arp.row_id 
		AND arp.nome_aerop = ?
		AND st.c_cab = ?";
# NOTA: il ? è usato successivamente nella execute per passare il valore di $id_centralina
$errstr=$db_radar->errstr;
$selCAB = $db_radar->prepare($sel_cabina) || die "Can't prepare $statement: $errstr\n";
$errstr=$selCAB->errstr;
$selCAB->bind_param(1,$aeroporto);
$selCAB->bind_param(2,$id_centralina);
$rv = $selCAB->execute || die "can't execute the query: $errstr\n";
$rv == 0 && die "\n CABINA NON TROVATA - CONTROLLA I DATI DI INPUT\n ";

@cabine = $selCAB->fetchrow_array;

############# preparo la select degli eventi

if ($shift != 0)
{
	print "HAI INSERITO uno shfit temporale: $shift\n";
	$sel_eventi = "SELECT distinct row_id, id_centralina_cmp, date_add(data_ora, INTERVAL $shift SECOND), Sel 
		FROM st_eventi_cmp
		WHERE	date_format(data_ora,'%Y-%m-%d') BETWEEN '$datainizio' AND '$datafine'
		AND id_centralina_cmp = ?
		ORDER BY Sel desc";
}
elsif ($shift == 0)
{
	print "NON HAI INSERITO uno shfit temporale\n";
	$sel_eventi = "SELECT row_id, id_centralina_cmp, data_ora, Sel 
		FROM st_eventi_cmp
		WHERE	date_format(data_ora,'%Y-%m-%d') BETWEEN '$datainizio' AND '$datafine'
		AND id_centralina_cmp = ?
		ORDER BY data_ora";	
}
else
{
	die "ma che cavolo di shift hai inserito?\n";
}
$errstr=$db_radar->errstr;
$selEV = $db_radar->prepare($sel_eventi) || die "Can't prepare $statement: $errstr\n";



############# preparo la select che inserisce nel DB la correlazione tra eventi e battute-tracce

$insert_coor = "INSERT INTO battute_eventi_cmp (flay_id,battuta_id,evento_cmp_id,distance,shift) VALUES (?,?,?,?,?)";
$errstr=$db_radar->errstr;
$insCORR = $db_radar->prepare($insert_coor) || die "Can't prepare $statement: $errstr\n";

################ INIZIA A CORRELARE

$c_cab = $cabine[0];
$X_cab = $cabine[1];
$Y_cab = $cabine[2];
$A_cab = $cabine[3];
	
print "INIZIA LA CABINA: $c_cab\tx=$X_cab\ty=$Y_cab\th=$A_cab\n";  
# solo ora si possono cancellare le correlazioni con c_cab
print  ("Cancello correlazioni esistenti nel periodo $datainizio - $datafine ...");
$delCORR->bind_param(1,"$c_cab");
$delCORR->bind_param(2,"$datainizio"." 00:00:00");
$delCORR->bind_param(3,"$datafine"." 23:59:59");
$rv = $delCORR->execute || die "Cancellazione non riuscita!: $errstr\n";
print ("\t\t....cancellazione OK!\n");
############# preparo la query di correlazione

$sel_BAT = "SELECT fl.row_id, bt.row_id, bt.X_m, bt.Y_m, bt.A_m,
	SQRT(POW(($X_cab - bt.X_m),2) + POW(($Y_cab - bt.Y_m),2) + POW(($A_cab - bt.A_m),2)) as distance,
	fl.data_ora_arr
	FROM BATTUTE AS bt JOIN FLAY AS fl on bt.flay_id = fl.row_id join anagrafica.stazioni_sid as sid
	on sid.sid = fl.sid
	WHERE 
   	fl.validation_bt = 3
	AND bt.validation = 'Y' 
    AND (sid.stazioni_id = $c_cab $condizione)
	AND bt.time_italy between date_add(?,INTERVAL $delta_time_rew SECOND) AND date_add(?,INTERVAL $delta_time_adv SECOND) 
	AND SQRT(POW(($X_cab - bt.X_m),2) + POW(($Y_cab - bt.Y_m),2) + POW(($A_cab - bt.A_m),2)) < $max_distance 
	order by SQRT(POW(($X_cab - bt.X_m),2) + POW(($Y_cab - bt.Y_m),2) + POW(($A_cab - bt.A_m),2))";

$errstr=$db_radar->errstr;
$selBAT = $db_radar->prepare($sel_BAT) || die "Can't prepare $statement: $errstr\n";
$j = 0;

$SelTotNonCorr=0;
$SelTotCorr=0;
################### estraggo gli eventi

$rv = $selEV->execute($c_cab) || die "can't execute the query: $errstr\n";
$rv == 0 && die "\n NON CI SONO EVENTI NEL PERIODO SELEZIONATO\n ";
$rows=$selEV->rows;
$Diff=-1;
$c=0; #controllo sulle battute già correlate
print("Stazione\tCabina\tEvento\tData\tBattute\tOra battuta\tDelta SEL");
EVE: while(@EV = $selEV->fetchrow_array)  #### per ogni evento estratto cerco una battuta
{		#la lista @EV contiene gli eventi
		
		if($c>0){
			printf("+ + + + + + + + + +\t%2.2f",$Diff);
			print(FILELOG "\nsolo battute correlate ->$c");
			$c=0;
		}
		print "\n$id_centralina\t$c_cab\t$EV[0]\t$EV[2]\t";
		print (FILELOG "\n$id_centralina\t$c_cab\t$EV[0]\t$EV[2]\t ");
		#sleep (4);
		$SelTotNonCorr=$SelTotNonCorr+10**(0.1*$EV[3]);
		$selBAT->bind_param(1,"$EV[2]");
		$selBAT->bind_param(2,"$EV[2]");
		
		$rv = $selBAT->execute || die "can't execute the query: $errstr\n";
		#@cr=$selBAT->fetchrow_array;#??!! perdo la prima battuta??!!
		#print(FILELOG "cr--->\t$cr[0]\t$cr[6]\n");
		$rows_BAT=$selBAT->rows;
		if ($rows_BAT>-1){print ("$rows_BAT\t");}
		print (FILELOG "\tbattute trovate=$rows_BAT");
		
		# era $rv==0 and next EVE;
		if($rv == 0){ 
		        #print "\t\t\t\t\t correlati prima di questo: $j\t su $rows\n";
			if($SelTotNonCorr>$SelTotCorr && $SelTotCorr>0 ) {
				$Diff=10*(log($SelTotNonCorr)-log($SelTotCorr))/log(10);
			}
			printf("- - - - - - - - - -\t%2.2f",$Diff);
			$c=0;
			print (FILELOG "\t\t\tnessuna battuta trovata!");
			next EVE; 
		}
		#siccome  non sono uscito dal ciclo eventi ho delle battute da verificare
		BAT: while (@CORR = $selBAT->fetchrow_array)
		{	# 
			
			print (FILELOG "\nbattuta n.$c\t$CORR[6]");	
			$flay_id = $CORR[0];
			$evento_id = $EV[0];
			#$c=0;
			$control_corr = $db_radar->prepare("SELECT count(*) FROM battute_eventi_cmp AS corr 
					LEFT JOIN st_eventi_cmp AS ev ON corr.evento_cmp_id = ev.row_id   
					WHERE (corr.flay_id = $flay_id OR corr.evento_cmp_id = $evento_id)
					AND shift = $shift
					AND ev.id_centralina_cmp = $c_cab") or die "non posso preparare la query per controllare se un evento e' gia correlato\n";
			$rv = $control_corr->execute or die "non posso eseguire la query per controllare se un evento e' gia correlato\n";
			@prec_corr = $control_corr->fetchrow_array;
			#print (FILELOG "battute gia correlate per $CORR[0]=$prec_corr[0] \n");
			
			if($SelTotNonCorr>$SelTotCorr && $SelTotCorr>0 ) {
				$Diff=10*(log($SelTotNonCorr)-log($SelTotCorr))/log(10);
			}
			#questa if fa saltare tutte le battute già correlate: se sono tutte correlate esce semplicemente dal ciclo
			if ($prec_corr[0] > 0) {
				$c++;
				print(FILELOG "\tc->$c");
				next BAT;
			}
			
			$insCORR->bind_param(1,"$flay_id");
			$insCORR->bind_param(2,"$CORR[1]");
			$insCORR->bind_param(3,"$evento_id");
			$insCORR->bind_param(4,"$CORR[5]");
			$insCORR->bind_param(5,$shift);
			
			#print ("Che fortuna! L'evento $EV[0] viene correlato!\t");
			#print("Battuta ora ->$CORR[6] ed evento ->$EV[2]\n");
			#print "\t\t\t\t\t correlati finora: $j\t su $rows\n";
			$SelTotCorr=$SelTotCorr+10**(0.1*$EV[3]);
			if($SelTotNonCorr>$SelTotCorr && $SelTotCorr>0 ) {
				$Diff=10*(log($SelTotNonCorr)-log($SelTotCorr))/log(10);
			}
			printf("$CORR[6]\t%2.2f",$Diff);
			$rv = $insCORR->execute || die "can't execute the query: $errstr\n";
			$j++;
			$c=0;
			print (FILELOG "\t correlazione:$j");
			next EVE;
		}
		
}
if ($SelTotNonCorr*$SelTotCorr>0){
	$Diff=10*(log($SelTotNonCorr)-log($SelTotCorr))/log(10);
}
else
{
	$Diff=-9999
}
print("\nDifferenza energia correlata FINALE->$Diff\n");
print("Correlati \t$j eventi su\t$rows"); 
$oo=adesso($o);
#
#inserimento dei dati di correlazione nella tabella correla_log
#
$database_ana='anagrafica' ;
$db_radar = DBI->connect("DBI:mysql:$database_ana:$IP", $nome_utente, $password) || die "Non mi posso connettere al database:$DBI::errstr\n";
print "\nCONNESSIONE AL DATABASE anagrafica RIUSCITA\n\n";
$Insert_CORR = "INSERT INTO correla_log 
(DataCorr,DatabaseCorr,IdStazione,DataInizio,DataFine,CorrNumber,MaxTimeIn,MaxTimeAdv,MaxDistance)
VALUES ('$oo','$database',$id_centralina,'$datainizio','$datafine',$j,$delta_time_rew,$delta_time_adv,$max_distance)";
$errstr=$db_radar->errstr;
$InsertCORR = $db_radar->prepare($Insert_CORR) || die "Can't prepare $statement: $errstr\n";	
$rv = $InsertCORR->execute || die "Inserimento dati log fallito!: $errstr\n";
# occorre inserire la select per l'id log
$max_log="SELECT max(IdLog) from correla_log";
$errstr=$db_radar->errstr;
$MaxLOG=$db_radar->prepare($max_log)||die "Preparazione max_log fallita!!";
$rv=$MaxLOG->execute || die "query max_log fallita!!";
@ml=$MaxLOG->fetchrow_array;
$id_log=$ml[0];
#
# CALCOLO DEI PARAMETRI LVA CORRELATO E NON CORRELATO
# la query per il calcolo distingue tra eventi del periodo diurno (dalle 6:00:00 alle 22:59:59, perchè legge solo la cifra delle ore)
# e del periodo notturno per esclusione, aggiungendo a questi ultimi un peso di 10dB 
#
$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) || 
die "Non mi posso connettere al database:$DBI::errstr\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

$datafine1=$datafine.' 23:59.59';
$Calc_LVA ="
select 
st.id_centralina_cmp,
date_format(st.data_ora,'%d/%m/%Y'),
10*log10(sum(pow(10,if(hour(data_ora) between 6 and 22,st.Sel/10,(st.Sel+10)/10)))/86400.0),count(st.id_centralina_cmp)
from st_eventi_cmp as st right join battute_eventi_cmp as bt on st.row_id=bt.evento_cmp_id
where data_ora between '$datainizio' and '$datafine1'
and st.id_centralina_cmp=$c_cab
group by st.id_centralina_cmp,date_format(st.data_ora,'%d/%m/%Y')";
$Calc_LVA_nc="
select 
st.id_centralina_cmp,
date_format(st.data_ora,'%d/%m/%Y') as data,
10*log10(sum(pow(10,if(hour(data_ora) between 6 and 22,st.Sel/10,(st.Sel+10)/10)))/86400.0)  as LVA_no_corr,count(st.id_centralina_cmp) as eventi
from st_eventi_cmp as st 
where data_ora between '$datainizio' and '$datafine1'
and st.id_centralina_cmp=$c_cab
group by st.id_centralina_cmp,date_format(st.data_ora,'%d/%m/%Y')";

$errstr=$db_radar->errstr;
$selLVA = $db_radar->prepare($Calc_LVA);
$selLVA_nc = $db_radar->prepare($Calc_LVA_nc);
$rv = $selLVA->execute;
$rv1=$selLVA_nc->execute;
$num_rows=$selLVA->rows;
$num_rows_nc=$selLVA_nc->rows;


$Insert_LVA="INSERT INTO st_lva (data_calc,id_stazione,data_lva,correlato,valore,id_log)
VALUES ('$oo',$id_centralina,STR_TO_DATE(?,'%d/%m/%Y'),?,?,$id_log)";
$InsertLVA=$db_radar->prepare($Insert_LVA);
print("LVA correlato/nc \t stazione  \tper il giorno : \t dBA \n");
LVA:while (@L=$selLVA->fetchrow_array){	   #@L contiene i valori di LVA
	   @L_nc=$selLVA_nc->fetchrow_array; #@L_nc contiene i valori LVA non correlato
	   
		#misteriosamente funziona ogni tipo di chiamata a bind_param....
		print ("\t$L[0]\t$L[1]\t$L[2]\n");
		$InsertLVA->bind_param(1,"$L[1]");
		$InsertLVA->bind_param(2,1,SQL_TINYINT);
		$InsertLVA->bind_param(3,$L[2]);
		$rvl=$InsertLVA->execute || die "Inserimento LVA fallito miseramente\n";
		print ("nc->\t$L_nc[0]\t$L_nc[1]\t$L_nc[2]\n");
		$InsertLVA->bind_param(1,$L_nc[1]);
		$InsertLVA->bind_param(2,0);
		$InsertLVA->bind_param(3,$L_nc[2]);
		$rvl=$InsertLVA->execute || die "Inserimento LVAnc fallito miseramente\n";
	   }
#inserimento nella tabella dgli lva calcolati
#validazione:
#chiedo all'utente se il dato calcolato è da ritenersi valido: in questo caso valorizzo il flag di dato attuale nella tabella st_lva
print "\nSEI SODDISFATTO/A DEL CALCOLO (s/n)?\n\n";
print"ATTENZIONE! Se sei soddisfatto tutti i dati di LVAj calcolati per la stazione \n";
print "\t$c_cab dalla data $datainizio alla data $datafine1\n";
print "saranno 'deattualizzati' e quelli calcolati ora saranno i valori correnti;\n";
print"i dati precedenti non sono cancellati, ma hanno il campo attuale=0\n";
print"la tua scelta->";
$risposta=<STDIN>;
chomp($risposta);
if($risposta=='s'||$risposta=='S'){

#questo implica la modifica della tabella st_lva con l'aggiunta di un campo "attuale" di tipo booleano
#step 1: cerco i precedenti dati con attuale=1 per lo stesso periodo
#step 2: faccio un update attuale=0
#query annullamento lva attuale
$DeAttualizza=$db_radar->prepare(qq{update st_lva set attuale=0 where
data_lva between '$datainizio' and '$datafine1' and id_stazione=? and attuale=1});
$errstr=$db_radar->errstr;
$rv=$DeAttualizza->execute($c_cab)|| die "query annullamento calcolo attuale fallita!!";
#
#step 3 seleziono i dati con id_log
#step 4 faccio un update con attuale=1
$Attualizza=$db_radar->prepare(qq{update st_lva set attuale=1 where
data_lva between '$datainizio' and '$datafine1' and id_stazione=? and id_log=?
});
$errstr=$db_radar->errstr;
$rv=$Attualizza->execute($c_cab,$id_log)|| die "query valorizzazione calcolo attuale fallita!!";
}

############################
print "Correlati $j eventi per la cabina $c_cab \tstazione $id_centralina";
print (FILELOG "\nfine correlazione \n");
print(FILELOG adesso($o));

close(FILELOG);
sub trim($)
{
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}
sub adesso($)
{
my @ora=localtime(time);
$y=$ora[5]+1900;
$ora[4]++;
$m='0'.$ora[4];
$d='0'.$ora[3];
$h='0'.$ora[2];
$mi='0'.$ora[1];
$s='0'.$ora[0];
$dd= $y.'-'.substr($m,-2.,2).'-'.substr($d,-2,2).' '.substr($h,-2,2).':'.substr($mi,-2,2).':'.substr($s,-2,2);
return $dd;
}
