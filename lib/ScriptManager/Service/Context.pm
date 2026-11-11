package ScriptManager::Service::Context;
use Mojo::Base -base, -signatures;

use Digest::SHA;
use Mojo::File 'path';
use Mojolicious::Types;
use ScriptManager::Exception;

# Execution context passed to every command: logging, progress, cancellation and output files.
has [qw(execution_id repo output_root logger retention_days)];
has types => sub { Mojolicious::Types->new };

sub output_dir ($self) {
    return $self->{output_dir} //= path($self->output_root, $self->execution_id)->make_path;
}

sub log ($self, $level, $message, %meta) {
    $message = substr($message, 0, 4000) if length $message > 4000;
    $self->repo->add_event($self->execution_id, $level, $message, metadata => \%meta);
    my $method = $level eq 'warning' ? 'warn' : $level;
    $self->logger->$method(sprintf '[exec=%s] %s', $self->execution_id, $message);
    return $self;
}

sub progress ($self, $percent, $step = undef) {
    $self->repo->update_progress($self->execution_id, $percent, $step);
    return $self;
}

sub is_cancelled ($self) {
    return ($self->repo->status($self->execution_id) // '') eq 'cancel_requested';
}

sub check_cancel ($self) {
    ScriptManager::Exception->throw('cancelled', 'Esecuzione annullata') if $self->is_cancelled;
    return;
}

# Writes bytes to a new file in the execution output directory and registers it as an artifact.
sub write_artifact ($self, $name, $content, %o) {
    ScriptManager::Exception->throw('invalid_artifact_name', 'Nome file non valido')
        unless defined $name && $name =~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/ && $name !~ /\.\./;
    my $file = $self->output_dir->child($name);
    ScriptManager::Exception->throw('artifact_exists', 'File già presente') if -e $file;
    $file->spew($content);

    my ($ext) = $name =~ /\.([^.]+)\z/;
    my $type = $o{media_type} // (defined $ext ? $self->types->type(lc $ext) : undef) // 'application/octet-stream';
    return $self->repo->add_artifact(
        $self->execution_id,
        original_name  => $name,
        stored_name    => $name,
        media_type     => $type,
        size_bytes     => -s $file,
        sha256         => Digest::SHA->new(256)->addfile("$file")->hexdigest,
        relative_path  => join('/', $self->execution_id, $name),
        retention_days => $o{retention_days} // $self->retention_days,
    );
}

1;
