package Zonemaster::Backend::RPCAPI;

use strict;
use warnings;
use 5.14.2;

# Public Modules
use JSON::PP;
use DBI qw(:utils);
use Digest::MD5 qw(md5_hex);
use String::ShellQuote;
use File::Slurp qw(append_file);
use HTML::Entities;
use JSON::Validator::Joi;

# Zonemaster Modules
use Zonemaster::LDNS;
use Zonemaster::Engine;
use Zonemaster::Engine::DNSName;
use Zonemaster::Engine::Logger::Entry;
use Zonemaster::Engine::Nameserver;
use Zonemaster::Engine::Net::IP;
use Zonemaster::Engine::Recursor;
use Zonemaster::Backend;
use Zonemaster::Backend::Config;
use Zonemaster::Backend::ErrorMessages;
use Zonemaster::Backend::Translator;
use Zonemaster::Backend::Validator;
use Locale::TextDomain qw[Zonemaster-Backend];
use Locale::Messages qw[setlocale LC_MESSAGES];
use Encode;

#use Locale::Messages::Debug qw[debug_gettext];

my $zm_validator = Zonemaster::Backend::Validator->new;
my %json_schemas;
my %extra_validators;
my $recursor = Zonemaster::Engine::Recursor->new;

sub joi {
    return JSON::Validator::Joi->new;
}

sub new {
    my ( $type, $params ) = @_;

    my $self = {};
    bless( $self, $type );

    if ( ! $params || ! $params->{config} ) {
        handle_exception('new', "Missing 'config' parameter", '001');
    }

    $self->{config} = $params->{config};

    my $dbtype;
    if ( $params->{dbtype} ) {
        $dbtype = $self->{config}->check_db($params->{dbtype});
    } else {
        $dbtype = $self->{config}->DB_engine;
    }

    $self->_init_db($dbtype);

    return ( $self );
}

sub _init_db {
    my ( $self, $dbtype ) = @_;

    eval {
        my $backend_module = "Zonemaster::Backend::DB::" . $dbtype;
        eval "require $backend_module";
        die "$@ \n" if $@;
        $self->{db} = $backend_module->new( { config => $self->{config} } );
    };
    if ($@) {
        handle_exception('_init_db', "Failed to initialize the [$dbtype] database backend module: [$@]", '002');
    }
}

sub handle_exception {
    my ( $method, $exception, $exception_id ) = @_;

    $exception =~ s/\n/ /g;
    $exception =~ s/^\s+|\s+$//g;
    warn "Internal error $exception_id: Unexpected error in the $method API call: [$exception] \n";
    die "Internal error $exception_id \n";
}

$json_schemas{version_info} = joi->object->strict;
sub version_info {
    my ( $self ) = @_;

    my %ver;
    eval {
        $ver{zonemaster_engine} = Zonemaster::Engine->VERSION;
        $ver{zonemaster_backend} = Zonemaster::Backend->VERSION;

    };
    if ($@) {
        handle_exception('version_info', $@, '003');
    }

    return \%ver;
}

$json_schemas{profile_names} = joi->object->strict;
sub profile_names {
    my ( $self ) = @_;

    my @profiles;
    eval {
        @profiles = $self->{config}->ListPublicProfiles();

    };
    if ($@) {
        handle_exception('profile_names', $@, '004');
    }

    return \@profiles;
}

# Return the list of language tags supported by get_test_results(). The tags are
# derived from the locale tags set in the configuration file.
$json_schemas{get_language_tags} = joi->object->strict;
sub get_language_tags {
    my ( $self ) = @_;

    my @lang = $self->{config}->ListLanguageTags();

    return \@lang;
}

$json_schemas{get_host_by_name} = joi->object->strict->props(
    hostname   => $zm_validator->domain_name->required
);
sub get_host_by_name {
    my ( $self, $params ) = @_;
    my @adresses;

    eval {
        my $ns_name  = $params->{hostname};

        @adresses = map { {$ns_name => $_->short} } $recursor->get_addresses_for($ns_name);
        @adresses = { $ns_name => '0.0.0.0' } if not @adresses;

    };
    if ($@) {
        handle_exception('get_host_by_name', $@, '005');
    }

    return \@adresses;
}

