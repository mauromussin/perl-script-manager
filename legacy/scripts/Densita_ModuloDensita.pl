#########################################################################################
#	Crea i file csv delle densita aeree nel formato 															#
#	necessario per caricarli nel sistema sira	                              												#
#																						#	
#	DIRECTORY OUTPUT = "D:\Lombardia Informatica\2SIRA\INVIO" (pra-server)										#
#																						#
#	Author: BT																				#
#	Date:	2005-11-08
#	MOdified: BT  2006-09-29
#																						#
#                                                                                     														#
#########################################################################################

if ($ARGV[0] eq '/help')
{
print 	"\n\n\n###########################################################################
######										   	##
###### INPUT RICHIESTO A VIDEO: LOCALHOST; DATABASE; 					##
######				 USERNAME; PASSWORD; ICAO AREOPORTO;			##
######											##
###### Crea Il file densità Per SIDRA e lo salva nella cartella:			##
######	D:\Lombardia Informatica\2SIRA\INVIO  di pra-server				##
###### 											##
###### 											##
######			 								##
######											##
###### 											##
###### Author:  BT									##
######											##
########################################################################################\n\n\n";
die;
}
############################# carica librerie ########################################
use DBI; # carica la libreria DBI per connetrsi con il DB
use Date::Calc qw(
		Delta_DHMS
		Add_Delta_DHMS); # carica una libreria per il calcolo delle date

##############################################################################

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
$aeroporto = uc $aeroporto;
print "INSERIRE LA DATA DI CUI SI INTENDE ESTRARRE LE densità di OPERAZIONI AEREE (YYYY-mm-dd): ";
$data_analisi=<STDIN>;
chop($data_analisi);

############## CONNESIONE AL DB ###################################################

$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) ||  
die "\n\n\n  -- FATAL ERROR :  Non mi posso connettere al database:$DBI::errstr\n\n\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

$dir = "d:/Lombardia Informatica/2SIRA";  				# setta la direttory base di lavoro
$DB_densita = 'densita';							# nome del DB dove si salvano le tabelle temporane di densita

################## RECUPERA IL CODICE IATA Per L? AREOPORTO #################################

$select_areoporto = "SELECT IATA_code from anagrafica.aeroporti where nome_aerop = '$aeroporto'";
$h_select_aerop = $db_radar->prepare($select_areoporto) || die "Can't prepare $select_areoporto:" . $db_radar->errstr;
$rv = $h_select_aerop ->execute || die "can't execute the query: $h_select_aerop->errstr";
@IATA_row = $h_select_aerop->fetchrow_array;
$IATA = $IATA_row[0];

$tabreticolo = $IATA.'_GRID';

print "IATA =$IATA\n\n ";

################## APRE IL FILE DI OUTPUT ###############################################
$giorno_analisi1= $data_analisi;
$nome_giorno_analisi1 = join('',split('-',$data_analisi));
$tab_densita = $aeroporto.'_'.$database.'_'.$nome_giorno_analisi1; 	# nome tabella di output
print "nome tabella: - > $tab_densita";
$nome_file_output = $IATA."_GRID_$nome_giorno_analisi1.csv";
$file_outup = $dir."/INVIO/".$nome_file_output;

############### Giorno analizzato 'AAAA-MM-GG' ###############################################
   

############# creo la tabella per le battute interpolate ad un secondo #####################################
$rv = $db_radar->do("DROP TABLE IF EXISTS  $DB_densita.$tab_densita");
if (!$rv) 
{
	$errore = $db_radar->errstr;
	die "Can't execute the statement =  $errore";
}

$create_table = "CREATE TABLE $DB_densita.$tab_densita (
	row_id int(10) unsigned NOT NULL auto_increment PRIMARY KEY,
	flay_id INT,
	data_ora_italy DATETIME,
	X_m double(11,2),
	Y_m double(11,2),
	H_m double(11,2),
	ID_CELLA INT unsigned,
	Aircraft CHAR(4),
	interpolata ENUM('Y','N'),
	KEY cella (ID_CELLA))";

