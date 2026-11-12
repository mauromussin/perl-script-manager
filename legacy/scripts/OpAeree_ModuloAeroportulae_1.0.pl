#########################################################################################
#	Crea i file csv delle operazioni aeree nel formato 															#
#	necessario per caricarli nel sistema sira	                              												#
#																						#	
#	DIRECTORY OUTPUT = "D:\Lombardia Informatica\2SIRA\INVIO" (pra-server)										#
#																						#
#	Author: Bartolomeo Telaro																				#
#	Date:	????-??-??
#	Modified: 2007-02-08	Matteo Giampaolo#
#																						#
#                                                                                     														#
#########################################################################################

if ($ARGV[0] eq '/help')
{
print 	"\n\n\n########################################################################################
######										########
###### INPUT RICHIESTO A VIDEO: LOCALHOST; DATABASE; 				########
######				 USERNAME; PASSWORD; ICAO AREOPORTO;		########
######										########
###### INSERISCE I DATI CONTENUTI NEI FILE *.OUT DELLA DIRECTORY SPECIFICATA	########
######										########
###### ASSEGNA UN VALORE AI CAMPI flay, data, ora, aircraft, airport_dep	########
###### 				  airport_arr. flay_operation 			########
###### DELLA TABELLA FLAY							########
######										########
###### ASSEGNA UN VALORE AI CAMPI flay, ora, flay_id, X_m, Y_m, H_m		########
###### DELLA TABELLA BATTUTE							########
######										########
########################################################################################\n\n\n";
die;
}

############################# carica librerie ########################################
use DBI; # carica la libreria DBI per connetrsi con il DB
use Date::Calc qw(
		Delta_Days
		Add_Delta_Days); # carica una libreria per il calcolo delle date

###############################################################################################

print "INSERIRE L'INDIRIZZO DELLA MACCHINA SU CUI RISIEDE IL DB (localhost se vuoto): ";
$IP=<STDIN>;
chomp($IP);
if ($IP eq '')
{$IP='localhost';}
print "INSERIRE IL NOME DEL DATABASE: ";
$database=<STDIN>;
chop($database);
print "INSERIRE IL NOME UTENTE: ";
$nome_utente=<STDIN>;
chop($nome_utente);
print "INSERIRE LA PASSWORD (VISUALIZZATA IN CHIARO!): ";
$password=<STDIN>;
chop($password);
print "INSERIRE IL NOME DELL' AEROPORTO CODICE (ICAO): ";
$aeroporto=<STDIN>;
chop($aeroporto);
print "INSERIRE LA DATA DI INIZIO DELLE OPERAZIONI AEREE (YYYY-mm-dd): ";
$data_inizio=<STDIN>;
chop($data_inizio);
print "INSERIRE LA DATA DI FINE (dello stesso mese della data di inizio) DELLE OPERAZIONI AEREE (YYYY-mm-dd): ";
$data_fine=<STDIN>;
chop($data_fine);


############## CONNESIONE AL DB ###################################################

$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) ||  
die "\n\n\n  -- FATAL ERROR :  Non mi posso connettere al database:$DBI::errstr\n\n\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

$dir = "d:/Lombardia Informatica/2SIRA";  # setta la direttory base di lavoro
###################################################################################

################## RECUPERA IL CODICE IATA PEr L? AREOPORTO

$select_areoporto = "SELECT IATA_code from anagrafica.aeroporti where nome_aerop = '$aeroporto'";
$h_select_aerop = $db_radar->prepare($select_areoporto) || die "Can't prepare $select_areoporto:" . $db_radar->errstr;
$rv = $h_select_aerop ->execute || die "can't execute the query: $h_select_aerop->errstr";
@IATA_row = $h_select_aerop->fetchrow_array;
$IATA = $IATA_row[0];

print "IATA =$IATA\n\n ";

######################################################################################

@data_inizio = split ('-',$data_inizio);
@data_fine = split ('-',$data_fine);

$diff_giorni = Delta_Days(@data_inizio,@data_fine);

for ($giorni = 0; $giorni <= $diff_giorni; $giorni++)
{
	@data_ini = Add_Delta_Days(@data_inizio,$giorni); 
	print "$data_ini[0]-$data_ini[1]-$data_ini[2]\t";
	if ($data_ini[1] < 10) {$data_ini[1] = "0$data_ini[1]";}
	if ($data_ini[2] < 10) {$data_ini[2] = "0$data_ini[2]";}
	################## APRE IL FILE DI OUTPUT ############################################

	$nome_file_output = $IATA."_$data_ini[0]$data_ini[1]$data_ini[2].csv";
	$file_outup = $dir."/INVIO/".$nome_file_output;

	#####################################################################################

	$select_operazioni = "SELECT pista,sid,flay_operation,aircraft,ana.ICAO_type,count(*) as flights 
			FROM flay LEFT JOIN anagrafica.an_aircraft as ana ON flay.aircraft = ana.ICAO_type
			WHERE date_format(data_ora_arr,'%Y-%m-%d') = '$data_ini[0]-$data_ini[1]-$data_ini[2]'
			AND validation_bt > 0
			AND pista IS NOT NULL
			AND sid IS NOT NULL
			group by pista,sid,flay_operation,aircraft
			order by flights desc, aircraft";			
	$h_select = $db_radar->prepare($select_operazioni) || die "Can't prepare $select_operazioni:" . $db_radar->errstr;
	$rv = $h_select->execute || die "can't execute the query: $h_select->errstr";

	if ($rv == 0) 
	{
		print "NON CI SONO OPERAZIONI NEL DB PER IL GIORNO $data_ini[0]-$data_ini[1]-$data_ini[2]\n\n";
	}
	else 
	{
		print"OK \n\n";
	}
	open(FILEOUTPUT,'>',$file_outup);
	print (FILEOUTPUT "AIRPORT|RUNWAY|SID|AIRCRAFT|FLIGHTS\n"); 

	while(@row = $h_select->fetchrow_array)
	{
		$pista = $row[0];
		
		if ($row[2] eq 'A') 
		{
			$sid = 'APP';
		}
		else
		{
			$sid = $row[1];
		}
		
		if (!$row[4])
		{
			$aircraft = 'NA';
			print "AIRCRAFT NON ASSEGNAT0 - $row[3]\n";
		}
		else 
		{
			$aircraft = $row[4];
		}
	
		$n_voli = $row[5];	
		print (FILEOUTPUT "$IATA|$pista|$sid|$aircraft|$n_voli\n");
	}                      
}                       
############### funzioni ################################################
                        
sub f_time              
{                       
	my @data_ora;   
	my $data;       
	@data_ora=localtime(time);
	$data_ora[4]=$data_ora[4]+1;
	$data_ora[5]=$data_ora[5]+1900;
	$data = "$data_ora[5]-$data_ora[4]-$data_ora[3] $data_ora[2]:$data_ora[1]:$data_ora[0]";
	return $data;   
}                       
                        
sub f_data              
{                       
	my @data_ora;   
	my $data;       
	@data_ora=localtime(time);
	$data_ora[4]=$data_ora[4]+1;
	$data_ora[5]=$data_ora[5]+1900;
	$data = "$data_ora[5]/$data_ora[4]/$data_ora[3]";
	return $data;   
}
