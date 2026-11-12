
use Time::Local;    # carica la libreria per gestire le date e i fusi orari
use DBI; # carica la libreria DBI per connetrsi con il DB
use Date::Calc qw(
		Delta_DHMS
		Delta_Days
		Add_Delta_Days
		Add_Delta_DHMS); # carica una libreria per il calcolo delle date
		
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

print "INSERIRE LA DATA DI INIZIO DELLE OPERAZIONI AEREE (YYYY-mm-dd hh:mm:ss): ";
$data_inizio=<STDIN>;
chop($data_inizio);
print "INSERIRE LA DATA DI FINE DELLE OPERAZIONI AEREE (YYYY-mm-dd hh:mm:ss): ";
$data_fine=<STDIN>;
chop($data_fine);


$data_inizio_str = $data_inizio;
$data_fine_str = $data_fine;
$data_inizio_str =~ s/://g;
$data_fine_str =~ s/://g;



$db_radar = DBI->connect("DBI:mysql:$database:localhost", $nome_utente, $password) ||  
die "\n\n\n  -- FATAL ERROR :  Non mi posso connettere al database:$DBI::errstr\n\n\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

@data_ora=localtime(time);
$data_ora[4]=$data_ora[4]+1;
$data_ora[5]=$data_ora[5]+1900;

$dir_tracks = "d:/Cartografia/TRACKS2GIS/";


$sel_str = "select flay_operation, pista, sid, validation_fl, validation_bt, count(*)
			FROM flay
			WHERE data_ora_italy between '$data_inizio' AND '$data_fine'
			group by flay_operation,pista,sid, validation_fl, validation_bt
			order by pista, sid";  # il numero di tracce raggruppate per flay_operation,pista,sid, validation_fl, validation_bt
$sel_h = $db_radar->prepare($sel_str) ||
	chomp($errstr=$sel_h->errstr) &&
	die "Can't prepare $statement: $errstr\n";
$rv = $sel_h->execute ||
	chomp($errstr=$sel_h->errstr) &&
	die "Can't prepare $statement: $errstr\n";
