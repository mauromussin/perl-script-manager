use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use Mojo::File 'path';
use Mojo::JSON qw(true false);
use Mojo::Parameters;
use ScriptManager::Service::ValidationWindow;
use ScriptManager::Service::ProcedureRegistry;

subtest 'date reali, estremi inclusi e intervallo facoltativo' => sub {
    for my $params ({}, {date_from => '2024-02-29', date_to => '2024-02-29'},
        {date_from => '2026-01-01', date_to => '2026-12-31'}) {
        ok eval { ScriptManager::Service::ValidationWindow->validate_params($params); 1 }, 'intervallo valido';
    }
    for my $params ({date_from => '2026-01-01'}, {date_to => '2026-01-01'},
        {date_from => '2026-02-30', date_to => '2026-03-01'},
        {date_from => '2026-11-02', date_to => '2026-11-01'},
        {date_from => '2026-1-01', date_to => '2026-11-01'}) {
        eval { ScriptManager::Service::ValidationWindow->validate_params($params) };
        ok(ScriptManager::Exception->caught($@, 'invalid_date_range'), 'intervallo non valido rifiutato');
    }
};

subtest 'controlli web API e CLI condivisi dai comandi di validazione' => sub {
    my $root = path($FindBin::Bin, '..', '..')->realpath;
    local $ENV{MRT_CONFIG_FILE} = $root->child('config', 'MRT.example.json')->to_string;
    my $registry = ScriptManager::Service::ProcedureRegistry->new(file => $root->child('config', 'procedures.yml'))->load;
    for my $code (qw(valida_tracce valida_battute trova_pista_atterraggi trova_pista_decolli assegna_sid rettifica_quote correggi_quote)) {
        my $validator = $registry->validator($registry->get($code));
        my $input = {database => 'radar_test', airport => 'LIME'};
        delete $input->{airport} if $code eq 'valida_battute' || $code eq 'rettifica_quote';
        my ($params, $errors) = $validator->validate($input);
        is_deeply $errors, [], "$code senza date";
        ok !$params->{overwrite}, 'sovrascrittura disabilitata per default';
        my $form = $validator->from_form(Mojo::Parameters->new(date_from => '', date_to => ''));
        ok !exists $form->{date_from} && !exists $form->{date_to} && !$form->{overwrite},
            'form vuoto significa tutti i giorni senza sovrascrittura';
        my $args = $validator->from_args([qw(--date-from 2026-11-01 --date-to 2026-11-02 --overwrite)]);
        ($params, $errors) = $validator->validate({%$input, %$args});
        is_deeply $errors, [], 'date e checkbox accettati';
        ok $params->{overwrite}, 'flag CLI tipizzato';
        (undef, $errors) = $validator->validate({%$input, date_from => '2026-11-01'});
        ok @$errors, 'una sola data rifiutata dallo schema';
    }
};

{
    package WindowRepository;
    use Mojo::Base -base, -signatures;
    has completed => sub { ['2026-11-01'] };
    has invalidated => sub { [] };
    has recorded => sub { [] };
    sub lock_validation_target ($self, $target) { return {target => $target} }
    sub completed_validation_days ($self, @args) { return $self->completed }
    sub invalidate_validation_days ($self, @args) { push @{$self->invalidated}, \@args }
    sub complete_validation_days ($self, @args) { push @{$self->recorded}, \@args }
}
{
    package WindowContext;
    use Mojo::Base -base, -signatures;
    has repo => sub { WindowRepository->new };
    has [qw(validation_guard execution_id)];
    has events => sub { [] };
    sub check_cancel ($self) { }
    sub log ($self, @args) { push @{$self->events}, \@args }
}
{
    package WindowDatabase;
    use Mojo::Base -base, -signatures;
    has queries => sub { [] };
    sub selectrow_array ($self, $sql, @bind) {
        push @{$self->queries}, [$sql, @bind];
        return 2;
    }
    sub selectcol_arrayref ($self, $sql, @bind) {
        push @{$self->queries}, [$sql, @bind];
        return [] if $sql =~ /HAVING/;
        return ['2026-11-01', '2026-11-02'];
    }
    sub do ($self, $sql, @bind) { push @{$self->queries}, [$sql, @bind]; return 1 }
}

