package ScriptManager::Exception;
use Mojo::Base -base, -signatures;

use Scalar::Util 'blessed';
use overload '""' => sub ($self, @) { $self->message }, fallback => 1;

# code: stable identifier; message: text safe to show to the user.
has [qw(code message)];

sub throw ($class, $code, $message) {
    die $class->new(code => $code, message => $message);
}

sub caught ($class, $err, $code = undef) {
    return 0 unless blessed($err) && $err->isa($class);
    return 1 unless defined $code;
    return $err->code eq $code;
}

1;
