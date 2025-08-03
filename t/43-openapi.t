# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later.

use Test::Most;
use Test::Warnings qw(:report_warnings);
use Mojo::Base -strict, -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';
use Test::Mojo;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
$t->app->log->level('trace');

subtest jobs => sub {
    $t->get_ok('/api/v1/jobs/23')->status_is(404)->json_is('/error', 'Job does not exist');
    $t->get_ok('/api/v1/jobs/23a')->status_is(400)->json_like('/errors/0/message', qr{Expected integer - got string});

    $t->get_ok('/api/v1/jobs/80000')->status_is(200)->json_is('/job/id', '80000')->json_is('/job/testresults', undef);
    $t->get_ok('/api/v1/jobs/80000/details')->status_is(200)->json_is('/job/id', '80000')
      ->json_is('/job/testresults', []);

    $t->post_ok('/api/v1/jobs/80000/prio', form => {prio => 99})->status_is(200);
    $t->post_ok('/api/v1/jobs/80000/prio', form => {prio => 'not a number'})->status_is(400)->json_like('/error', qr{Erroneous parameters.*prio});
};

subtest jobgroups => sub {
    $t->get_ok('/api/v1/job_groups/23')->status_is(404)->json_is('/error', 'Group 23 does not exist');
    $t->get_ok('/api/v1/job_groups/1001')->status_is(200)->json_is('/0/id', '1001');


    $t->post_ok('/api/v1/job_groups', {Authorization => 'Bearer 123'}, form => {name => 'xy'})->status_is(200)
      ->json_is({id => 1003});

    $t->post_ok('/api/v1/job_groups', {Authorization => 'Bearer 123'}, form => {name => 'xy', size_limit_gb => 'oops'})
      ->status_is(400)->json_like('/errors/0/message' => qr{Expected integer - got string});
    $t->post_ok('/api/v1/job_groups', {Authorization => 'Bearer 123'}, form => {name => ' '})->status_is(400)
      ->json_like('/errors/0/message' => qr{String does not match});

    $t->post_ok('/api/v1/job_groups', {Authorization => 'Bearer'}, form => {name => 'xy'})->status_is(401)
      ->json_like('/errors/0/message' => qr{Api Key not present});
};

done_testing;
