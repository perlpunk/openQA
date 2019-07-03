# Copyright (C) 2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License

package OpenQA::Settings;

use strict;
use warnings;

# replace %NAME% with $settings{NAME}
sub expand_placeholders {
    my ($settings) = @_;

    for my $value (sort values %$settings) {
        next unless defined $value;
        my %seen;
        eval {
            $value =~ s/%(\w+)%/expand_placeholder($settings, $1, \%seen)/ge;
        };
        if ($@) {
            return "Error: $@";
        }
    }
    return undef;
}

sub expand_placeholder {
    my ($settings, $key, $global_seen) = @_;

    unless (exists $settings->{ $key }) {
        return '';
    }
    my %seen = %$global_seen;
    # prevent circular replacement
    if ($seen{ $key }++) {
        die sprintf "The key %s contains a circular reference, its value is %s\n",
            $key, $settings->{ $key };
    }

    my $value = $settings->{ $key };
    $value =~ s/%(\w+)%/expand_placeholder($settings, $1, \%seen)/ge;

    return $value;
}

1;
