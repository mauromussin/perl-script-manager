package ScriptManager::Validation::Parameters;
use Mojo::Base -base, -signatures;

use JSON::Validator;
use Mojo::JSON qw(false true);

# JSON Schema (object) describing the procedure parameters
has 'schema';

sub properties ($self) {
    my $props = $self->schema->{properties} // {};
    return [sort { ($props->{$a}{'x-order'} // 1000) <=> ($props->{$b}{'x-order'} // 1000) || $a cmp $b }
            keys %$props];
}

# Converts submitted form values (Mojo::Parameters) into typed data.
sub from_form ($self, $params) {
    my $props = $self->schema->{properties} // {};
    my %data;
    for my $name (keys %$props) {
        my $p    = $props->{$name};
        my $type = $p->{type} // 'string';
        if ($type eq 'boolean') {
            $data{$name} = $params->param($name) ? true : false;
        }
        elsif ($type eq 'array') {
            my @values = grep { length } @{$params->every_param($name)};
            $data{$name} = \@values if @values;
        }
        else {
            my $value = $params->param($name);
            next unless defined $value && length $value;
            $value .= ':00Z' if ($p->{format} // '') eq 'date-time' && $value =~ /\A\d{4}-\d\d-\d\dT\d\d:\d\d\z/;
            $data{$name} = $value;
        }
    }
    return \%data;
}

# Converts CLI arguments (--name value, --name=value, --flag, --no-flag) into data.
sub from_args ($self, $args) {
    my $props = $self->schema->{properties} // {};
    my (%data, @rest);
    @rest = @$args;
    while (@rest) {
        my $arg = shift @rest;
        die "Argomento non valido: $arg\n" unless $arg =~ /\A--(no-)?([A-Za-z0-9_-]+?)(?:=(.*))?\z/s;
        my ($negated, $name, $value) = ($1, $2, $3);
        $name =~ tr/-/_/;
        my $p = $props->{$name} // die "Parametro sconosciuto: $name\n";
        my $type = $p->{type} // 'string';
        if ($type eq 'boolean') {
            $data{$name} = defined $value ? ($value =~ /\A(?:1|true|yes|on)\z/i ? true : false) : $negated ? false : true;
            next;
        }
        die "--no-$name è ammesso solo per i parametri booleani\n" if $negated;
        $value //= shift @rest;
        die "Valore mancante per --$name\n" unless defined $value;
        if ($type eq 'array') { push @{$data{$name}}, $value }
        else                  { $data{$name} = $value }
    }
    return \%data;
}

# Returns ($coerced_data, \@errors); errors are hashes with path and message.
sub validate ($self, $data) {
    my $validator = JSON::Validator->new->coerce('booleans,numbers,defaults');
    $validator->schema($self->schema);
    my %copy   = %{$data // {}};
    my @errors = $validator->validate(\%copy);
    return (\%copy, [map { {path => $_->path, message => $_->message} } @errors]);
}

# Copy of the data without parameters flagged "x-sensitive".
sub redact ($self, $data) {
    my $props = $self->schema->{properties} // {};
    return {map { $_ => $data->{$_} } grep { !$props->{$_}{'x-sensitive'} } keys %$data};
}

sub has_sensitive ($self) {
    my $props = $self->schema->{properties} // {};
    return scalar grep { $props->{$_}{'x-sensitive'} } keys %$props;
}

1;
