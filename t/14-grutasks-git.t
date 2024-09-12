#!/usr/bin/env perl
# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Task::Git::Clone;
require OpenQA::Test::Database;
use OpenQA::Test::Utils qw(run_gru_job perform_minion_jobs);
use OpenQA::Test::TimeLimit '20';
use Test::MockModule;
use Test::Mojo;
use Test::Warnings qw(:report_warnings);
use Mojo::Util qw(dumper scope_guard);
use Mojo::File qw(path tempdir);
use Time::Seconds;

# Avoid tampering with git checkout
my $workdir = tempdir("$FindBin::Script-XXXX", TMPDIR => 1);
my $guard = scope_guard sub { chdir $FindBin::Bin };
chdir $workdir;
path('t/data/openqa/db')->make_path;
my $git_clones = "$workdir/git-clones";
mkdir $git_clones;

my $schema = OpenQA::Test::Database->new->create();
my $t = Test::Mojo->new('OpenQA::WebAPI');

# launch an additional app to serve some file for testing blocking downloads
my $mojo_port = Mojo::IOLoop::Server->generate_port;
my $webapi = OpenQA::Test::Utils::create_webapi($mojo_port, sub { });

# prevent writing to a log file to enable use of combined_like in the following tests
$t->app->log(Mojo::Log->new(level => 'warn'));

