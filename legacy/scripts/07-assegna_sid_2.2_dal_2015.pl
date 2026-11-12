##############################################################################################
#
# Title:	Assegna SID
# Author:	Matteo Giampaolo, Fabio Forfori
# Date:		perso nella notte dei tempo
# Revision: 	????-??-??	Matteo Giampaolo (innumerrevoli volte) chiedere a lui per la logica 
#				arcana ed esoterica dietro le assegnazione delle sid
#		2007-02-22	Bartolomeo Telaro
#		2015-05-08	Roberta Pollini(inserita nuova SID 071 modificando vecchie info sulla 070 e modificato quadrilatero della 070 e della 358)
# Comment:	Analizza le tracce (decolli) con validation_bt = 1 e pista assegnata
#		cioè su cui hanno girato correttamente tutti gli script precedenti
#		e cerca di assegnareuna SID, se non ci riesce setta a 'NA' il campo SID
#
# Table usate:		flay, battute
#
###############################################################################################

if ($ARGV[0] eq '/help')
{
print 	"\n\n\n#########################################################################
######  									########
######  									########
########################################################################################\n\n\n";
die;
}

use DBI;

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

print "INSERIRE LA DATA DI INIZIO (YYYY-mm-dd): ";
$datainizio = <STDIN>;
chomp($datainizio);

print "INSERIRE LA DATA DI FINE (YYYY-mm-dd): ";
$datafine = <STDIN>;
chomp($datafine);

print "INSERIRE IL NOME UTENTE: ";
$nome_utente=<STDIN>;
chomp($nome_utente);

print "INSERIRE LA PASSWORD (VISUALIZZATA IN CHIARO!): ";
$password=<STDIN>;
chomp($password);

$db_radar = DBI->connect("DBI:mysql:$database:$IP", $nome_utente, $password) || 
die "Non mi posso connettere al database:$DBI::errstr\n";
print "\nCONNESSIONE AL DATABASE RIUSCITA\n\n";

$B = length($database);
print "\n\n\t\t";
for ($L=0; $L < $B; $L++){print"*";}
print "********************************************** \n";
print "\t\t****    CONNECTION TO DB '$database' SUCCESSFUL    **** \n\t\t";
for ($L=0; $L < $B; $L++){print"*";}
print "********************************************** \n\n\n\n\n\n";
 
@data_ora=localtime(time);
$data_ora[4]=$data_ora[4]+1;
$data_ora[5]=$data_ora[5]+1900;

$nomefileOUT = "report\\07assegna_sid-$database\_$nome_utente\_$data_ora[3]-$data_ora[4]-$data_ora[5]\_$data_ora[2]-$data_ora[1]-$data_ora[0].log";
open(FILEOUTPUT,'>>',$nomefileOUT);
print "\n\n**** ASSEGNA SID *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n";
print (FILEOUTPUT "***** ASSEGNA SID *****\n$data_ora[3]/$data_ora[4]/$data_ora[5]\t$data_ora[2]:$data_ora[1]:$data_ora[0]\n\n");

print (FILEOUTPUT "\n\n\t\t");
for ($L=0; $L < $B; $L++){print(FILEOUTPUT "*");}
print (FILEOUTPUT "********************************************** \n");
print (FILEOUTPUT "\t\t****    CONNECTION TO DB '$database' SUCCESSFUL    **** \n\t\t");
for ($L=0; $L < $B; $L++){print(FILEOUTPUT "*");}
print (FILEOUTPUT "********************************************** \n\n\n\n");


$sel_track = "SELECT row_id, pista FROM flay WHERE (date_format(data_ora_arr,'%Y-%m-%d') BETWEEN '$datainizio' AND '$datafine') AND flay_operation = 'D' AND validation_bt > 0 AND pista IS NOT NULL AND sid IS NULL";
$errstr=$db_radar->errstr;
$selTh = $db_radar->prepare($sel_track) || die "Can't prepare $statement: $errstr\n";
$errstr=$selTh->errstr;
$rv = $selTh->execute || die "can't execute the query: $errstr\n";
$rv == 0 && die "\n non ci sono tracce non assegnate \n ";

#**************************************************************************************************************
#************************************* ALGORITMO PER MALPENSA *************************************************
#**************************************************************************************************************