$sth_create = $db_radar->prepare($create_table);
$rv = $sth_create->execute or die "e che cazzo\n";
if (!$rv) 
{
	$errore = $db_radar->errstr;
	die "\n\n ERRORE O\n non sono riuscito a creare la tabella\n";
}
############## Preaparo la query di inserimento delle battute interpolate ###################################
############## nell' apposita tabella $tab_densita,   che verra utilizzta inseguito ##############################

$statement = qq{INSERT INTO $DB_densita.$tab_densita (
				flay_id,
				data_ora_italy,
				X_m,
				Y_m,
				H_m,
				ID_CELLA,
				Aircraft,
				interpolata) 
				VALUES (?,?,?,?,?,?,?,?)};
$InsRadar = $db_radar->prepare($statement) 
			or die "\n\n ERRORE O4\n";
			

####################  Estraggo i dati dal DB standard delle tracce  ###########################

$query_tracce = qq {SELECT row_id 
	FROM flay 
	where DATE_FORMAT(data_ora_italy,'%Y-%m-%d') = '$giorno_analisi1' 
	AND validation_fl = 'Y'};
$sth = $db_radar->prepare($query_tracce)
    or die "\n\n ERRORE 01 non sono riuscito a prepare la query di select delle tracce per il giorno in esame\n";

$rv = $sth->execute
          or die "\n\n ERRORE 02 non sono riuscito a eseguire la select delle tracce per il giorno in esame";

print "\nrighe $rv";


my $table_flay = $sth->fetchall_arrayref
                or die "\n\n ERRORE 03 non sono riuscito a fare il fetchall_arreyref della select delle tracce\n";

#$db_radar->do("LOCK TABLES densita.$tab_densita WRITE, flay as f READ, battute as b READ");

$query_battute = "SELECT
		f.row_id,
		f.Aircraft,
		b.X_m,
		b.Y_m,
		b.A_m,
		b.time_italy
		FROM flay as f, battute as b 
		where f.row_id = ? 
		and f.row_id = b.flay_id
		and validation = 'Y'
		order by b.time_italy";

$sth2 = $db_radar->prepare($query_battute) or die "\n\n ERRORE 05\n";

print "\n\nnumero righe trovate dall $#{$table_flay}\n";
my($k);
for $k ( 0 .. $#{$table_flay} ) 
{
	$flay_id = $table_flay->[$k][0];
	print "$flay_id\t$k\n";

	$rv = $sth2->execute($flay_id) 
				or die "\n\n ERRORE 06\n";
	
	my $table_battute = $sth2->fetchall_arrayref 
				or die "\n\n ERRORE 07\n";
	my($i);
	$n_battute = $#{$table_battute};
	for $i (0 .. $n_battute ) 
	{
		$X_m = $table_battute->[$i][2];
		$Y_m = $table_battute->[$i][3];
		$H_m = $table_battute->[$i][4];
		$ID_cella=((int($X_m/100))*100000)+int($Y_m/100);
		
		@Time = ($table_battute->[$i][5] =~ /(\d\d\d\d)-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)/);
		$Time_st = $table_battute->[$i][5];
		
		
		#print "\n00002 $flay_id battuta $Time_st";
		
		@Values = (
			$table_battute->[$i][0],
			$Time_st,
			$X_m,
			$Y_m,
			$H_m,
			$ID_cella,
			$table_battute->[$i][1],
			'N');
		
		$rv = $InsRadar->execute(@Values)
					or die "\n\n ERRORE 08";
		$errore = $InsRadar->errstr;
		$err_code = $InsRadar->err;
		if ($errore)
		{
		print "\n\n ERRORE 08 Questo e' l' errore dato dall' inserimento della prima riga di dati\n\n\n$errore\n\n";
		}
		if ($i > 0)
		{
			@deltaT = Delta_DHMS(@Time_old,@Time); # vedere la documentatione perl del modulo Date::Calc
			$delta_s = ($deltaT[2]*60)+$deltaT[3];
			$n_interpol = $delta_s-1;
			#print "flay: $flay_id @Time batt: $i -- \t @Time_old -- @Time -- @deltaT\n";
			#print "\nfly -> $flay_id punti da interpolare =  $n_interpol\n delta t = $delta_s";
			if ($n_interpol >= 1)
			{
				$velX = ($X_m-$Xold)/$delta_s;  # velocita dell' aereo tra le due battute
				$velY = ($Y_m-$Yold)/$delta_s;  # velocita dell' aereo tra le due battute
				$velH = ($H_m-$Hold)/$delta_s; 
				for $j (1..$n_interpol)
				{
					$X_int = $Xold + $velX*$j;
					$Y_int = $Yold + $velY*$j;
					$ID_cella_int=((int($X_int/100))*100000)+int($Y_int/100);
					$H_int = $Hold + $velH*$j;

					@Time_int = Add_Delta_DHMS(@Time_old,0,0,0,$j);
					$Time_int_st = "$Time_int[0]-$Time_int[1]-$Time_int[2] $Time_int[3]:$Time_int[4]:$Time_int[5]";			

					@Values = (
						$table_battute->[$i][0],
						$Time_int_st,
						$X_int,
						$Y_int,
						$H_int,
						$ID_cella_int,
						$table_battute->[$i][1],
						'Y');

					$rv = $InsRadar->execute(@Values) 
							or die "\n\n ERRORE 10\n";
					$errore = $InsRadar->errstr;
					$err_code= $InsRadar->err;
				}
			}
		}
		$Xold = $X_m;
		$Yold = $Y_m;
		$Hold = $H_m;
		@Time_old = @Time;
	        #print "\n ora vecchia = @Time_old";
	}
}

