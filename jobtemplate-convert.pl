#!/usr/bin/perl

use strict;
use warnings;
use 5.010;

use FindBin '$Bin';
use lib "$Bin/local/lib/perl5";
use YAML::PP;
use YAML::PP::Highlight;
use YAML::LibYAML::API::XS;
use YAML::PP::Common;
use Encode;
use Data::Dumper;
use constant DEBUG => $ENV{DEBUG} ? 1 : 0;

my $yp = YAML::PP->new;
my ($jt, $ts) = @ARGV;
my $template_file  = "$Bin/data/jobtemplates/$jt.yaml";
my $testsuite_file = "$Bin/data/testsuites/$ts.json";
my $host           = 'https://openqa.opensuse.org';

fetch_testsuite($ts);
fetch_jobtemplate($jt);

my $testsuite = do {
    my $data       = $yp->load_file($testsuite_file);
    my $testsuites = $data->{TestSuites} or die "No TestSuites";
    $testsuites->[0];
};

open my $fh, '<', $template_file or die $!;
my @lines = <$fh>;
close $fh;
my @events = parse_events($template_file);

while (1) {
    my ($found) = search_testsuite(\@lines, \@events, $testsuite);
    last unless $found;
}
say "=========== NEW =============";
print @lines;
open $fh, '>', "$template_file.new" or die $!;
print $fh @lines;
close $fh;

say "Created $template_file.new";
my $out = qx{$Bin/script/openqa-validate-yaml $template_file.new 2>&1};
if ($?) {
    say "Validation of new file failed:\n$out";
    exit 1;
}
say "Validation of new file passed";

sub search_testsuite {
    my ($lines, $items, $ts) = @_;
    my $name     = $ts->{name};
    my $settings = $ts->{settings};
    my %settings = map { $_->{key} => $_->{value} } @$settings;
    return unless @$items;
    my $tline = 0;
    my $tcol  = 0;
    while (my $ev = shift @$items) {
        my $event = $ev->{event};
        my $types = $ev->{types};
        my $count = $ev->{count};
        my $level = $ev->{level};
        pp($ev);

        my $found_key
          = (     $event->{name} eq 'scalar_event' and $event->{value} eq $name
              and $types->[$level] eq 'MAP'
              and $count->[$level] == 1);
        my $found_seq = ($event->{name} eq 'scalar_event' and $event->{value} eq $name and $types->[$level] eq 'SEQ');
        if ($found_key) {
            say "========= KEY $level $name" if DEBUG;
            my $found_settings = 0;
            my $found_description;
            $tline = $event->{start}->{line};
            $tcol  = $event->{start}->{column};
            my $next_map = $items->[0]->{event};
            my $map_col  = $next_map->{start}->{column};
            my @ts_events;
            while ($items->[0]->{level} > $level) {
                push @ts_events, shift @$items;
            }
            while (my $ev = shift @ts_events) {
                pp($ev);
                next unless $ev->{level} == $level + 1;
                next if $ev->{event}->{name} ne 'scalar_event';
                if ($ev->{event}->{value} eq 'settings') {
                    say "========= SEQ $level settings" if DEBUG;
                    my $sline           = $ev->{event}->{start}->{line};
                    my $next_map        = $ts_events[0]->{event};
                    my $map_col         = $next_map->{start}->{column};
                    my $append_settings = inline_yaml($map_col, \%settings,);

                    say "Appending settings to existing '$name:' entry";
                    $lines->[$sline] .= $append_settings;
                    $found_settings = 1;
                }
                elsif ($ev->{event}->{value} eq 'description') {
                    say "========= SEQ $level description" if DEBUG;
                    # description here will overwrite testsuite description,
                    # nothing to do
                    $found_description = 1;
                }
            }
            unless ($found_settings) {
                my $append_settings = inline_yaml($map_col + 2, \%settings,);
                $append_settings = (' ' x ($map_col)) . "settings:\n" . $append_settings;

                say "Inserting settings into '$name:' entry";
                $lines->[$tline] .= $append_settings;
            }
            unless ($found_description) {
                my $desc_yaml = inline_yaml($map_col, {description => $ts->{description}},);

                say "Inserting description into '$name:' entry";
                $lines->[$tline] .= $desc_yaml;
            }

            my $yaml = inline_yaml($map_col, {testsuite => 'empty'},);
            say "Inserting 'testsuite: empty' into '$name:' entry";
            $lines->[$tline] .= $yaml;
            return $found_key;
        }
        elsif ($found_seq) {
            say "========= SEQ $level $name" if DEBUG;
            $tline = $event->{start}->{line};
            $tcol  = $event->{start}->{column};
            $lines->[$tline] =~ s/(?<=\Q$name\E)/:/;
            my $line    = $lines->[$tline];
            my $ts_yaml = ts_yaml($ts);
            $ts_yaml =~ s/^/' ' x ($tcol + 2)/meg;

            say "Appending test suite to '$name' entry";
            $lines->[$tline] .= $ts_yaml;
            return 1;
        }
    }
    return;
}

