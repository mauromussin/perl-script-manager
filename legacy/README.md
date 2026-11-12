# Script legacy

## Acquisizione del 2026-11-11

- Origine comune: `E:\TUTTI GLI SCRIPT`, solo file della cartella principale.
- Destinazione: `legacy/scripts/`.
- Acquisiti: 47 file con estensione `.pl` o `.PL`, mantenendo i nomi originali.
- Esclusi: sottocartelle e file con altre estensioni; nessun dato operativo, log o configurazione esterna importato.
- Versione: non certificata; i nomi e i commenti di revisione non costituiscono una versione approvata.
- Controllo preliminare: nessuna password letterale, token o chiave privata segnalata dai pattern statici controllati.
	Le credenziali sono richieste a terminale, da configurazione esterna o da argomenti; questo controllo non certifica l'assenza di ogni dato riservato.
- Sanificazione: non applicata, non essendo stati identificati segreti incorporati nei controlli effettuati.
- Integrita: SHA-256 di ogni copia verificato uguale all'originale. Gli originali non sono stati modificati.
- Esecuzione: nessuno script eseguito, neppure contro un database di prova.
- Inventario: [ricognizione iniziale](../docs/INVENTARIO_SCRIPT.md); analisi approfondita e caratterizzazione ancora da completare.

Gli hash seguenti identificano sia gli originali acquisiti sia le copie. Non modificare gli script
prima dei test di caratterizzazione; non registrarli nel catalogo web come procedure eseguibili.