$sth->finish;
$sth2->finish;
#$InsRadar->finish;
#$db_radar->do("UNLOCK TABLE");
#$rc = $db_radar->disconnect;

#######################  FINE CREAZIONE TABELLA DENSITA CON BATTUTE INTERPOLATE ############

############ QUERY ESTRAZIONE TABELLA DENSITA e SCITTURA FILE #############################

$db_radar2 = DBI->connect("DBI:mysql:$DB_densita:$IP", $nome_utente, $password) ||  
die "\n\n\n  -- FATAL ERROR :  Non mi posso connettere al database:$DBI::errstr\n\n\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";



####################### END  ###################################################
open(FILEOUTPUT,'>',$file_outup);
print (FILEOUTPUT "DATA|ORA|AIRCRAFT_TYPE|H_MEDIA|H_MIN|H_MAX|H_DEV|ID_CELLA|N_BATTUTE\n"); 

$sel_densita_day =	"SELECT date_format(data_ora_italy,'%Y/%m/%d') as data,
				date_format(data_ora_italy,'%k') as ora,
				airc.classe as aicraft_type,
				AVG(H_m) as H_media, 
				MIN(H_m) as H_min, 
				MAX(H_m) as H_max, 
				round(STD(H_m),2) as H_dev, 
				a.ID_CELLA as ID_CELLA, 
				count(*) as n_battute
				FROM anagrafica.$tabreticolo as a, $tab_densita as den LEFT JOIN anagrafica.an_aircraft as airc ON den.aircraft = airc.ICAO_type
				WHERE den.ID_CELLA = a.ID_CELLA
				GROUP BY airc.classe, den.ID_CELLA, date_format(data_ora_italy,'%k')";
				
print "ECCO LA QUERY:\n\n$sel_densita_day\n\n";				
				
$h_sel_densita_day = $db_radar2->prepare($sel_densita_day) || die "Can't prepare $sel_densita_day:" . $db_radar->errstr;
$rv = $h_sel_densita_day->execute || die "can't execute the query: $h_sel_densita_day->errstr";
while(@row = $h_sel_densita_day->fetchrow_array)
{
	#print "sono nel ciclo\n";
	if ($row[2] ne '')
	{
		print (FILEOUTPUT "$row[0]|$row[1]|$row[2]|$row[3]|$row[4]|$row[5]|$row[6]|$row[7]|$row[8]\n");
	}
	else
	{
		print (FILEOUTPUT "$row[0]|$row[1]|99|$row[3]|$row[4]|$row[5]|$row[6]|$row[7]|$row[8]\n");
	}
}
$rc = $db_radar2->disconnect;
############### funzioni ##########################################################

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
