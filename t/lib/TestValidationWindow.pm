package TestValidationWindow;
use Mojo::Base -base, -signatures;

# Existing algorithm tests isolate the date/history orchestration.
sub prepare ($self) { return $self }
sub filter ($self, @args) { return ('') }
sub overwrite ($self) { return 0 }
sub start_saving ($self) { }
sub finish ($self, $result) { return $result }

1;