| Script in legacy/scripts/ | SHA-256 originale e copia |
|---|---|
| 02-carica_DB_2.0 (LIN dal 2024).pl | 423d93939f558e81561be34cd2e2c5e90767de6b78979a8893c3536d20bd53e3 |
| 02-carica_DB_2.0 (LIN dal 2025).PL | be09556309e1b259a983904e9e87867b550602fdbbc3b4af1928f71a3dcbbf84 |
| 02-carica_DB_2.0 (LIN dal 2026).PL | ab4f5a1755abc83aaa4b107902fcbf83518cf362d583040d70c3da2610750710 |
| 02-carica_DB_2.0 (LIN dal 25102017).pl | 13d8e3e7a8d080f80bf00f66c789e49d00e4f7d7237b4d50a66f92aea9005c0c |
| 02-carica_DB_2.0 (ORIO_da_RADAR_LIN).pl | ffe867f27db990d1a1f77f4f4735c10b05d6e61d83be4058fd4a4094743cee4c |
| 02-carica_DB_2.0MXP_dbltrk_da_06032015.pl | 5b5128b8b3e773836f3299b3a3a5386eeb79d04ba7fd47bd550b1e62e81fca0e |
| 02-carica_DB_2.0_ORIO_dbltrk.pl | 455498fbf122dd53c648e26cb8eaddd584090c630fcbcf0175b14d570b3ea165 |
| 02-carica_DB_2.0_ORIO_dbltrk_new_radar.pl | 0cf2b6af73bfd7d39ae314c17ac75722256c26001b7b7ed72949898c48ba7828 |
| 02-carica_DB_2.0_VBS_da_RADAR_LIN_dbltrk.pl | 1532e7f4dfdd373ba5c318ec2663c0d927a822623c7ff82c3960b3aa7772443d |
| 02-carica_DB_2.0_VBS_dbltrk.pl | e32bf755a864c5d21a75ebbba2026e505d01e268e5e0385452c19d5c6c2b3a54 |
| 03-valida_tracce_01.pl | 9d5caaa6d41b91d134b13029f476400585142cbfbaff1fb06b0abb3a1868f61b |
| 03-valida_tracce_01_bs.pl | 170674f133fc24c2139e8193d3096ff0dab9f44dfdf421712954ded66011655e |
| 04-valida_battute_1.0.pl | 0f72018ad522e7104c6767c4fa94fad71c71ac3e80d2c1d5d1d27467ebae9bc8 |
| 05-trova_pista_atterraggi_1.0.pl | 6a9a030f09b62dc495ab594a9bd6a00a7f2761a184379658c5d449a660fdd57e |
| 05-trova_pista_atterraggi_1.1.pl | 3b478fc43f95e569949b4d227ad59d24d1cb223c14e3d6464211f089e5ed2bfc |
| 05-trova_pista_atterraggi_1.2.pl | 3239087a92ca45e9a74ad8c95e64cf67fc83e91fb8c611b398d5a15f6b1926dd |
| 06-trova_pista_decolli_1.1.pl | daa39cf5760e38d43a08d946209e61158a9b7ea1f341dca3dbb15a1fd2fff79f |
| 07-assegna_sid_2.1.pl | 2d0a9549fb774e096c638d9befc764a139c5028c4c7db0140033af2807e90a8f |
| 07-assegna_sid_2.2.pl | 9adfdeb6572474fd184ff2c3ccaa0d0c0036340056cf368211adc8da5d395a91 |
| 07-assegna_sid_2.2_dal_2014.pl | 125342693bad2de29557ab6bb2e9cd58c2fe381869311f2ec52faee214b43c66 |
| 07-assegna_sid_2.2_dal_2015.pl | 03b31bda5590071ef717a97c53d4ffc7684a3b0b964130f497217c9e20b97fa6 |
| 07-assegna_sid_2.2_dal_2015_corr+lipo.pl | 5c2ebbea03f5f3c4eb4b2a0f24983306fc94e7585e6de2ab2619abc29937963b |
| 07-assegna_sid_2.2_dal_2015_corr.pl | ff1d67115b477049003681fbf7e3ac933cfa58d0fc9044724309e9bfcec7a22e |
| 07-assegna_sid_2.2_dal_2015_corr_MXP_da12giu2025.pl | 83b6eb7e32e6c8d4377f63717e6603564ae548bd1b366adbe2c366b911ab018c |
| 07-assegna_sid_2.2_dal_2015_corr_sperimMXP2024.pl | 02e6764eb263a0e069af801145ea7adda6eaf721cf682fde724d8010ecf70763 |
| 07-assegna_sid_2.2_dal_2015_orio_sid044.pl | 853fe42d7ccbb35b007944fa30d0e53fee96e37ec5d52af349f58d457de35893 |
| 08-rettifica_quote_nulle_1.1.pl | baf069d8a51dad0ff9341b0f3afbe4e1dfa6cea9f874e20b79e57d1754e661aa |
| 09-carica_dati_meteo_1.3.pl | 8ef12eec1ff2ac6d2c5454edc863b4bf3979b136a00d1699bad8a78da1d4191e |
| 09-carica_dati_meteo_1.4.pl | 7f72a597ddd59050d52b041336b16dffb8f046f25e7eb42bf9098c9fc17fcfcb |
| 09-carica_dati_meteo_1.5.pl | 1c7a2571f922a2384720da0ff038d36d4f2ee85b09725ac2738f9dd2c91069b0 |
| 09-carica_dati_meteo_1.6.pl | a317ca36e9d1455a1f0ba8380386894530cafce12427ccc352708ae6b6e406ca |
| 10-correggi_quote_1.0+lipo.pl | c95ba1251c2f6e6af4af09da64436498e7efddab1d2ccb58b2f6690a886cc62a |
| 10-correggi_quote_1.0.pl | 837133c56bba167fe7e405b9765f38945467ae2569643f67c2601d1087f169f8 |
| 12-carica_acustici_cmp_0.1.pl | 69d8fcdd281297dbcf4d6c0c1fe11540ee6b9aeb72e4c236c8b773a841084c60 |
| 14-correla_eventi_cmp_0.63.pl | e12335da0c7a8a8f7e07668ba4666c5a854de3ebf0af5dd21797ee850892765c |
| 14-correla_eventi_cmp_0.64_Lvan.pl | 6e067414a3e791da7840b7cde13567cf9549b5e9be930d34063b4d6616a00859 |
| 14-correla_eventi_cmp_0.64_LVA_Lvan.pl | afec11c048c61df6ef58a6ba86485f2513eccb2d7510dba62df9cd46def99f65 |
| 15-calcolo_Lva_corr_DBedENAV.pl | 9a69f7a60c93fa991716755bea27a5ba96f4f4b1f4db04158ef360cb1f565945 |
| 16-calcolo_LAeq_aeroportuale_ev_correlati.pl | 81b3e8d7ad5fb27de653bb60045d56ca2b5bb000adadf6b0ee6e611ad3f4398c |
| 16-calcolo_LAeq_aeroportuale_ev_correlati_night.pl | 4148c209a5b7aee24707fe68c5b10adceb100155952def9ad8815ec89ae68f30 |
| 18-validazione_0.1.pl | 46bf156790e6be4d8ec568a22392453ab642ac96b1636fcf9c7b06b79cd689a5 |
| 20-tracks_2_gis_0.0.1_sperimentale.pl | aaf37008dde6b63f24ace30c1f0016d413f3949138a5d833f138ecfcf5133207 |
| calcolo_Lva_correl_manuali.pl | 5dcd58f71786b958380d688850b2fd01123216571ec56815409334247ba83bd8 |
| Densita_ModuloDensita.pl | 997dca6d5c38ba02a955416560f6d617b41b82cac5e4459a25839347e5c26d4e |
| Densita_ModuloDensita_1.0.pl | 38bf44a541d6386c7f42fc27fd765b0ba17928e028f54e5515420355c5aef692 |
| OpAeree_ModuloAeroportulae_1.0.pl | 9cd18924d093b1140c20369ef31917f5298844b987ded3893d8577163b370570 |
| prova.pl | 5aed223379f0a6bc29b2b072af9bd05f0cfc70e789e19beb0f339f4030fb15a6 |