while(@row_Fl = $sel_h->fetchrow_array)
{
	$operazione	= $row_Fl[0];
	$pista	= $row_Fl[1];
	$sid	= $row_Fl[2];
	$val_fl = $row_Fl[3];
	$val_bt = $row_Fl[4];
	
	if ($operazione	&& $pista && $sid && $val_fl && $val_bt)
	{
		$nome_file_tracks = $database.'_'.$operazione.'_'.$pista.'_'.$sid.'_'.$val_fl.'_'.$val_bt.'_'.$data_inizio_str.'-'.$data_fine_str.'.txt';
		$file_tracks = $dir_tracks.$nome_file_tracks;
		print '### TUTTI I CAMPI NON NULLI ####\n';
		print "DB: $database \t op: $operazione \t pista: $pista \t sid: $sid \t calfl: $val_fl \t valbt: $val_bt\n";
		print "FILE OUTPUT $nome_file_tracks\n";
		print "FILE OUTPUT $file_tracks\n\n";
		
		$sel_y_str = "(SELECT 'row_id', 'time_italy', 'X_m', 'Y_m', 'H_m', 'z_m', 'validation','flay_id', 'data_ora_arr', 'operation', 'pista', 'sid', 'aircraft', 'dep', 'arr', 'val_fl', 'val_bt')
						UNION
						(SELECT 
						bt.row_id, bt.time_italy, bt.X_m, bt.Y_m, bt.H_m, bt.z_m, bt.validation,
						bt.flay_id, fl.data_ora_arr, fl.flay_operation, fl.pista, fl.sid, fl.aircraft, fl.airport_dep as dep, fl.airport_arr as arr, fl.validation_fl, fl.validation_bt
						INTO OUTFILE '$file_tracks'
						FROM battute as bt JOIN flay as fl on bt.flay_id = fl.row_id
						WHERE data_ora_italy between '$data_inizio' AND '$data_fine' 
						AND flay_operation = '$operazione' AND pista = '$pista' AND sid = '$sid' 
						AND validation_fl = '$val_fl'
						AND validation_bt = $val_bt
						ORDER BY bt.flay_id, bt.row_id)";

		$sel_y_h = $db_radar->prepare($sel_y_str) ||
			chomp($errstr=$sel_y_h->errstr) &&
			die "Can't prepare $statement: $errstr\n";
		$rv = $sel_y_h->execute ||
			chomp($errstr=$sel_y_h->errstr) &&
			die "Can't prepare $statement: $errstr\n";
	}
	elsif ($val_fl eq 'N')	## estrai le tracce nulle ovvero cona validation_fl = N 
	{
		$nome_file_tracks = $database.'_'.$operazione.'_NULL_NULL_'.$val_fl.'_NULL_'.$data_inizio_str.'-'.$data_fine_str.'.txt';
		$file_tracks = $dir_tracks.$nome_file_tracks;
		print '### VALIDATION_FL = N ####\n';
		print "DB: $database \t op: $operazione \t pista: $pista \t sid: $sid \t calfl: $val_fl \t valbt: $val_bt\n";
		print "FILE OUTPUT $nome_file_tracks\n";
		print "FILE OUTPUT $file_tracks\n\n";
		
		$sel_y_str = "(SELECT 'row_id', 'time_italy', 'X_m', 'Y_m', 'H_m', 'z_m', 'validation','flay_id', 'data_ora_arr', 'operation', 'pista', 'sid', 'aircraft', 'dep', 'arr', 'val_fl', 'val_bt')
						UNION
						(SELECT 
						bt.row_id, bt.time_italy, bt.X_m, bt.Y_m, bt.H_m, bt.z_m, bt.validation,
						bt.flay_id, fl.data_ora_arr, fl.flay_operation, fl.pista, fl.sid, fl.aircraft, fl.airport_dep as dep, fl.airport_arr as arr, fl.validation_fl, fl.validation_bt
						INTO OUTFILE '$file_tracks'
						FROM battute as bt JOIN flay as fl on bt.flay_id = fl.row_id
						WHERE data_ora_italy between '$data_inizio' AND '$data_fine' 
						AND flay_operation = '$operazione' AND pista IS NULL AND sid IS NULL 
						AND validation_fl = '$val_fl'
						AND validation_bt IS NULL
						ORDER BY bt.flay_id, bt.row_id)";

		$sel_y_h = $db_radar->prepare($sel_y_str) ||
			chomp($errstr=$sel_y_h->errstr) &&
			die "Can't prepare $statement: $errstr\n";
		$rv = $sel_y_h->execute ||
			chomp($errstr=$sel_y_h->errstr) &&
			die "Can't prepare $statement: $errstr\n";
	}
	elsif(!$pista && !$sid)
	{
		print '### VALIDI MA SENZa PISta E SENZA SID ####\n';
		$nome_file_tracks = $database.'_'.$operazione.'_NULL_NULL_'.$val_fl.'_'.$val_bt.'_'.$data_inizio_str.'-'.$data_fine_str.'.txt';
		$file_tracks = $dir_tracks.$nome_file_tracks;
		
		print "DB: $database \t op: $operazione \t pista: $pista \t sid: $sid \t calfl: $val_fl \t valbt: $val_bt\n";
		print "FILE OUTPUT $nome_file_tracks\n";
		print "FILE OUTPUT $file_tracks\n\n";
		
		$sel_y_str = "(SELECT 'row_id', 'time_italy', 'X_m', 'Y_m', 'H_m', 'z_m', 'validation','flay_id', 'data_ora_arr', 'operation', 'pista', 'sid', 'aircraft', 'dep', 'arr', 'val_fl', 'val_bt')
						UNION
						(SELECT 
						bt.row_id, bt.time_italy, bt.X_m, bt.Y_m, bt.H_m, bt.z_m, bt.validation,
						bt.flay_id, fl.data_ora_arr, fl.flay_operation, fl.pista, fl.sid, fl.aircraft, fl.airport_dep as dep, fl.airport_arr as arr, fl.validation_fl, fl.validation_bt
						INTO OUTFILE '$file_tracks'
						FROM battute as bt JOIN flay as fl on bt.flay_id = fl.row_id
						WHERE data_ora_italy between '$data_inizio' AND '$data_fine'
						AND flay_operation = '$operazione' AND pista IS NULL AND sid IS NULL 
						AND validation_fl = '$val_fl'
						AND validation_bt = '$val_bt'
						ORDER BY bt.flay_id, bt.row_id)";

		$sel_y_h = $db_radar->prepare($sel_y_str) ||
			chomp($errstr=$sel_y_h->errstr) &&
			die "Can't prepare $statement: $errstr\n";
		$rv = $sel_y_h->execute ||
			chomp($errstr=$sel_y_h->errstr) &&
			die "Can't prepare $statement: $errstr\n";	
	}
	elsif($pista && !$sid)
	{
		$nome_file_tracks = $database.'_'.$operazione.'_'.$pista.'_NULL_'.$val_fl.'_'.$val_bt.'_'.$data_inizio_str.'-'.$data_fine_str.'.txt';
		$file_tracks = $dir_tracks.$nome_file_tracks;
		print '### PISTA SI SID NO ####\n';
		print "DB: $database \t op: $operazione \t pista: $pista \t sid: $sid \t calfl: $val_fl \t valbt: $val_bt\n";
		print "FILE OUTPUT $nome_file_tracks\n";
		print "FILE OUTPUT $file_tracks\n";
		
		$sel_y_str = "(SELECT 'row_id', 'time_italy', 'X_m', 'Y_m', 'H_m', 'z_m', 'validation','flay_id', 'data_ora_arr', 'operation', 'pista', 'sid', 'aircraft', 'dep', 'arr', 'val_fl', 'val_bt')
						UNION
						(SELECT 
						bt.row_id, bt.time_italy, bt.X_m, bt.Y_m, bt.H_m, bt.z_m, bt.validation,
						bt.flay_id, fl.data_ora_arr, fl.flay_operation, fl.pista, fl.sid, fl.aircraft, fl.airport_dep as dep, fl.airport_arr as arr, fl.validation_fl, fl.validation_bt
						INTO OUTFILE '$file_tracks'
						FROM battute as bt JOIN flay as fl on bt.flay_id = fl.row_id
						WHERE data_ora_italy between '$data_inizio' AND '$data_fine'
						AND flay_operation = '$operazione' AND pista = '$pista' AND sid IS NULL 
						AND validation_fl = '$val_fl'
						AND validation_bt = '$val_bt'
						ORDER BY bt.flay_id, bt.row_id)";

		$sel_y_h = $db_radar->prepare($sel_y_str) ||
			chomp($errstr=$sel_y_h->errstr) &&
			die "Can't prepare $statement: $errstr\n";
		$rv = $sel_y_h->execute ||
			chomp($errstr=$sel_y_h->errstr) &&
			die "Can't prepare $statement: $errstr\n";	
	}
}
