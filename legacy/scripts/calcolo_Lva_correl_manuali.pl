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


print(FILELOG adesso($o));
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
