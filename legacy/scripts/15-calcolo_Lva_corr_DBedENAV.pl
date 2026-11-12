###############################################################################################
#
# Title:	calcolo Lva cor manuali
# Author:	roberta pollini
# Date:		2016-09-15, 2016-09-16
# Revisione: 0
# Comment:	calcola lva in base agli eventi della tabella eventi_corr_bdvedenav 
#               
#		tiene conto dell possibile shift temporale degli eventi	
#		implementato l'intervallo asimmetrico di ricerca battute
#		aggiornato a MySQL5
#		calcolo LVA e inserimento nella tabella lva_calc
#		
# Table usate:	st_eventi_cmp, lva_calc, eventi_corr_devedenav
#NOTA: in questa versione gli eventi devono essere codificati con il codice c_cab e non con quello interno id_stazione
#	    anche nel file di input deve essere specificato c_cab
# 
###############################################################################################

use DBI; #Carica in memoria il modulo DBI.
 use DBI qw(:sql_types); #carica le costanti SQL
#use Statistics::Descriptive;   #Carica il modulo di statistica descrittiva
use Acme::Comment type =>'C++', own_line=>1; # commenti multiriga stile C++

###########  costanti e variabili  ############################################################

#####################  INPUT UTENTE ###########################################################
# i dati di input vengono presi dal file $ARGV[0] (cfr doc.per keywords)		              #
###############################################################################################
$fileini=$ARGV[0];
print "\nI DATI VERRANNO PRESI DAL FILE $fileini\n";
open(FILEINPUT,$fileini);


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

print (FILELOG "\n");

############# connessione al DB ######################################################
$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) || 
die "Non mi posso connettere al database:$DBI::errstr\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

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

# CALCOLO DEI PARAMETRI LVA CORRELATO E NON CORRELATO
#
$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) || 
die "Non mi posso connettere al database:$DBI::errstr\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

$c_cab = $cabine[0];
$datafine1=$datafine.' 23:59.59';
$Calc_LVA ="
select 
st.id_centralina_cmp,
date_format(st.data_ora,'%d/%m/%Y'),
10*log10(sum(pow(10,if(hour(data_ora) between 6 and 22,st.Sel/10,(st.Sel+10)/10)))/86400.0),count(st.id_centralina_cmp)
from st_eventi_cmp as st right join eventi_corr_dbedenav as e on st.row_id=e.evento_cmp_id
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


$Insert_LVA="INSERT INTO lva_calc (id_stazione,data_lva,correlato,Lva)
VALUES ($id_centralina,STR_TO_DATE(?,'%d/%m/%Y'),?,?)";
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
	   
	   sub trim($)
{
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}
