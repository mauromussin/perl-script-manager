use Mojo::Base -strict;
use Test::More;
use Mojo::JSON 'false';
use Mojo::Parameters;
use ScriptManager::Validation::Parameters;

my $v = ScriptManager::Validation::Parameters->new(
    schema => {
        type                 => 'object',
        additionalProperties => false,
        required             => ['name'],
        properties           => {
            name   => {type => 'string', minLength => 1, 'x-order' => 1},
            count  => {type => 'integer', minimum => 1, maximum => 5, default => 2, 'x-order' => 2},
            flag   => {type => 'boolean', default => 1, 'x-order' => 3},
            secret => {type => 'string', 'x-sensitive' => 1},
            tags   => {type => 'array', items => {type => 'string'}},
        },
    }
);

is_deeply $v->properties, [qw(name count flag secret tags)], 'ordered properties';

subtest 'validate and coerce' => sub {
    my ($data, $errors) = $v->validate({name => 'x', count => '3'});
    is_deeply $errors, [], 'no errors';
    is $data->{count}, 3, 'number coerced';
    ok exists $data->{flag}, 'default applied';

    ($data, $errors) = $v->validate({count => 9});
    ok scalar @$errors >= 2, 'missing required and out of range';

    ($data, $errors) = $v->validate({name => 'x', extra => 1});
    ok scalar @$errors, 'unknown property rejected';
};

subtest 'from_form' => sub {
    my $params = Mojo::Parameters->new('name=abc&count=&tags=a&tags=b');
    my $data   = $v->from_form($params);
    is $data->{name}, 'abc';
    ok !exists $data->{count}, 'empty value skipped';
    ok !$data->{flag}, 'unchecked checkbox is false';
    is_deeply $data->{tags}, [qw(a b)];
};

subtest 'from_args' => sub {
    my $data = $v->from_args([qw(--name abc --count=4 --no-flag --tags a --tags b)]);
    is $data->{name}, 'abc';
    is $data->{count}, 4;
    ok !$data->{flag};
    is_deeply $data->{tags}, [qw(a b)];
    eval { $v->from_args(['--unknown', '1']) };
    like $@, qr/sconosciuto/;
    eval { $v->from_args(['--count']) };
    like $@, qr/mancante/;
    eval { $v->from_args(['abc']) };
    like $@, qr/non valido/;
};

subtest 'redact' => sub {
    ok $v->has_sensitive;
    is_deeply $v->redact({name => 'a', secret => 's'}), {name => 'a'};
};

done_testing;
