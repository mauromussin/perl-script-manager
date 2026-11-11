package ScriptManager::Service::ProcedureRegistry;
use Mojo::Base -base, -signatures;

use Mojo::Loader 'load_class';
use Mojo::JSON 'false';
use ScriptManager::Exception;
use ScriptManager::Validation::Parameters;
use YAML::PP;

# Path to the YAML catalog
has 'file';

sub load ($self) {
    my $doc = YAML::PP->new(boolean => 'JSON::PP')->load_file($self->file->to_string);
    my (%by_code, @list);
    for my $p (@{$doc->{procedures} // []}) {
        $self->_check($p);
        $p->{parameter_schema}{type}                 //= 'object';
        $p->{parameter_schema}{additionalProperties} //= false;
        $p->{enabled}     = (exists $p->{enabled} ? $p->{enabled} : 1) ? 1 : 0;
        $p->{description} //= '';
        die "Procedura duplicata: $p->{code}\n" if $by_code{$p->{code}};
        $by_code{$p->{code}} = $p;
        push @list, $p;
    }
    $self->{by_code} = \%by_code;
    $self->{list}    = \@list;
    return $self;
}

sub all     ($self) { return [@{$self->{list}}] }
sub enabled ($self) { return [grep { $_->{enabled} } @{$self->{list}}] }

sub get ($self, $code) {
    return undef unless defined $code;
    my $p = $self->{by_code}{$code} or return undef;
    return $p->{enabled} ? $p : undef;
}

sub validator ($self, $procedure) {
    return ScriptManager::Validation::Parameters->new(schema => $procedure->{parameter_schema});
}

sub _check ($self, $p) {
    my $code = $p->{code} // '';
    die "Codice procedura non valido: '$code'\n" unless $code =~ /\A[a-z][a-z0-9_]{1,63}\z/;
    for my $key (qw(name handler_class execution_mode timeout_seconds)) {
        die "Procedura $code: campo '$key' mancante\n" unless defined $p->{$key} && length $p->{$key};
    }
    die "Procedura $code: execution_mode deve essere sync o async\n"
        unless $p->{execution_mode} =~ /\A(?:sync|async)\z/;
    die "Procedura $code: timeout_seconds non valido\n" unless $p->{timeout_seconds} =~ /\A[1-9]\d*\z/;
    die "Procedura $code: handler_class fuori da ScriptManager::Command::\n"
        unless $p->{handler_class} =~ /\AScriptManager::Command::\w+(?:::\w+)*\z/;
    if (my $e = load_class $p->{handler_class}) {
        die "Procedura $code: impossibile caricare $p->{handler_class}: $e\n" if ref $e;
        die "Procedura $code: modulo $p->{handler_class} non trovato\n";
    }
    die "Procedura $code: il handler non implementa run()\n" unless $p->{handler_class}->can('run');
    my $v = ScriptManager::Validation::Parameters->new(schema => $p->{parameter_schema} //= {});
    die "Procedura $code: parametri x-sensitive richiedono execution_mode sync\n"
        if $v->has_sensitive && $p->{execution_mode} ne 'sync';
    return;
}

1;