$json_schemas{get_data_from_parent_zone} = joi->object->strict->props(
    domain   => $zm_validator->domain_name->required
);
sub get_data_from_parent_zone {
    my ( $self, $params ) = @_;

    my $result = eval {
        my %result;

        my $domain = $params->{domain};

        my ( $dn, $dn_syntax ) = $self->_check_domain( $domain );
        return $dn_syntax if ( $dn_syntax->{status} eq 'nok' );

        my @ns_list;
        my @ns_names;

        my $zone = Zonemaster::Engine->zone( $domain );
        push @ns_list, { ns => $_->name->string, ip => $_->address->short} for @{$zone->glue};

        my @ds_list;

        $zone = Zonemaster::Engine->zone($domain);
        my $ds_p = $zone->parent->query_one( $zone->name, 'DS', { dnssec => 1, cd => 1, recurse => 1 } );
        if ($ds_p) {
            my @ds = $ds_p->get_records( 'DS', 'answer' );

            foreach my $ds ( @ds ) {
                next unless $ds->type eq 'DS';
                push(@ds_list, { keytag => $ds->keytag, algorithm => $ds->algorithm, digtype => $ds->digtype, digest => $ds->hexdigest });
            }
        }

        $result{ns_list} = \@ns_list;
        $result{ds_list} = \@ds_list;
        return \%result;
    };
    if ($@) {
        handle_exception('get_data_from_parent_zone', $@, '006');
    }
    elsif ($result) {
        return $result;
    }
}


sub _check_domain {
    my ( $self, $domain ) = @_;

    if ( !defined( $domain ) ) {
        return ( $domain, { status => 'nok', message => N__ 'Domain name required' } );
    }

    if ( $domain =~ m/[^[:ascii:]]+/ ) {
        if ( Zonemaster::LDNS::has_idn() ) {
            eval { $domain = Zonemaster::LDNS::to_idn( $domain ); };
            if ( $@ ) {
                return (
                    $domain,
                    {
                        status  => 'nok',
                        message => N__ 'The domain name is not a valid IDNA string and cannot be converted to an A-label'
                    }
                );
            }
        }
        else {
            return (
                $domain,
                {
                    status  => 'nok',
                    message => N__ 'The domain name contains non-ascii characters and IDNA is not installed'
                }
            );
        }
    }

    if ( $domain !~ m/^[\-a-zA-Z0-9\.\_]+$/ ) {
        return (
            $domain,
            {
                status  => 'nok',
                message => N__ 'The domain name character(s) are not supported'
            }
        );
    }

    my %levels = Zonemaster::Engine::Logger::Entry::levels();
    my @res;
    @res = Zonemaster::Engine::Test::Basic->basic00( $domain );
    @res = grep { $_->numeric_level >= $levels{ERROR} } @res;
    if ( @res != 0 ) {
        return ( $domain, { status => 'nok', message => N__ 'The domain name or label is too long' } );
    }

    return ( $domain, { status => 'ok', message => 'Syntax ok' } );
}

sub validate_syntax {
    my ( $self, $syntax_input ) = @_;

    my $result = eval {
        my @errors;

        if ( defined $syntax_input->{profile} ) {
            my @profiles = map lc, $self->{config}->ListPublicProfiles();
            push @errors, { path => '/profile', message => N__ 'Unknown profile' }
            unless ( grep { $_ eq lc $syntax_input->{profile} } @profiles );
        }

        if ( defined $syntax_input->{domain} ) {
            my ( undef, $dn_syntax ) = $self->_check_domain( $syntax_input->{domain} );
            push @errors, { path => "/domain", message => $dn_syntax->{message} } if ( $dn_syntax->{status} eq 'nok' );
        }

        if ( defined $syntax_input->{nameservers} && ref $syntax_input->{nameservers} eq 'ARRAY' && @{ $syntax_input->{nameservers} } ) {
            while (my ($index, $ns_ip) = each @{ $syntax_input->{nameservers} }) {
                my ( $ns, $ns_syntax ) = $self->_check_domain( $ns_ip->{ns} );
                push @errors, { path => "/nameservers/$index/ns", message => $ns_syntax->{message} } if ( $ns_syntax->{status} eq 'nok' );

                push @errors, { path => "/nameservers/$index/ip", message => N__ 'Invalid IP address' }
                unless ( !$ns_ip->{ip}
                    || Zonemaster::Engine::Net::IP::ip_is_ipv4( $ns_ip->{ip} )
                    || Zonemaster::Engine::Net::IP::ip_is_ipv6( $ns_ip->{ip} ) );
            }
        }

        if (@errors) {
            return {
                status => 'nok',
                errors => \@errors,
                message => 'Syntax validation error'
            };
        }
    };
    if ($@) {
        handle_exception('validate_syntax', $@, '008');
    }
    elsif ($result) {
        return $result;
    }
    else {
        return { status => 'ok', message =>  encode_entities( 'Syntax ok' ) };
    }
}