subtest 'skip giornaliero, filtro e invalidazione delle sole dipendenze' => sub {
    local $ENV{MYSQL_HOST} = 'mysql.test';
    local $ENV{MYSQL_PORT} = 3306;
    for my $stage (3 .. 8, 10) {
        for my $overwrite (false, true) {
            my $ctx = WindowContext->new;
            my $db = WindowDatabase->new;
            my $scope = ScriptManager::Service::ValidationWindow->new(db => $db, ctx => $ctx, stage => $stage,
                params => {database => 'radar_test', date_from => '2026-11-01', date_to => '2026-11-02',
                    overwrite => $overwrite})->prepare;
            is_deeply $scope->days, $overwrite ? ['2026-11-01', '2026-11-02'] : ['2026-11-02'],
                "fase $stage: giorni gia completati inclusi solo in sovrascrittura";
            my ($sql, @bind) = $scope->filter('f');
            like $sql, $stage == 7 || $stage == 10 ? qr/DATE\(f.data_ora_arr\) IN \(/ : qr/DATE\(f.data_ora_italy\) IN \(/,
                'campo data coerente con la fase';
            is $bind[0], $overwrite ? '2026-11-01' : '2026-11-02', 'date tramite placeholder';
            ok !grep({ $_->[0] =~ /^(UPDATE|DELETE)/ } @{$db->queries}), 'prepare non modifica dati';
            $scope->start_saving;
            my $invalidated = $ctx->repo->invalidated->[0];
            is_deeply $invalidated->[2], $scope->days, 'invalida solo i giorni elaborati';
            is_deeply $invalidated->[1], $stage == 3
                ? [qw(valida_tracce valida_battute trova_pista_atterraggi trova_pista_decolli)]
                : $stage == 4 ? [qw(valida_battute trova_pista_atterraggi trova_pista_decolli)]
                : [$stage == 5 ? 'trova_pista_atterraggi' : $stage == 6 ? 'trova_pista_decolli'
                    : $stage == 7 ? 'assegna_sid' : $stage == 8 ? 'rettifica_quote' : 'correggi_quote'],
                '05 e 06 sono indipendenti, entrambi dipendono da 04';
            if ($stage == 3 || $stage == 4 || $stage == 6) {
                is_deeply $ctx->repo->invalidated->[2][1], ['assegna_sid'], 'invalida anche SID con date dedicate';
            }
            if ($stage <= 6) {
                is_deeply $ctx->repo->invalidated->[1][1], ['rettifica_quote'], 'invalida anche 08 sulle date locali';
            }
            unlike $sql, qr/flay_operation/, '08 include arrivi e decolli' if $stage == 8;
            if ($stage <= 6 || $stage == 8) {
                ok grep({ $_->[1][0] eq 'correggi_quote' } @{$ctx->repo->invalidated}),
                    'upstream invalida anche 10 sulle date effettive';
            }
            is scalar @{$ctx->repo->recorded}, 0, 'non registra successo prima del completamento';
            my $result = $scope->finish({success => 1, data => {}, message => 'OK'});
            is_deeply $result->{data}{days_skipped}, $overwrite ? [] : ['2026-11-01'], 'skip nel risultato';
            ok grep({ $_->[1] =~ /2 tracce senza/ } @{$ctx->events}), 'segnala tracce senza data';
        }
    }
    my $scope = ScriptManager::Service::ValidationWindow->new;
    is_deeply [$scope->filter], [' AND 1 = 0'], 'nessun giorno non diventa intero database';
};

subtest '10 non registra completi i giorni con tracce saltate' => sub {
    local $ENV{MYSQL_HOST} = 'mysql.test';
    my $ctx = WindowContext->new;
    my $scope = ScriptManager::Service::ValidationWindow->new(db => WindowDatabase->new, ctx => $ctx, stage => 10,
        params => {database => 'radar_test', overwrite => true})->prepare;
    $scope->finish({message => 'OK', data => {incomplete_days => ['2026-11-02']}});
    is_deeply $ctx->repo->recorded->[0][2], ['2026-11-01'];
};

done_testing;