if ($aeroporto eq 'LIMC')
{
	@A358=(1473763,5068161);
	@B358=(1484851,5067590);
	@C358=(1479321,5058882);
	@D358=(1475557,5056132);

	$mAB358=($A358[1]-$B358[1])/($A358[0]-$B358[0]);
	$mBC358=($B358[1]-$C358[1])/($B358[0]-$C358[0]);
	$mCD358=($C358[1]-$D358[1])/($C358[0]-$D358[0]);
	$mDA358=($D358[1]-$A358[1])/($D358[0]-$A358[0]);
	print"$mAB358\t$mBC358\t$mCD358\t$mDA358\n";
	
	$qAB358=$B358[1]-$mAB358*$B358[0];
	$qBC358=$C358[1]-$mBC358*$C358[0];
	$qCD358=$D358[1]-$mCD358*$D358[0];
	$qDA358=$A358[1]-$mDA358*$A358[0];
	print"AB: $qAB358\tBC: $qBC358\tCD: $qCD358\tDA: $qDA358\n";
	
	
	@A071=(1482823,5060674);
	@B071=(1482706,5058919);
	@C071=(1479914,5057691);
	@D071=(1479321,5058882);

	$mAB071=($A071[1]-$B071[1])/($A071[0]-$B071[0]);
	$mBC071=($B071[1]-$C071[1])/($B071[0]-$C071[0]);
	$mCD071=($C071[1]-$D071[1])/($C071[0]-$D071[0]);
	$mDA071=($D071[1]-$A071[1])/($D071[0]-$A071[0]);
	print"$mAB071\t$mBC071\t$mCD071\t$mDA071\n";
	
	$qAB071=$B071[1]-$mAB071*$B071[0];
	$qBC071=$C071[1]-$mBC071*$C071[0];
	$qCD071=$D071[1]-$mCD071*$D071[0];
	$qDA071=$A071[1]-$mDA071*$A071[0];
	print"AB: $qAB071\tBC: $qBC071\tCD: $qCD071\tDA: $qDA071\n";
	
	
	@A070=(1482706,5058919);
	@B070=(1483762,5054300);
	@C070=(1480663,5054194);
	@D070=(1479914,5057691);

	$mAB070=($A070[1]-$B070[1])/($A070[0]-$B070[0]);
	$mBC070=($B070[1]-$C070[1])/($B070[0]-$C070[0]);
	$mCD070=($C070[1]-$D070[1])/($C070[0]-$D070[0]);
	$mDA070=($D070[1]-$A070[1])/($D070[0]-$A070[0]);
	print"$mAB070\t$mBC070\t$mCD070\t$mDA070\n";
	
	$qAB070=$B070[1]-$mAB070*$B070[0];
	$qBC070=$C070[1]-$mBC070*$C070[0];
	$qCD070=$D070[1]-$mCD070*$D070[0];
	$qDA070=$A070[1]-$mDA070*$A070[0];
	print"AB: $qAB070\tBC: $qBC070\tCD: $qCD070\tDA: $qDA070\n";
	
	
	@A310=(1469874,5063461);
	@B310=(1475462,5058160);
	@C310=(1474600,5057660);
	@D310=(1468218,5060897);

	$mAB310=($A310[1]-$B310[1])/($A310[0]-$B310[0]);
	$mBC310=($B310[1]-$C310[1])/($B310[0]-$C310[0]);
	$mCD310=($C310[1]-$D310[1])/($C310[0]-$D310[0]);
	$mDA310=($D310[1]-$A310[1])/($D310[0]-$A310[0]);
	print"$mAB310\t$mBC310\t$mCD310\t$mDA310\n";

	$qAB310=$B310[1]-$mAB310*$B310[0];
	$qBC310=$C310[1]-$mBC310*$C310[0];
	$qCD310=$D310[1]-$mCD310*$D310[0];
	$qDA310=$A310[1]-$mDA310*$A310[0];
	print"AB: $qAB310\tBC: $qBC310\tCD: $qCD310\tDA: $qDA310\n";
	
	
	@A320=(1476041,5067978);
	@B320=(1480494,5057867);
	@C320=(1475462,5058160);
	@D320=(1469874,5063461);

	$mAB320=($A320[1]-$B320[1])/($A320[0]-$B320[0]);
	$mBC320=($B320[1]-$C320[1])/($B320[0]-$C320[0]);
	$mCD320=($C320[1]-$D320[1])/($C320[0]-$D320[0]);
	$mDA320=($D320[1]-$A320[1])/($D320[0]-$A320[0]);
	print"$mAB320\t$mBC320\t$mCD320\t$mDA320\n";

	$qAB320=$B320[1]-$mAB320*$B320[0];
	$qBC320=$C320[1]-$mBC320*$C320[0];
	$qCD320=$D320[1]-$mCD320*$D320[0];
	$qDA320=$A320[1]-$mDA320*$A320[0];
	print"AB: $qAB320\tBC: $qBC320\tCD: $qCD320\tDA: $qDA320\n";
	
	
	@A280=(1468218,5060897);
	@B280=(1474600,5057660);
	@C280=(1477123,5053290);
	@D280=(1467197,5051528);

	$mAB280=($A280[1]-$B280[1])/($A280[0]-$B280[0]);
	$mBC280=($B280[1]-$C280[1])/($B280[0]-$C280[0]);
	$mCD280=($C280[1]-$D280[1])/($C280[0]-$D280[0]);
	$mDA280=($D280[1]-$A280[1])/($D280[0]-$A280[0]);
	print"$mAB280\t$mBC280\t$mCD280\t$mDA280\n";

	$qAB280=$B280[1]-$mAB280*$B280[0];
	$qBC280=$C280[1]-$mBC280*$C280[0];
	$qCD280=$D280[1]-$mCD280*$D280[0];
	$qDA280=$A280[1]-$mDA280*$A280[0];
	print"AB: $qAB280\tBC: $qBC280\tCD: $qCD280\tDA: $qDA280\n";
	
	
	@A294=(1465813,5054241);
	@B294=(1476236,5052011);
	@C294=(1474813,5041242);
	@D294=(1463736,5044280);

	$mAB294=($A294[1]-$B294[1])/($A294[0]-$B294[0]);
	$mBC294=($B294[1]-$C294[1])/($B294[0]-$C294[0]);
	$mCD294=($C294[1]-$D294[1])/($C294[0]-$D294[0]);
	$mDA294=($D294[1]-$A294[1])/($D294[0]-$A294[0]);
	print"$mAB294\t$mBC294\t$mCD294\t$mDA294\n";

	$qAB294=$B294[1]-$mAB294*$B294[0];
	$qBC294=$C294[1]-$mBC294*$C294[0];
	$qCD294=$D294[1]-$mCD294*$D294[0];
	$qDA294=$A294[1]-$mDA294*$A294[0];
	print"AB: $qAB294\tBC: $qBC294\tCD: $qCD294\tDA: $qDA294\n";
	
	
	@A038=(1483066,5056252);
	@B038=(1498021,5069326);
	@C038=(1514641,5048669);
	@D038=(1496109,5036434);

	$mAB038=($A038[1]-$B038[1])/($A038[0]-$B038[0]);
	$mBC038=($B038[1]-$C038[1])/($B038[0]-$C038[0]);
	$mCD038=($C038[1]-$D038[1])/($C038[0]-$D038[0]);
	$mDA038=($D038[1]-$A038[1])/($D038[0]-$A038[0]);
	print"$mAB038\t$mBC038\t$mCD038\t$mDA038\n";

	$qAB038=$B038[1]-$mAB038*$B038[0];
	$qBC038=$C038[1]-$mBC038*$C038[0];
	$qCD038=$D038[1]-$mCD038*$D038[0];
	$qDA038=$A038[1]-$mDA038*$A038[0];
	print"AB: $qAB038\tBC: $qBC038\tCD: $qCD038\tDA: $qDA038\n";

	ciclo1:
	while(@row_T = $selTh->fetchrow_array)
	{ 
		$fl_id = $row_T[0];
		$pista= $row_T[1];
		$sid='NA';

		$sel_batt = "SELECT X_m, Y_m, H_m FROM battute WHERE flay_id = '$fl_id' AND validation = 'Y'";
		$errstr=$db_radar->errstr;
		$selBh = $db_radar->prepare($sel_batt) || die "Can't prepare $statement: $errstr\n";
		$errstr=$selBh->errstr;
		$rv1 = $selBh->execute || die "can't execute the query: $errstr";
		$rv1 == 0 && print "\n non ci sono battute associate alla traccia $fl_id \n";

		$selBh->fetchrow_array;  # SALTA PRIMA BATTUTA
		while(@battuta = $selBh->fetchrow_array)
		{
			$X=$battuta[0];
			$Y=$battuta[1];
			$Z=$battuta[2];
			########################	SID	070
			if (($Y<$mAB070*$X+$qAB070) &&
				($Y>$mBC070*$X+$qBC070) &&
				($Y>$mCD070*$X+$qCD070) &&
				($Y<$mDA070*$X+$qDA070) &&
				($Z<3500)&&
				$pista eq '35R')
			{
				$sid='070';
				#print"070\t$fl_id\n";
				
				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}			
			########################	SID	071
			if (($Y>$mAB071*$X+$qAB071) &&
				($Y>$mBC071*$X+$qBC071) &&
				($Y>$mCD071*$X+$qCD071) &&
				($Y<$mDA071*$X+$qDA071) &&
				($Z<3500)&&
				$pista eq '35R')
			{
				$sid='071';
				#print"071\t$fl_id\n";
				
				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}			
			########################	SID	358	
			if (($Y<$mAB358*$X+$qAB358) &&
				($Y>$mBC358*$X+$qBC358) &&
				($Y>$mCD358*$X+$qCD358) &&
				($Y>$mDA358*$X+$qDA358) &&
				($Z<3500)&&
				$pista eq '35R')
			{
				$sid='358';
				#print"358\t$fl_id\n";
				
				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}
			#########	SID	280
			if (($Y<$mAB280*$X+$qAB280) &&
				($Y<$mBC280*$X+$qBC280) &&
				($Y>$mCD280*$X+$qCD280) &&
				($Y<$mDA280*$X+$qDA280) &&
				($Z<3500)&&
				$pista eq '35L')
			{
				$sid='280';
				#print"280\t$fl_id\n";

				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}
			########################	SID	310
			if (($Y<$mAB310*$X+$qAB310) &&
				($Y<$mBC310*$X+$qBC310) &&
				($Y>$mCD310*$X+$qCD310) &&
				($Y<$mDA310*$X+$qDA310) &&
				($Z<3500)&&
				$pista eq '35L')
			{
				$sid='310';
				#print"310\t$fl_id\n";
				
				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}
			########################	SID	320
			if (($Y<$mAB320*$X+$qAB320) &&
				($Y>$mBC320*$X+$qBC320) &&
				($Y>$mCD320*$X+$qCD320) &&
				($Y<$mDA320*$X+$qDA320) &&
				($Z<3500)&&
				$pista eq '35L')
			{
				$sid='320';
				#print"320\t$fl_id\n";
				
				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}
			if ($pista eq '17L' || $pista eq '17R')
			{
				#########	SID	294
				if (($Y<$mAB294*$X+$qAB294) &&
					($Y>$mBC294*$X+$qBC294) &&
					($Y>$mCD294*$X+$qCD294) &&
					($Y<$mDA294*$X+$qDA294) &&
					($Z<3500))
				{
					$sid='294';
					#print"294\t$fl_id\n";

					$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
					$errstr=$db_radar->errstr;
					$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
					$errstr=$upTh->errstr;
					$rv = $upTh->execute || die "can't execute the query: $errstr";
					#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
					$rc = $upTh->finish;
					print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
					print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
					next ciclo1;
				}
				#########	SID	038
				if (($Y<$mAB038*$X+$qAB038) &&
					($Y<$mBC038*$X+$qBC038) &&
					($Y>$mCD038*$X+$qCD038) &&
					($Y>$mDA038*$X+$qDA038) &&
					($Z<3500))
				{
					$sid='038';
					#print"038\t$fl_id\n";

					$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
					$errstr=$db_radar->errstr;
					$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
					$errstr=$upTh->errstr;
					$rv = $upTh->execute || die "can't execute the query: $errstr";
					#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
					$rc = $upTh->finish;
					print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
					print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
					next ciclo1;
				}
			}
		
		}
		####################################		SID	168
		if ($sid eq 'NA')
		{
			if ($pista eq '17L' || $pista eq '17R')
			{
				$sid='168';
			}
			
			$up_track = "UPDATE flay SET sid = '$sid' WHERE row_id = $fl_id";
			$errstr=$db_radar->errstr;
			$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
			$errstr=$upTh->errstr;
			$rv = $upTh->execute || die "can't execute the query: $errstr";
			#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
			$rc = $upTh->finish;
			print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
			print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
			next ciclo1;
		}
	}
}
#**************************************************************************************************************
#************************************* FINE ALGORITMO PER MALPENSA ********************************************
#**************************************************************************************************************