$json_schemas{start_domain_test} = joi->object->strict->props(
    domain => $zm_validator->domain_name->required,
    ipv4 => joi->boolean,
    ipv6 => joi->boolean,
    nameservers => joi->array->items(
        # NOTE: Array items are not compiled automatically, so to enforce all properties we need to do it by hand
        $zm_validator->nameserver->compile
    ),
    ds_info => joi->array->items(
        $zm_validator->ds_info->compile
    ),
    profile => $zm_validator->profile_name,
    client_id => $zm_validator->client_id,
    client_version => $zm_validator->client_version,
    config => joi->string,
    priority => $zm_validator->priority,
    queue => $zm_validator->queue
);
$extra_validators{start_domain_test} = \&validate_syntax;
sub start_domain_test {
    my ( $self, $params ) = @_;

    my $result = 0;
    eval {
        $params->{domain} =~ s/^\.// unless ( !$params->{domain} || $params->{domain} eq '.' );

        die "No domain in parameters\n" unless ( $params->{domain} );

        if ($params->{config}) {
            $params->{config} =~ s/[^\w_]//isg;
            die "Unknown test configuration: [$params->{config}]\n" unless ( $self->{config}->GetCustomConfigParameter('ZONEMASTER', $params->{config}) );
        }

        $params->{priority}  //= 10;
        $params->{queue}     //= 0;

        $result = $self->{db}->create_new_test( $params->{domain}, $params, $self->{config}->ZONEMASTER_age_reuse_previous_test );
    };
    if ($@) {
        handle_exception('start_domain_test', $@, '009');
    }

    return $result;
}

$json_schemas{test_progress} = joi->object->strict->props(
    test_id => $zm_validator->test_id->required
);
sub test_progress {
    my ( $self, $params ) = @_;

    my $result = 0;
    eval {
        my $test_id = $params->{test_id};
        $result = $self->{db}->test_progress( $test_id );
    };
    if ($@) {
        handle_exception('test_progress', $@, '010');
    }

    return $result;
}

$json_schemas{get_test_params} = joi->object->strict->props(
    test_id => $zm_validator->test_id->required
);
sub get_test_params {
    my ( $self, $params ) = @_;

    my $test_id = $params->{test_id};

    my $result = 0;

    eval {
        $result = $self->{db}->get_test_params( $test_id );
    };
    if ($@) {
        handle_exception('get_test_params', $@, '011');
    }

    return $result;
}

