use strict;
use warnings;
use 5.14.2;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;

use Zonemaster::Engine;
use JSON::PP;
use File::ShareDir qw[dist_file];
use File::Temp qw[tempdir];

use Zonemaster::Backend::Config;
use Zonemaster::Backend::RPCAPI;

my $TIME = CORE::time();

sub advance_time {
    my ( $delta ) = @_;
    $TIME += $delta;
}

BEGIN {
    *CORE::GLOBAL::time = sub { $TIME };
}

my $db_backend = Zonemaster::Backend::Config->check_db( $ENV{TARGET} || 'SQLite' );
diag "database: $db_backend";

my $tempdir = tempdir( CLEANUP => 1 );
my $config = Zonemaster::Backend::Config->parse( <<EOF );
[DB]
engine = $db_backend

[MYSQL]
host     = localhost
user     = travis_zm
password = travis_zonemaster
database = travis_zonemaster

[POSTGRESQL]
host     = localhost
user     = travis_zonemaster
password = travis_zonemaster
database = travis_zonemaster

[SQLITE]
database_file = $tempdir/zonemaster.sqlite

[ZONEMASTER]
age_reuse_previous_test = 10
EOF

subtest 'Everything but Test::NoWarnings' => sub {

    my $rpcapi = Zonemaster::Backend::RPCAPI->new(
        {
            dbtype => $db_backend,
            config => $config,
        }
    );

    if ( $db_backend eq 'SQLite' ) {
        $rpcapi->{db}->create_db()
          or BAIL_OUT( "$db_backend database could not be created" );
    }

    subtest 'start_domain_test' => sub {
        my $result1 = $rpcapi->start_domain_test( { domain => "zone1.rpcapi.example" } );
        advance_time( 10 );
        my $result2 = $rpcapi->start_domain_test( { domain => "zone1.rpcapi.example" } );
        advance_time( 1 );
        my $result3 = $rpcapi->start_domain_test( { domain => "zone1.rpcapi.example" } );

        is ref $result1, '', 'start_domain_test returns "result" scalar';
        is $result1,   $result2, 'old testid is reused before it expires';
        isnt $result2, $result3, 'a new testid is generated after the old one expires';
    };
};
