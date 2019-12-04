# Configuration

Zonemaster *Backend* is configured as a whole from `/etc/zonemaster/backend_config.ini`
(CentOS, Debian and Ubuntu) or `/usr/local/etc/zonemaster/backend_config.ini`
(FreeBSD).

Each section in `backend_config.ini` is documented below.

## DB section

TBD


## GEOLOCATION section

TBD


## LOG section

TBD


## PERL section

TBD


## PUBLIC PROFILES and PRIVATE PROFILES sections

The PUBLIC PROFILES and PRIVATE PROFILES sections together define the available [profiles].

Keys in both sections are [profile names], and values are absolute file system paths to
[profile JSON files]. Keys must not be duplicated between the sections, and the
key `default` must not be present in the PRIVATE PROFILES sections.

Each profile JSON file contains a (possibly empty) set of overrides to
the [Zonemaster Engine default profile].

There is a `default` profile that is special.
It is always available.
If it is not explicitly mapped to a profile JSON file, it is implicitly
mapped to the Zonemaster Engine default profile.

Specifying a profile JSON file that contains a complete set of profile
data is equivalent to specifying a profile JSON file with only the parts
that differ from the Zonemaster Engine default profile.
Specifying a profile JSON file that contains no profile data is equivalent
to specifying a profile JSON file containing the entire Zonemaster Engine
default profile.

## ZONEMASTER section

TBD

--------

[Profile JSON files]: https://metacpan.org/pod/Zonemaster::Backend::Config
[Profile names]: API.md#profile-name
[Profiles]: Architecture.md#profile
[Zonemaster Engine default profile]: https://metacpan.org/pod/Zonemaster::Backend::Config