$json_schemas{get_test_results} = joi->object->strict->props(
    id => $zm_validator->test_id->required,
    language => $zm_validator->language_tag->required
);
sub get_test_results {
    my ( $self, $params ) = @_;

    my $result;
    my $translator;
    $translator = Zonemaster::Backend::Translator->new;

    # Already validated by json_validate
    my $locale = $self->_get_locale($params);

    my $previous_locale = $translator->locale;
    $translator->locale( $locale );

    eval { $translator->data } if $translator;    # Provoke lazy loading of translation data

    my $test_info;
    my @zm_results;
    eval{
        $test_info = $self->{db}->test_results( $params->{id} );
        foreach my $test_res ( @{ $test_info->{results} } ) {
            my $res;
            if ( $test_res->{module} eq 'NAMESERVER' ) {
                $res->{ns} = ( $test_res->{args}->{ns} ) ? ( $test_res->{args}->{ns} ) : ( 'All' );
            }
            elsif ($test_res->{module} eq 'SYSTEM'
                && $test_res->{tag} eq 'POLICY_DISABLED'
                && $test_res->{args}->{name} eq 'Example' )
            {
                next;
            }

            $res->{module} = $test_res->{module};
            $res->{message} = $translator->translate_tag( $test_res, $params->{language} ) . "\n";
            $res->{message} =~ s/,/, /isg;
            $res->{message} =~ s/;/; /isg;
            $res->{level} = $test_res->{level};

            if ( $test_res->{module} eq 'SYSTEM' ) {
                if ( $res->{message} =~ /policy\.json/ ) {
                    my ( $policy ) = ( $res->{message} =~ /\s(\/.*)$/ );
                    if ( $policy ) {
                        my $policy_description = 'DEFAULT POLICY';
                        $policy_description = 'SOME OTHER POLICY' if ( $policy =~ /some\/other\/policy\/path/ );
                        $res->{message} =~ s/$policy/$policy_description/;
                    }
                    else {
                        $res->{message} = 'UNKNOWN POLICY FORMAT';
                    }
                }
                elsif ( $res->{message} =~ /config\.json/ ) {
                    my ( $config ) = ( $res->{message} =~ /\s(\/.*)$/ );
                    if ( $config ) {
                        my $config_description = 'DEFAULT CONFIGURATION';
                        $config_description = 'SOME OTHER CONFIGURATION' if ( $config =~ /some\/other\/configuration\/path/ );
                        $res->{message} =~ s/$config/$config_description/;
                    }
                    else {
                        $res->{message} = 'UNKNOWN CONFIG FORMAT';
                    }
                }
            }

            push( @zm_results, $res );
        }

        $result = $test_info;
        $result->{results} = \@zm_results;
    };
    if ($@) {
        handle_exception('get_test_results', $@, '012');
    }

    $translator->locale( $previous_locale );

    $result = $test_info;
    $result->{results} = \@zm_results;

    return $result;
}

$json_schemas{get_test_history} = joi->object->strict->props(
    offset => joi->integer->min(0),
    limit => joi->integer->min(0),
    filter => joi->string->regex('^(?:all|delegated|undelegated)$'),
    frontend_params => joi->object->strict->props(
        domain => $zm_validator->domain_name->required
    )->required
);
sub get_test_history {
    my ( $self, $params ) = @_;

    my $results;

    eval {
        $params->{offset} //= 0;
        $params->{limit} //= 200;
        $params->{filter} //= "all";

        $results = $self->{db}->get_test_history( $params );
    };
    if ($@) {
        handle_exception('get_test_history', $@, '013');
    }

    return $results;
}

$json_schemas{add_api_user} = joi->object->strict->props(
    username => $zm_validator->username->required,
    api_key => $zm_validator->api_key->required,
);
sub add_api_user {
    my ( $self, $params, undef, $remote_ip ) = @_;

    my $result = 0;

    eval {
        my $allow = 0;
        if ( defined $remote_ip ) {
            $allow = 1 if ( $remote_ip eq '::1' || $remote_ip eq '127.0.0.1' );
        }
        else {
            $allow = 1;
        }

        if ( $allow ) {
            $result = 1 if ( $self->{db}->add_api_user( $params->{username}, $params->{api_key} ) eq '1' );
        }
    };
    if ($@) {
        handle_exception('add_api_user', $@, '014');
    }

    return $result;
}

$json_schemas{add_batch_job} = joi->object->strict->props(
    username => $zm_validator->username->required,
    api_key => $zm_validator->api_key->required,
    domains => joi->array->strict->items(
        $zm_validator->domain_name->required
    )->required,
    test_params => joi->object->strict->props(
        ipv4 => joi->boolean,
        ipv6 => joi->boolean,
        nameservers => joi->array->strict->items(
            $zm_validator->nameserver
        ),
        ds_info => joi->array->strict->items(
            $zm_validator->ds_info
        ),
        profile => $zm_validator->profile_name,
        client_id => $zm_validator->client_id,
        client_version => $zm_validator->client_version,
        config => joi->string,
        priority => $zm_validator->priority,
        queue => $zm_validator->queue
    )
);
sub add_batch_job {
    my ( $self, $params ) = @_;

    $params->{test_params}->{priority}  //= 5;
    $params->{test_params}->{queue}     //= 0;

    my $results;
    eval {
        $results = $self->{db}->add_batch_job( $params );
    };
    if ($@) {
        handle_exception('add_batch_job', $@, '015');
    }

    return $results;
}

