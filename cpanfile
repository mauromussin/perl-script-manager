requires 'perl', '5.036';

requires 'DBD::Pg';
requires 'IPC::Run';
requires 'JSON::Validator', '>= 5.14';
requires 'Log::Any';
requires 'Minion',          '>= 10.25';
requires 'Mojo::Pg',        '>= 4.27';
requires 'Mojolicious',     '>= 9.34';
requires 'YAML::PP';

on 'test' => sub {
    requires 'Test::More';
    requires 'Test2::V0';
};

on 'develop' => sub {
    requires 'Perl::Critic';
    requires 'Perl::Tidy';
};