#**************************************************************************************************************
#************************************* ALGORITMO PER LINATE ***************************************************
#**********************************(non considera la pista ovest)**********************************************
#**************************************************************************************************************
if ($aeroporto eq 'LIML')
{print "\nQUESTO SCRIPT PUO' GIRARE SOLO PER LINATE\n\n";}

if ($aeroporto eq 'LIML')
{
	@A_SRN5C=(1515090.853,5037026.835);
        @B_SRN5C=(1507453.303,5037133.903);
        @C_SRN5C=(1512842.416,5052444.693);
        @D_SRN5C=(1515733.264,5046662.996);
        
        $mAB_SRN5C=($A_SRN5C[1]-$B_SRN5C[1])/($A_SRN5C[0]-$B_SRN5C[0]);
        $mBC_SRN5C=($B_SRN5C[1]-$C_SRN5C[1])/($B_SRN5C[0]-$C_SRN5C[0]);
        $mCD_SRN5C=($C_SRN5C[1]-$D_SRN5C[1])/($C_SRN5C[0]-$D_SRN5C[0]);
        $mDA_SRN5C=($D_SRN5C[1]-$A_SRN5C[1])/($D_SRN5C[0]-$A_SRN5C[0]);
        print"$mAB_SRN5C\t$mBC_SRN5C\t$mCD_SRN5C\t$mDA_SRN5C\n";
	
	$qAB_SRN5C=$B_SRN5C[1]-$mAB_SRN5C*$B_SRN5C[0];
	$qBC_SRN5C=$C_SRN5C[1]-$mBC_SRN5C*$C_SRN5C[0];
	$qCD_SRN5C=$D_SRN5C[1]-$mCD_SRN5C*$D_SRN5C[0];
	$qDA_SRN5C=$A_SRN5C[1]-$mDA_SRN5C*$A_SRN5C[0];
	print"AB: $qAB_SRN5C\tBC: $qBC_SRN5C\tCD: $qCD_SRN5C\tDA: $qDA_SRN5C\n";
	
	@A_NIKMO5A=(1515733.264,5046662.996);
        @B_NIKMO5A=(1512842.416,5052444.693);
        @C_NIKMO5A=(1523763.398,5052837.277);
        @D_NIKMO5A=(1521764.787,5046091.964);
	
	$mAB_NIKMO5A=($A_NIKMO5A[1]-$B_NIKMO5A[1])/($A_NIKMO5A[0]-$B_NIKMO5A[0]);
        $mBC_NIKMO5A=($B_NIKMO5A[1]-$C_NIKMO5A[1])/($B_NIKMO5A[0]-$C_NIKMO5A[0]);
        $mCD_NIKMO5A=($C_NIKMO5A[1]-$D_NIKMO5A[1])/($C_NIKMO5A[0]-$D_NIKMO5A[0]);
        $mDA_NIKMO5A=($D_NIKMO5A[1]-$A_NIKMO5A[1])/($D_NIKMO5A[0]-$A_NIKMO5A[0]);
        print"$mAB_NIKMO5A\t$mBC_NIKMO5A\t$mCD_NIKMO5A\t$mDA_NIKMO5A\n";

	$qAB_NIKMO5A=$B_NIKMO5A[1]-$mAB_NIKMO5A*$B_NIKMO5A[0];
	$qBC_NIKMO5A=$C_NIKMO5A[1]-$mBC_NIKMO5A*$C_NIKMO5A[0];
	$qCD_NIKMO5A=$D_NIKMO5A[1]-$mCD_NIKMO5A*$D_NIKMO5A[0];
	$qDA_NIKMO5A=$A_NIKMO5A[1]-$mDA_NIKMO5A*$A_NIKMO5A[0];
	print"AB: $qAB_NIKMO5A\tBC: $qBC_NIKMO5A\tCD: $qCD_NIKMO5A\tDA: $qDA_NIKMO5A\n";
	
	@A_TZO5C=(1521764.787,5046091.964);
        @B_TZO5C=(1523763.398,5052837.277);
        @C_TZO5C=(1527386.793,5044235.742);
        @D_TZO5C=(1523849.096,5043280.995);
        
        $mAB_TZO5C=($A_TZO5C[1]-$B_TZO5C[1])/($A_TZO5C[0]-$B_TZO5C[0]);
        $mBC_TZO5C=($B_TZO5C[1]-$C_TZO5C[1])/($B_TZO5C[0]-$C_TZO5C[0]);
        $mCD_TZO5C=($C_TZO5C[1]-$D_TZO5C[1])/($C_TZO5C[0]-$D_TZO5C[0]);
        $mDA_TZO5C=($D_TZO5C[1]-$A_TZO5C[1])/($D_TZO5C[0]-$A_TZO5C[0]);
        print"$mAB_TZO5C\t$mBC_TZO5C\t$mCD_TZO5C\t$mDA_TZO5C\n";

	$qAB_TZO5C=$B_TZO5C[1]-$mAB_TZO5C*$B_TZO5C[0];
	$qBC_TZO5C=$C_TZO5C[1]-$mBC_TZO5C*$C_TZO5C[0];
	$qCD_TZO5C=$D_TZO5C[1]-$mCD_TZO5C*$D_TZO5C[0];
	$qDA_TZO5C=$A_TZO5C[1]-$mDA_TZO5C*$A_TZO5C[0];
	print"AB: $qAB_TZO5C\tBC: $qBC_TZO5C\tCD: $qCD_TZO5C\tDA: $qDA_TZO5C\n";
	
	@A_DORIN5C=(1523849.096,5043280.995);
        @B_DORIN5C=(1527386.793,5044235.742);
        @C_DORIN5C=(1526663.33,5038601.306);
        @D_DORIN5C=(1523889.223,5039132.145);
        
        $mAB_DORIN5C=($A_DORIN5C[1]-$B_DORIN5C[1])/($A_DORIN5C[0]-$B_DORIN5C[0]);
        $mBC_DORIN5C=($B_DORIN5C[1]-$C_DORIN5C[1])/($B_DORIN5C[0]-$C_DORIN5C[0]);
        $mCD_DORIN5C=($C_DORIN5C[1]-$D_DORIN5C[1])/($C_DORIN5C[0]-$D_DORIN5C[0]);
        $mDA_DORIN5C=($D_DORIN5C[1]-$A_DORIN5C[1])/($D_DORIN5C[0]-$A_DORIN5C[0]);
        print"$mAB_DORIN5C\t$mBC_DORIN5C\t$mCD_DORIN5C\t$mDA_DORIN5C\n";

	$qAB_DORIN5C=$B_DORIN5C[1]-$mAB_DORIN5C*$B_DORIN5C[0];
	$qBC_DORIN5C=$C_DORIN5C[1]-$mBC_DORIN5C*$C_DORIN5C[0];
	$qCD_DORIN5C=$D_DORIN5C[1]-$mCD_DORIN5C*$D_DORIN5C[0];
	$qDA_DORIN5C=$A_DORIN5C[1]-$mDA_DORIN5C*$A_DORIN5C[0];
	print"AB: $qAB_DORIN5C\tBC: $qBC_DORIN5C\tCD: $qCD_DORIN5C\tDA: $qDA_DORIN5C\n";
	
	@A_PIKOT=(1523889.223,5039132.145);
        @B_PIKOT=(1526663.33,5038601.306);
        @C_PIKOT=(1525959.213,5031208.137);
        @D_PIKOT=(1523139.744,5032814.164);

        $mAB_PIKOT=($A_PIKOT[1]-$B_PIKOT[1])/($A_PIKOT[0]-$B_PIKOT[0]);
        $mBC_PIKOT=($B_PIKOT[1]-$C_PIKOT[1])/($B_PIKOT[0]-$C_PIKOT[0]);
        $mCD_PIKOT=($C_PIKOT[1]-$D_PIKOT[1])/($C_PIKOT[0]-$D_PIKOT[0]);
        $mDA_PIKOT=($D_PIKOT[1]-$A_PIKOT[1])/($D_PIKOT[0]-$A_PIKOT[0]);
        print"$mAB_PIKOT\t$mBC_PIKOT\t$mCD_PIKOT\t$mDA_PIKOT\n";

	$qAB_PIKOT=$B_PIKOT[1]-$mAB_PIKOT*$B_PIKOT[0];
	$qBC_PIKOT=$C_PIKOT[1]-$mBC_PIKOT*$C_PIKOT[0];
	$qCD_PIKOT=$D_PIKOT[1]-$mCD_PIKOT*$D_PIKOT[0];
	$qDA_PIKOT=$A_PIKOT[1]-$mDA_PIKOT*$A_PIKOT[0];
	print"AB: $qAB_PIKOT\tBC: $qBC_PIKOT\tCD: $qCD_PIKOT\tDA: $qDA_PIKOT\n";
	
        @A_PIA5D=(1527401.35,5028891.24);
        @B_PIA5D=(1523580.173,5030277.09);
        @C_PIA5D=(1526069.32,5023912.946);
        @D_PIA5D=(1522920.885,5025581.347);
        
        $mAB_PIA5D=($A_PIA5D[1]-$B_PIA5D[1])/($A_PIA5D[0]-$B_PIA5D[0]);
        $mBC_PIA5D=($B_PIA5D[1]-$C_PIA5D[1])/($B_PIA5D[0]-$C_PIA5D[0]);
        $mCD_PIA5D=($C_PIA5D[1]-$D_PIA5D[1])/($C_PIA5D[0]-$D_PIA5D[0]);
        $mDA_PIA5D=($D_PIA5D[1]-$A_PIA5D[1])/($D_PIA5D[0]-$A_PIA5D[0]);
        print"$mAB_PIA5D\t$mBC_PIA5D\t$mCD_PIA5D\t$mDA_PIA5D\n";

	$qAB_PIA5D=$B_PIA5D[1]-$mAB_PIA5D*$B_PIA5D[0];
	$qBC_PIA5D=$C_PIA5D[1]-$mBC_PIA5D*$C_PIA5D[0];
	$qCD_PIA5D=$D_PIA5D[1]-$mCD_PIA5D*$D_PIA5D[0];
	$qDA_PIA5D=$A_PIA5D[1]-$mDA_PIA5D*$A_PIA5D[0];
	print"AB: $qAB_PIA5D\tBC: $qBC_PIA5D\tCD: $qCD_PIA5D\tDA: $qDA_PIA5D\n";
	
	@A_SSUD=(1522920.885,5025581.347);
        @B_SSUD=(1526069.32,5023912.946);
        @C_SSUD=(1515403.694,5022993.038);
        @D_SSUD=(1516721.395,5026540.678);
        
        $mAB_SSUD=($A_SSUD[1]-$B_SSUD[1])/($A_SSUD[0]-$B_SSUD[0]);
        $mBC_SSUD=($B_SSUD[1]-$C_SSUD[1])/($B_SSUD[0]-$C_SSUD[0]);
        $mCD_SSUD=($C_SSUD[1]-$D_SSUD[1])/($C_SSUD[0]-$D_SSUD[0]);
        $mDA_SSUD=($D_SSUD[1]-$A_SSUD[1])/($D_SSUD[0]-$A_SSUD[0]);
        print"$mAB_SSUD\t$mBC_SSUD\t$mCD_SSUD\t$mDA_SSUD\n";

	$qAB_SSUD=$B_SSUD[1]-$mAB_SSUD*$B_SSUD[0];
	$qBC_SSUD=$C_SSUD[1]-$mBC_SSUD*$C_SSUD[0];
	$qCD_SSUD=$D_SSUD[1]-$mCD_SSUD*$D_SSUD[0];
	$qDA_SSUD=$A_SSUD[1]-$mDA_SSUD*$A_SSUD[0];
	print"AB: $qAB_SSUD\tBC: $qBC_SSUD\tCD: $qCD_SSUD\tDA: $qDA_SSUD\n";
	
	ciclo1:
	while(@row_T = $selTh->fetchrow_array)
	{ 
		$fl_id = $row_T[0];
		$pista= $row_T[1];
		$sid='NA';

		$sel_batt = "SELECT X_m, Y_m, H_m FROM battute WHERE flay_id = '$fl_id' AND validation = 'Y'";
		$errstr=$db_radar->errstr;
		$selBh = $db_radar->prepare($sel_batt) || die "Can't prepare $statement: $errstr\n";
		$errstr=$selBh->errstr;
		$rv1 = $selBh->execute || die "can't execute the query: $errstr";
		$rv1 == 0 && print "\n non ci sono battute associate alla traccia $fl_id \n";

		$selBh->fetchrow_array;  # SALTA PRIMA BATTUTA
		while(@battuta = $selBh->fetchrow_array)
		{
			$X=$battuta[0];
			$Y=$battuta[1];
			$Z=$battuta[2];
			####################################	SID	SRN5C	
			if (($Y>$mAB_SRN5C*$X+$qAB_SRN5C) &&
				($Y<$mBC_SRN5C*$X+$qBC_SRN5C) &&
				($Y<$mCD_SRN5C*$X+$qCD_SRN5C) &&
				($Y>$mDA_SRN5C*$X+$qDA_SRN5C) &&
				($Z<3500)&&
				$pista eq '36R')
			{
				$sid='SRN5C';
				#print"SRN5C\t$fl_id\n";

				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}
			####################################	SID	NIKMO5A
			if (($Y>$mAB_NIKMO5A*$X+$qAB_NIKMO5A) &&
				($Y<$mBC_NIKMO5A*$X+$qBC_NIKMO5A) &&
				($Y>$mCD_NIKMO5A*$X+$qCD_NIKMO5A) &&
				($Y>$mDA_NIKMO5A*$X+$qDA_NIKMO5A) &&
				($Z<3500)&&
				$pista eq '36R')
			{
				$sid='NIKMO';
				#print"NIKMO\t$fl_id\n";
				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}
			####################################	SID	TZO5C
			if (($Y<$mAB_TZO5C*$X+$qAB_TZO5C) &&
				($Y<$mBC_TZO5C*$X+$qBC_TZO5C) &&
				($Y>$mCD_TZO5C*$X+$qCD_TZO5C) &&
				($Y>$mDA_TZO5C*$X+$qDA_TZO5C) &&
				($Z<3500)&&
				$pista eq '36R')
			{
				$sid='TZO5C';
				#print"TZO5C\t$fl_id\n";
			
				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}
			####################################	SID	DORIN5C
			if (($Y<$mAB_DORIN5C*$X+$qAB_DORIN5C) &&
				($Y>$mBC_DORIN5C*$X+$qBC_DORIN5C) &&
				($Y>$mCD_DORIN5C*$X+$qCD_DORIN5C) &&
				($Y>$mDA_DORIN5C*$X+$qDA_DORIN5C) &&
				($Z<3500)&&
				$pista eq '36R')
			{
				$sid='DORIN';
				#print"DORIN\t$fl_id\n";
				
				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}
			
			####################################	SID	PIKOT
			if (($Y<$mAB_PIKOT*$X+$qAB_PIKOT) &&
				($Y>$mBC_PIKOT*$X+$qBC_PIKOT) &&
				($Y>$mCD_PIKOT*$X+$qCD_PIKOT) &&
				($Y<$mDA_PIKOT*$X+$qDA_PIKOT) &&
				($Z<3500)&&
				$pista eq '36R')
			{
				$sid='PIKOT';
				#print"PIKOT\t$fl_id\n";
				
				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}
			####################################	SID	PIA5D
			if (($Y<$mAB_PIA5D*$X+$qAB_PIA5D) &&
				($Y>$mBC_PIA5D*$X+$qBC_PIA5D) &&
				($Y>$mCD_PIA5D*$X+$qCD_PIA5D) &&
				($Y<$mDA_PIA5D*$X+$qDA_PIA5D) &&
				($Z<3500)&&
				$pista eq '36R')
			{
				$sid='PIA5D';
				#print"PIA5D\t$fl_id\n";
				
				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}
			
			####################################	SID	SSUD
			if (($Y<$mAB_SSUD*$X+$qAB_SSUD) &&
				($Y>$mBC_SSUD*$X+$qBC_SSUD) &&
				($Y<$mCD_SSUD*$X+$qCD_SSUD) &&
				($Y<$mDA_SSUD*$X+$qDA_SSUD) &&
				($Z<3500)&&
				$pista eq '36R')
			{
				$sid='SSUD';
				#print"SSUD\t$fl_id\n";
				
				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}		
		}
	}
}
#************************************* FINE ALGORITMO PER LINATE **********************************************
#**************************************************************************************************************