$json_schemas{get_batch_job_result} = joi->object->strict->props(
    batch_id => $zm_validator->batch_id->required
);
sub get_batch_job_result {
    my ( $self, $params ) = @_;

    my $result;

    eval {
        my $batch_id = $params->{batch_id};

        $result = $self->{db}->get_batch_job_result($batch_id);
    };
    if ($@) {
        handle_exception('get_batch_job_result', $@, '016');
    }

    return $result;
}

sub _get_locale {
    my ( $self, $params ) = @_;
    my @error;

    my %locale = $self->{config}->Language_Locale_hash();
    my $language = $params->{language};
    my $ret;

    if ( defined $language ) {
        if ( $locale{$language} ) {
            if ( $locale{$language} eq 'NOT-UNIQUE') {
                push @error, {
                    path => "/language",
                    message => N__ "Language string not unique"
                };
            } else {
                $ret = $locale{$language};
            }
        } else {
            push @error, {
                path => "/language",
                message => N__ "Unkown language string"
            };
        }
    }

    return $ret, \@error,
}

my $rpc_request = joi->object->props(
    jsonrpc => joi->string->required,
    method => $zm_validator->jsonrpc_method()->required);
sub jsonrpc_validate {
    my ( $self, $jsonrpc_request) = @_;

    my @error_rpc = $rpc_request->validate($jsonrpc_request);
    if (!exists $jsonrpc_request->{id} || @error_rpc) {
        return {
            jsonrpc => '2.0',
            id => undef,
            error => {
                code => '-32600',
                message => decode_utf8(__ 'The JSON sent is not a valid request object.'),
                data => "@error_rpc"
            }
        }
    }

    my $method_schema = $json_schemas{$jsonrpc_request->{method}};
    # the JSON schema for the method has a 'required' key
    if ( exists $method_schema->{required} ) {
        if ( not exists $jsonrpc_request->{params} ) {
            return {
                jsonrpc => '2.0',
                id => $jsonrpc_request->{id},
                error => {
                    code => '-32602',
                    message => decode_utf8(__ "Missing 'params' object"),
                }
            };
        }

        my @error_response;

        # NOTE: Make that configurable
        my $default_language =  'en_US';
        my ($locale, $locale_error) = $self->_get_locale( $jsonrpc_request->{params} );

        # NOTE: temporary workaround to not break everything
        if (exists $jsonrpc_request->{params}->{language} && !exists $method_schema->{properties}->{language}) {
            delete $jsonrpc_request->{params}->{language};
        }

        push @error_response, @{$locale_error};
        $locale //= $default_language;
        $ENV{LANGUAGE} = $locale;
        setlocale( LC_MESSAGES, $locale );

        my @json_validation_error = $method_schema->validate($jsonrpc_request->{params});

        my $error_config = Zonemaster::Backend::ErrorMessages::custom_messages_config;

        # Customize error message from json validation
        foreach my $err ( @json_validation_error ) {
            my $message = $err->message;
            foreach my $entry (@{$error_config}) {
                my $pattern = $entry->{pattern};
                my $config = $entry->{config};

                if ($err->{path} =~ /^$pattern$/) {
                    my @details = @{$err->details};
                    my $custom_message = $config->{@details[0]}->{@details[1]} if defined $config->{@details[0]};
                    if (defined $custom_message) {
                        $message = $custom_message;
                        last;
                    }
                }
            }
            push @error_response, { path => $err->path, message => $message };
        }

        # Add messages from extra validation function
        if ( $extra_validators{$jsonrpc_request->{method}} ) {
            my $sub_validator = $extra_validators{$jsonrpc_request->{method}};
            my $result = $self->$sub_validator($jsonrpc_request->{params});
            push @error_response, @{$result->{errors}} if $result->{status} eq 'nok';
        }

        # Translate messages
        @error_response = map { { %$_,  ( message => decode_utf8 __ $_->{message} ) } } @error_response;

        if ( @error_response ) {
            return {
                jsonrpc => '2.0',
                id => $jsonrpc_request->{id},
                error => {
                    code => '-32602',
                    message => decode_utf8(__ 'Invalid method parameter(s).'),
                    data => \@error_response
                }
            };
        }
    }

    return '';
}
1;