subtest 'git clone' => sub {
    my $openqa_git = Test::MockModule->new('OpenQA::Git');
    my @mocked_git_calls;
    my $clone_dirs = {
        '/etc/' => 'http://localhost/foo.git',
        '/root/' => 'http://localhost/foo.git#foobranch',
        '/this_directory_does_not_exist/' => 'http://localhost/bar.git',
    };
    $openqa_git->redefine(
        run_cmd_with_log_return_error => sub ($cmd) {
            push @mocked_git_calls, "@$cmd" =~ s/\Q$git_clones//r;
            my $stdout = '';
            splice @$cmd, 0, 2 if $cmd->[0] eq 'env';
            my $path = '';
            (undef, $path) = splice @$cmd, 1, 2 if $cmd->[1] eq '-C';
            my $action = $cmd->[1];
            my $return_code = 0;
            if ($action eq 'remote') {
                if ($clone_dirs->{$path}) {
                    $stdout = $clone_dirs->{$path} =~ s/#.*//r;
                }
                elsif ($path =~ m/opensuse/) {
                    $stdout = 'http://osado';
                }
            }
            elsif ($action eq 'ls-remote') {
                $stdout = 'ref: refs/heads/master	HEAD';
                $stdout = 'ref: something' if "@$cmd" =~ m/nodefault/;
            }
            elsif ($action eq 'branch') {
                $stdout = 'master';
            }
            elsif ($action eq 'diff-index') {
                $return_code = 1 if $path eq '/opt/';    # /opt/ simulates dirty checkout
                $return_code = 2
                  if $path eq '/lib/';    # /lib/ simulates error when checking checkout dirty status
            }
            return {
                status => $return_code == 0,
                return_code => $return_code,
                stderr => '',
                stdout => $stdout,
            };
        });
    my $res = run_gru_job($t->app, 'git_clone', $clone_dirs, {priority => 10});
    is $res->{result}, 'Job successfully executed', 'minion job result indicates success';
    #<<< no perltidy
    my $expected_calls = [
        # /etc/
        ['get-url'        => 'git -C /etc/ remote get-url origin'],
        ['check dirty'    => 'git -C /etc/ diff-index HEAD --exit-code'],
        ['default remote' => 'env GIT_SSH_COMMAND="ssh -oBatchMode=yes" git ls-remote --symref http://localhost/foo.git HEAD'],
        ['current branch' => 'git -C /etc/ branch --show-current'],
        ['fetch default'  => 'env GIT_SSH_COMMAND="ssh -oBatchMode=yes" git -C /etc/ fetch origin master'],
        ['reset'          => 'git -C /etc/ reset --hard origin/master'],

        # /root
        ['get-url'        => 'git -C /root/ remote get-url origin'],
        ['check dirty'    => 'git -C /root/ diff-index HEAD --exit-code'],
        ['current branch' => 'git -C /root/ branch --show-current'],
        ['fetch branch'   => 'env GIT_SSH_COMMAND="ssh -oBatchMode=yes" git -C /root/ fetch origin foobranch'],

        # /this_directory_does_not_exist/
        ['clone' => 'env GIT_SSH_COMMAND="ssh -oBatchMode=yes" git clone http://localhost/bar.git /this_directory_does_not_exist/'],
    ];
    #>>> no perltidy
    for my $i (0 .. $#$expected_calls) {
        my $test = $expected_calls->[$i];
        is $mocked_git_calls[$i], $test->[1], "$i: " . $test->[0];
    }

    subtest 'no default remote branch' => sub {
        $ENV{OPENQA_GIT_CLONE_RETRIES} = 0;
        $clone_dirs = {'/tmp/' => 'http://localhost/nodefault.git'};
        my $res = run_gru_job($t->app, 'git_clone', $clone_dirs, {priority => 10});
        is $res->{state}, 'failed', 'minion job failed';
        like $res->{result}, qr/Error detecting remote default.*ref: something/, 'error message';
    };

    subtest 'git clone retried on failure' => sub {
        $ENV{OPENQA_GIT_CLONE_RETRIES} = 1;
        my $openqa_clone = Test::MockModule->new('OpenQA::Task::Git::Clone');
        $openqa_clone->redefine(_git_clone => sub (@) { die "fake error\n" });
        $res = run_gru_job($t->app, 'git_clone', $clone_dirs, {priority => 10});
        is $res->{retries}, 1, 'job retries incremented';
        is $res->{state}, 'inactive', 'job set back to inactive';
    };
    subtest 'git clone fails when all retry attempts exhausted' => sub {
        $ENV{OPENQA_GIT_CLONE_RETRIES} = 0;
        my $openqa_clone = Test::MockModule->new('OpenQA::Task::Git::Clone');
        $openqa_clone->redefine(_git_clone => sub (@) { die "fake error\n" });
        $res = run_gru_job($t->app, 'git_clone', $clone_dirs, {priority => 10});
        is $res->{retries}, 0, 'job retries not incremented';
        is $res->{state}, 'failed', 'job considered failed';
    };

    subtest 'dirty git checkout' => sub {
        # /opt/ is mocked to be always reported as dirty
        $clone_dirs = {'/opt/' => 'http://localhost/foo.git'};
        my $res = run_gru_job($t->app, 'git_clone', $clone_dirs, {priority => 10});
        is $res->{state}, 'failed', 'minion job failed';
        like $res->{result}, qr/NOT updating dirty git checkout/, 'error message';
    };

    subtest 'error testing dirty git checkout' => sub {
        # /lib/ is mocked to be always reported as dirty
        $clone_dirs = {'/lib/' => 'http://localhost/foo.git'};
        my $res = run_gru_job($t->app, 'git_clone', $clone_dirs, {priority => 10});
        is $res->{state}, 'failed', 'minion job failed';
        like $res->{result}, qr/Internal Git error: Unexpected exit code 2/, 'error message';
    };

    subtest 'update clones without CASEDIR' => sub {
        @mocked_git_calls = ();
        #<<< no perltidy
        my $expected_calls = [
            # /opensuse
            ['get-url'        => 'git -C /opensuse remote get-url origin'],
            ['check dirty'    => 'git -C /opensuse diff-index HEAD --exit-code'],
            ['default remote' => 'env GIT_SSH_COMMAND="ssh -oBatchMode=yes" git ls-remote --symref http://osado HEAD'],
            ['current branch' => 'git -C /opensuse branch --show-current'],
            ['fetch default ' => 'env GIT_SSH_COMMAND="ssh -oBatchMode=yes" git -C /opensuse fetch origin master'],
            ['reset'          => 'git -C /opensuse reset --hard origin/master'],

            # /opensuse/needles
            ['get-url'        => 'git -C /opensuse/needles remote get-url origin'],
            ['check dirty'    => 'git -C /opensuse/needles diff-index HEAD --exit-code'],
            ['default remote' => 'env GIT_SSH_COMMAND="ssh -oBatchMode=yes" git ls-remote --symref http://osado HEAD'],
            ['current branch' => 'git -C /opensuse/needles branch --show-current'],
            ['fetch branch'   => 'env GIT_SSH_COMMAND="ssh -oBatchMode=yes" git -C /opensuse/needles fetch origin master'],
            ['reset'          => 'git -C /opensuse/needles reset --hard origin/master'],
        ];
        #>>> no perltidy
        $ENV{OPENQA_GIT_CLONE_RETRIES} = 0;
        $clone_dirs = {
            "$git_clones/opensuse" => undef,
            "$git_clones/opensuse/needles" => undef,
        };
        my $res = run_gru_job($t->app, 'git_clone', $clone_dirs, {priority => 10});
        is $res->{state}, 'finished', 'minion job finished';
        is $res->{result}, 'Job successfully executed', 'minion job result indicates success';
        for my $i (0 .. $#$expected_calls) {
            my $test = $expected_calls->[$i];
            is $mocked_git_calls[$i], $test->[1], "$i: " . $test->[0];
        }
    };

    subtest 'minion guard' => sub {
        my $guard = $t->app->minion->guard('limit_needle_task', ONE_HOUR);
        my $start = time;
        $res = run_gru_job($t->app, 'git_clone', $clone_dirs, {priority => 10});
        is $res->{state}, 'inactive', 'job is inactive';
        ok(($res->{delayed} - $start) > 5, 'job delayed as expected');
    };
};

subtest 'git_update_all' => sub {
    OpenQA::App->singleton->config->{'scm git'}->{git_auto_update} = 'yes';
    my $testdir = $workdir->child('openqa/share/tests');
    $testdir->make_path;
    my @clones;
    for my $path (qw(archlinux archlinux/products/archlinux/needles example opensuse opensuse/needles)) {
        push @clones, $testdir->child($path)->make_path . '';
        $testdir->child("$path/.git")->make_path;
    }
    local $ENV{OPENQA_BASEDIR} = $workdir;
    my $minion = $t->app->minion;
    my $result = $t->app->gru->enqueue_git_update_all;
    my $job = $minion->job($result->{minion_id});
    my $args = $job->info->{args}->[0];
    is_deeply [sort keys %$args], \@clones, 'job args as expected';
};

done_testing();

# clear gru task queue at end of execution so no 'dangling' tasks
# break subsequent tests; can happen if a subtest creates a task but
# does not execute it, or we crash partway through a subtest...
END {
    $webapi and $webapi->signal('TERM');
    $webapi and $webapi->finish;
    $t && $t->app->minion->reset;
}