#**************************************************************************************************************
#************************************* ALGORITMO PER ORIO *****************************************************
#**************************************************************************************************************

if ($aeroporto eq 'LIME')
{
	@A267=(1549171.43,5058931.15);
	@B267=(1549763.78,5058007.02);
	@C267=(1547546.33,5056957.03);
	@D267=(1547327.13,5060601.08);

	$mAB267=($A267[1]-$B267[1])/($A267[0]-$B267[0]);
	$mBC267=($B267[1]-$C267[1])/($B267[0]-$C267[0]);
	$mCD267=($C267[1]-$D267[1])/($C267[0]-$D267[0]);
	$mDA267=($D267[1]-$A267[1])/($D267[0]-$A267[0]);
	print"$mAB267\t$mBC267\t$mCD267\t$mDA267\n";
	
	$qAB267=$B267[1]-$mAB267*$B267[0];
	$qBC267=$C267[1]-$mBC267*$C267[0];
	$qCD267=$D267[1]-$mCD267*$D267[0];
	$qDA267=$A267[1]-$mDA267*$A267[0];
	print"AB: $qAB267\tBC: $qBC267\tCD: $qCD267\tDA: $qDA267\n";
	
	
	@A220=(1551802.65,5058471.32);
	@B220=(1551389.67,5057988.50);
	@C220=(1549828.12,5058028.29);
	@D220=(1550317.79,5058392.81);

	$mAB220=($A220[1]-$B220[1])/($A220[0]-$B220[0]);
	$mBC220=($B220[1]-$C220[1])/($B220D[0]-$C220[0]);
	$mCD220=($C220[1]-$D220[1])/($C220[0]-$D220[0]);
	$mDA220=($D220[1]-$A220[1])/($D220[0]-$A220[0]);
	print"$mAB11D\t$mBC11D\t$mCD11D\t$mDA11D\n";
	
	$qAB220=$B220[1]-$mAB220*$B220[0];
	$qBC220=$C220[1]-$mBC220*$C220[0];
	$qCD220=$D220[1]-$mCD220*$D220[0];
	$qDA220=$A220[1]-$mDA220*$A220[0];
	print"AB: $qAB11D\tBC: $qBC11D\tCD: $qCD11D\tDA: $qDA11D\n";
	
	
	@A044=(1553575.71,5057620.31);
	@B044=(1553898.98,5056944.98);
	@C044=(1551644.92,5057278.46);
	@D044=(1551239.75,5057973.03);

	$mAB044=($A044[1]-$B044[1])/($A044[0]-$B044[0]);
	$mBC044=($B044[1]-$C044[1])/($B044[0]-$C044[0]);
	$mCD044=($C044[1]-$D044[1])/($C044[0]-$D044[0]);
	$mDA044=($D044[1]-$A044[1])/($D044[0]-$A044[0]);
	print"$mAB11D\t$mBC11D\t$mCD11D\t$mDA11D\n";
	
	$qAB044=$B044[1]-$mAB044*$B044[0];
	$qBC044=$C044[1]-$mBC044*$C044[0];
	$qCD044=$D044[1]-$mCD044*$D044[0];
	$qDA044=$A044[1]-$mDA044*$A044[0];
	print"AB: $qAB11D\tBC: $qBC11D\tCD: $qCD11D\tDA: $qDA11D\n";
	
	
	ciclo1:
	while(@row_T = $selTh->fetchrow_array)
	{ 
		$fl_id = $row_T[0];
		$pista= $row_T[1];
		$sid='NA';

		$sel_batt = "SELECT X_m, Y_m, H_m FROM battute WHERE flay_id = '$fl_id' AND validation = 'Y'";
		$errstr=$db_radar->errstr;
		$selBh = $db_radar->prepare($sel_batt) || die "Can't prepare $statement: $errstr\n";
		$errstr=$selBh->errstr;
		$rv1 = $selBh->execute || die "can't execute the query: $errstr";
		$rv1 == 0 && print "\n non ci sono battute associate alla traccia $fl_id \n";

		$selBh->fetchrow_array;  # SALTA PRIMA BATTUTA
		while(@battuta = $selBh->fetchrow_array)
		{
			$X=$battuta[0];
			$Y=$battuta[1];
			$Z=$battuta[2];

			if ($pista eq '29')
			{
				####################################	SID	267
				if (($Y<$mAB267*$X+$qAB267) &&
					($Y>$mBC267*$X+$qBC267) &&
					($Y>$mCD267*$X+$qCD267) &&
					($Y<$mDA267*$X+$qDA267) &&
					($Z<3500))
				{
					$sid='267';
					#print"SRN\t$fl_id\n";

					$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
					$errstr=$db_radar->errstr;
					$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
					$errstr=$upTh->errstr;
					$rv = $upTh->execute || die "can't execute the query: $errstr";
					#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
					$rc = $upTh->finish;
					print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
					print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
					next ciclo1;
				}
				####################################	SID	220
				if (($Y>$mAB220*$X+$qAB220) &&
					($Y>$mBC220*$X+$qBC220) &&
					($Y<$mCD220*$X+$qCD220) &&
					($Y<$mDA220*$X+$qDA220) &&
					($Z<3500))
				{
					$sid='220';
					#print"166\t$fl_id\n";

					$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
					$errstr=$db_radar->errstr;
					$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
					$errstr=$upTh->errstr;
					$rv = $upTh->execute || die "can't execute the query: $errstr";
					#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
					$rc = $upTh->finish;
					print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
					print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
					next ciclo1;
				}
				####################################	SID	044
				if (($Y<$mAB044*$X+$qAB044) &&
					($Y>$mBC044*$X+$qBC044) &&
					($Y>$mCD044*$X+$qCD044) &&
					($Y<$mDA044*$X+$qDA044) &&
					($Z<3500))
				{
					$sid='044';
					#print"166\t$fl_id\n";

					$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
					$errstr=$db_radar->errstr;
					$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
					$errstr=$upTh->errstr;
					$rv = $upTh->execute || die "can't execute the query: $errstr";
					#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
					$rc = $upTh->finish;
					print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
					print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
					next ciclo1;
				}			
			}		
			if ($pista eq '11')
			{
				####################################	SID	150
				$sid='150';

				$up_track = "update flay set sid = '$sid' where row_id = $fl_id";
				$errstr=$db_radar->errstr;
				$upTh = $db_radar->prepare($up_track) || die "Can't prepare $statement: $errstr\n";
				$errstr=$upTh->errstr;
				$rv = $upTh->execute || die "can't execute the query: $errstr";
				#$rv == 0 && die "\n non ha updatato nessuna riga in track2 \n ";
				$rc = $upTh->finish;
				print (FILEOUTPUT "Assegnata SID  $sid   alla Traccia N. $fl_id\n");
				print "Assegnata  SID  $sid   alla Traccia N. $fl_id\n";
				next ciclo1;
			}
		}
	}
}
#************************************* FINE ALGORITMO PER ORIO ************************************************
#**************************************************************************************************************


