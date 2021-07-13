package Zonemaster::Backend::ErrorMessages;


use Readonly;
use Locale::TextDomain qw[Zonemaster-Backend];

# This structure is used to replace messages coming from JSON::Validator
# The items are evaluated in order and the first item that have its `pattern`
#  key matching the current path will be used.
# The `config` key holds the custom messages, the keys of the first level hash
#  represent the types of the JSON element and the ones of the second level
#  hash are the types of error.
# This structure is similar to the one used internally in JSON::Validator,
#  see https://github.com/jhthorsen/json-validator/blob/master/lib/JSON/Validator/Error.pm

Readonly my @CUSTOM_MESSAGES_CONFIG => (
    {
        pattern => "/(domain|hostname)",
        config => {
            string => {
                pattern => N__ 'The domain name character(s) are not supported'
            }
        }
    },
    {
        pattern => "/nameservers/\\d+/ip",
        config => {
            string => {
                pattern => N__ 'Invalid IP address'
            }
        }
    },
    {
        pattern => "/nameservers/\\d+/ns",
        config => {
            string => {
                pattern => N__ 'The domain name character(s) are not supported'
            }
        }
    },
    {
        pattern => "/ds_info/\\d+/keytag",
        config => {
            integer => {
                type => N__ 'Keytag should be a positive integer',
                minimum => N__ 'Keytag should be a positive integer'
            }
        }
    },
    {
        pattern => "/ds_info/\\d+/algorithm",
        config => {
            integer => {
                type => N__ 'Algorithm should be a positive integer',
                minimum => N__ 'Algorithm should be a positive integer'
            }
        }
    },
    {
        pattern => "/ds_info/\\d+/digtype",
        config => {
            integer => {
                type => N__ 'Digest type should be a positive integer',
                minimum => N__ 'Digest type should be a positive integer'
            }
        }
    },
    {
        pattern => "/ds_info/\\d+/digest",
        config => {
            string => {
                pattern => N__ 'Invalid digest format'
            }
        }
    },
    {
        pattern => "/language",
        config => {
            string => {
                pattern => N__ 'Invalid language tag format'
            }
        }
    },
    {
        # This item will catch all paths, used for common errors
        pattern => ".*",
        config => {
            object => {
                required => N__ 'Missing property'
            }
        }
    }
);

sub custom_messages_config {
    return \@CUSTOM_MESSAGES_CONFIG;
}
