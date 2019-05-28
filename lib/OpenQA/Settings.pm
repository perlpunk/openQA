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

    my $error_string;

    for my $value (values %$settings) {
        next unless defined $value;

        # loop the value until there is no %KEY% in it
        while ($value =~ /%(\w+)%/) {
            my $key = $1;
            last unless defined $settings->{$key};

            my $replaced_value = $settings->{$key};

# used to record already replaced value. If the value has been in this array which means there is a circular reference, then return an error message.
            my %replaced_hash;

            while ($replaced_value =~ /%(\w+)%/) {
                my $key_in_value = $1;
                last unless defined $settings->{$key_in_value};

                return "The key $key_in_value contains a circular reference, its value is " . $settings->{$key_in_value}
                  if exists $replaced_hash{$key_in_value};

                $replaced_value = $settings->{$key_in_value};
                $replaced_hash{$key_in_value} = 1;
            }
            $value =~ s/(%$key%)/$replaced_value/;
        }
    }
    return undef;
}

1;
