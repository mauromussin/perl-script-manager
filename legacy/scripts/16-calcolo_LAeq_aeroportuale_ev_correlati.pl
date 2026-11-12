###############################################################################################
#
# Title:	calcolo Lva cor manuali
# Author:	roberta pollini
# Date:		2025-02-13
# Revisione: 0
# Comment:	calcola LAeq in base agli eventi della tabella st_eventi_cmp 
#               
#		tiene conto dell possibile shift temporale degli eventi	
#		implementato l'intervallo asimmetrico di ricerca battute
#		aggiornato a MySQL5
#		calcolo LVA e inserimento nella tabella LAeq_aerop
#		
# Table usate:	st_eventi_cmp
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

# CALCOLO DEI PARAMETRI LAEQ DIURNO E NOTTURNO CORRELATI
#
$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) || 
die "Non mi posso connettere al database:$DBI::errstr\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

$c_cab = $cabine[0];
$datafine1=$datafine.' 21:59.59';
$Calc_LAEQD ="
select 
st.id_centralina_cmp,
date_format(st.data_ora,'%d/%m/%Y')as data,
10*log10(sum(pow(10,st.Sel/10))/57600.0)as LAEQD
from st_eventi_cmp as st
where data_ora between '$datainizio' and '$datafine1'
and hour(data_ora) between 06 and 21
and st.id_centralina_cmp=$c_cab
and st.correlato='1'
group by st.id_centralina_cmp,date(st.data_ora)";
$Calc_LAEQN="
select 
st.id_centralina_cmp,
date_format(st.data_ora,'%d/%m/%Y') as data,
10*log10(sum(pow(10,st.Sel/10))/28800.0) as LAEQN
from st_eventi_cmp as st 
where data_ora between '$datainizio' and '$datafine1'
and((hour(data_ora) <06) or (hour(data_ora) >21))
and st.id_centralina_cmp=$c_cab
and st.correlato='1'
group by st.id_centralina_cmp,date(st.data_ora)";

$errstr=$db_radar->errstr;
$selLAEQD = $db_radar->prepare($Calc_LAEQD);
$selLAEQN = $db_radar->prepare($Calc_LAEQN);
$rv = $selLAEQD->execute or die "Fallita query calcolo LEQD";
$rv1=$selLAEQN->execute or die "Fallita query calcolo LEQN";
$num_rows_d=$selLAEQD->rows;
$num_rows_n=$selLAEQN->rows;


$Insert_LAEQ="INSERT INTO st_laeq(id_stazione,data_LAeq,TR,valore_LAeq)
VALUES ($id_centralina,STR_TO_DATE(?,'%d/%m/%Y'),?,?)";
$InsertLAEQ=$db_radar->prepare($Insert_LAEQ);
print("LAEQ correlato/DN \t stazione  \tper il giorno : \t dBA \n");
LAEQ:while (@L_d=$selLAEQD->fetchrow_array){	   #@L_d contiene i valori di LAEQD
	   @L_n=$selLAEQN->fetchrow_array; #@L_n contiene i valori di LAEQN
	   
		#misteriosamente funziona ogni tipo di chiamata a bind_param....
		print ("d->\t$L_d[0]\t$L_d[1]\t$L_d[2]\n");
		$InsertLAEQ->bind_param(1,"$L_d[1]");
		$InsertLAEQ->bind_param(2,1,SQL_TINYINT);
		$InsertLAEQ->bind_param(3,$L_d[2]);
		$rvl=$InsertLAEQ->execute || die "Inserimento LAEQD fallito miseramente\n";
		print ("n->\t$L_n[0]\t$L_n[1]\t$L_n[2]\n");
		$InsertLAEQ->bind_param(1,$L_n[1]);
		$InsertLAEQ->bind_param(2,2,SQL_TINYINT);
		$InsertLAEQ->bind_param(3,$L_n[2]);
		$rvl=$InsertLAEQ->execute || die "Inserimento LAEQN fallito miseramente\n";
	   }
	   
	   sub trim($)
{
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}