#**************************************************************************************************************
#************************************* ALGORITMO PER ORIO *****************************************************
#**************************************************************************************************************

if ($aeroporto eq 'LIPO')
{
	die "ALGORITMO NON IMPLEMENTATO PER MONTICHIARI";
}
#************************************* FINE ALGORITMO PER ORIO ************************************************
#**************************************************************************************************************

if ($aeroporto ne 'LIMC' && $aeroporto ne 'LIML' && $aeroporto ne 'LIME' && $aeroporto ne 'LIPO')
{
	die "SIGLA AEROPORTO NON CORRETTA"
}

##########################################  Update Sid NULLE #######################################
$up_track3 = "UPDATE flay SET sid = 'NA' WHERE validation_bt = 1 AND pista IS NOT NULL AND sid IS NULL";
$errstr=$db_radar->errstr;
$rv3 = $db_radar->do($up_track3) || die "Can't prepare $statement: $errstr\n";

print (FILEOUTPUT "Traccie a cui non si è riusciti ad assegnare uns sid = $rv3\n");
####################################################################################################

print (FILEOUTPUT "****Situazione complessiva SDI DB****\n");

$sel_report= "SELECT sid, count(*) FROM flay WHERE flay_operation='D' AND validation_bt = 1  GROUP BY SID";
$sel_report_h=$db_radar->prepare($sel_report);
$rv=$sel_report_h->execute;

while(@report=$sel_report_h->fetchrow_array)
{
	print "\n@report\n";
	print (FILEOUTPUT "\n@report\n");
}

############################   AGGIORNA STAR ATTERRAGGI  ############################################

@data_oraE=localtime(time);
$data_oraE[4]=$data_oraE[4]+1;
$data_oraE[5]=$data_oraE[5]+1900;
$secondidelta = (3600*$data_oraE[2] + 60*$data_oraE[1] + $data_oraE[0])-(3600*$data_ora[2] + 60*$data_ora[1] + $data_ora[0]);
print (FILEOUTPUT "$data_oraE[3]/$data_oraE[4]/$data_oraE[5]\t$data_oraE[2]:$data_oraE[1]:$data_oraE[0]\n***** ASSEGNA SID FINE*****\n");
print (FILEOUTPUT "secondi trascorsi =  $secondidelta\n");
print "secondi trascorsi $secondidelta\n";
close (FILEOUTPUT);

$sel_report_h->finish;