sub inline_yaml {
    my ($indent, $data) = @_;
    my $yaml = YAML::PP->new(header => 0)->dump_string($data);
    $yaml =~ s/^/' ' x ($indent)/meg;
    return $yaml;
}

sub ts_yaml {
    my ($ts)     = @_;
    my $settings = delete $ts->{settings};
    my %settings = map { $_->{key} => $_->{value} } @$settings;
    my %data     = (
        testsuite   => 'empty',
        description => $ts->{description},
        settings    => \%settings,
    );
    my $yaml = YAML::PP->new(header => 0)->dump_string(\%data);
    return $yaml;
}

sub parse_events {
    my ($template_file) = @_;
    my $parse_events = [];
    YAML::LibYAML::API::XS::parse_file_events($template_file, $parse_events);
    my $level = -1;
    my @types;
    my @count;
    my @events;
    while (my $event = shift @$parse_events) {
        next if $event->{name} =~ m/^(stream|doc)/;
        my $str = YAML::PP::Common::event_to_test_suite($event);
        if ($str =~ m/^(\+(MAP|SEQ)|=VAL)/ and $level >= 0) {
            $count[$level]++;
        }
        if ($str =~ m/^\+/) {
            $level++;
        }
        if ($str =~ m/^\+(MAP|SEQ)/) {
            $types[$level] = $1;
        }
        push @events,
          {
            event => $event,
            types => [@types],
            count => [@count],
            level => $level,
          };

        if ($str =~ m/^-/) {
            $level--;
            pop @types;
            pop @count;
        }
    }
    return @events;
}

sub fetch_testsuite {
    my ($id) = @_;
    my $file = "$Bin/data/testsuites/$id.json";
    unless (-e $testsuite_file) {
        say "Fetching $testsuite_file";
        my $cmd
          = sprintf "$Bin/script/client --host %s --apikey=%s --apisecret=%s --json-output test_suites/%d get >%s",
          $host, $ENV{APIKEY}, $ENV{APISECRET}, $id, $file;
        system $cmd;
        if ($?) {
            warn "Cmd '$cmd' failed";
            exit 1;
        }
    }
}

sub fetch_jobtemplate {
    my ($id) = @_;
    my $file = "$Bin/data/jobtemplates/$id.yaml";
    unless (-e $template_file) {
        say "Fetching $file";
        my $cmd
          = sprintf
"$Bin/script/client --host %s --apikey=%s --apisecret=%s job_templates_scheduling/%d get | jq --raw-output . >%s",
          $host, $ENV{APIKEY}, $ENV{APISECRET}, $id, $file;
        system $cmd;
        if ($?) {
            warn "Cmd '$cmd' failed";
            exit 1;
        }
    }
}

sub pp {
    my ($ev) = @_;
    return unless DEBUG;
    my $event = $ev->{event};
    my $str   = YAML::PP::Common::event_to_test_suite($event);
    say sprintf "%-20s %-35s L:%2d C:%2d %-30s %-30s",
      (' ' x ($ev->{level} * 2)) . "$ev->{level}|", $str,
      $event->{start}->{line}, $event->{start}->{column},
      "@{ $ev->{types} }", "@{ $ev->{count} }";
}
exit;
