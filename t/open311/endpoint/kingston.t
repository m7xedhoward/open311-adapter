package SOAP::Result;
use Object::Tiny qw(method result);

package Integrations::Echo::Dummy;
use Path::Tiny;
use Moo;
extends 'Integrations::Echo';
sub _build_config_file { path(__FILE__)->sibling("kingston.yml")->stringify }

package Open311::Endpoint::Integration::Echo::Dummy;
use Path::Tiny;
use Moo;
extends 'Open311::Endpoint::Integration::UK::Kingston';
around BUILDARGS => sub {
    my ($orig, $class, %args) = @_;
    $args{jurisdiction_id} = 'echo_dummy';
    $args{config_file} = path(__FILE__)->sibling("kingston.yml")->stringify;
    return $class->$orig(%args);
};
has integration_class => (is => 'ro', default => 'Integrations::Echo::Dummy');

package main;

use strict;
use warnings;
use utf8;

BEGIN { $ENV{TEST_MODE} = 1; }

use Test::More;
use Test::MockModule;
use SOAP::Lite;
use JSON::MaybeXS;

use_ok 'Open311::Endpoint::Integration::UK::Kingston';

use constant EVENT_TYPE_SUBSCRIBE => 1638;

my $soap_lite = Test::MockModule->new('SOAP::Lite');
$soap_lite->mock(call => sub {
    # This is called when a test below makes a SOAP call, along with the data
    # to be passed via SOAP to the server. We check the values here, then pass
    # back a mocked result.
    my ($cls, @args) = @_;
    my $method = $args[0]->name;
    if ($method eq 'PostEvent') {
        my @params = ${$args[3]->value}->value;
        my $client_ref = $params[1]->value;
        like $client_ref, qr/RBK-2000123|REF-123/;
        return SOAP::Result->new(result => {
            EventGuid => '1234',
        });
    } elsif ($method eq 'GetEventType') {
        return SOAP::Result->new(result => {
            Datatypes => { ExtensibleDatatype => [
                { Id => 1004, Name => "Container Stuff",
                    ChildDatatypes => { ExtensibleDatatype => [
                        { Id => 1005, Name => "Quantity" },
                        { Id => 1007, Name => "Containers" },
                    ] },
                },
                { Id => 1008, Name => "Notes" },
            ] },
        });
    } else {
        is $method, 'UNKNOWN';
    }
});

use Open311::Endpoint::Integration::Echo::Dummy;
my $endpoint = Open311::Endpoint::Integration::Echo::Dummy->new;

my @params = (
    POST => '/requests.json',
    api_key => 'test',
    service_code => EVENT_TYPE_SUBSCRIBE,
    first_name => 'Bob',
    last_name => 'Mould',
    description => "This is the details",
    lat => 51,
    long => -1,
    'attribute[uprn]' => 1000001,
    'attribute[fixmystreet_id]' => 2000123,
    'attribute[Subscription_Details_Containers]' => 26, # Garden Bin
    'attribute[Subscription_Details_Quantity]' => 1,
    'attribute[Request_Type]' => 1,
);

subtest "POST subscription request OK" => sub {
    my $res = $endpoint->run_test_request(@params);
    ok $res->is_success, 'valid request'
        or diag $res->content;

    is_deeply decode_json($res->content),
        [ {
            "service_request_id" => '1234',
        } ], 'correct json returned';
};

subtest "POST subscription request with client ref provided OK" => sub {
    my $res = $endpoint->run_test_request(@params,
        'attribute[client_reference]' => 'REF-123',
    );
    ok $res->is_success, 'valid request'
        or diag $res->content;

    is_deeply decode_json($res->content),
        [ {
            "service_request_id" => '1234',
        } ], 'correct json returned';
};

done_testing;
