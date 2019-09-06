package SOAP::Result;

use Object::Tiny qw(method result);

package main;

use strict;
use warnings;

BEGIN { $ENV{TEST_MODE} = 1; }

use Test::More;
use Test::MockModule;
use SOAP::Lite;

use JSON::MaybeXS;

use constant {
    NORTHING => 100,
    EASTING_BAD => -100,
    EASTING_GOOD => 100,
    EASTING_GOOD_BURNT => 200,
};

my $soap_lite = Test::MockModule->new('SOAP::Lite');
$soap_lite->mock(call => sub {
    # This is called when a test below makes a SOAP call, along with the data
    # to be passed via SOAP to the server. We check the values here, then pass
    # back a mocked result.
    my ($cls, @args) = @_;
    if ($args[0] eq 'LogonToConnector') {
        my @params = ${$args[1]->value}->value;
        is $params[1]->value, 'FMS';
        return SOAP::Result->new(result => {
            LogonSuccessful => 'true'
        });
    } elsif ($args[0] eq 'GetCnCodeList') {
        return SOAP::Result->new(result => {
            CodeList => {
                CnCode => [
                    { CodeValue => 'FLY', CodeText => 'Fly-tipping' },
                    { CodeValue => 'DOG', CodeText => 'Doggy fouling' },
                ]
            }
        });
    } elsif ($args[0] eq 'SubmitGeneralServiceRequest') {
        my @request = ${$args[1]->value}->value;
        is $request[1]->value, 'DOG';

        my $easting;
        my @coords = ${$request[2]->value}->value;
        foreach (@coords) {
            if ($_->name eq 'MapEast') {
                $easting = $_->value;
            } elsif ($_->name eq 'MapNorth') {
                is $_->value, NORTHING;
            }
        }
        my $photo_desc = "\n\n[ This report contains a photo, see: http://example.org/photo/1.jpeg ]";
        is $request[3]->value, "This is the details$photo_desc";

        if ($easting == EASTING_BAD) {
            return SOAP::Result->new(method => {
                TransactionSuccess => 'False',
                TransactionMessages => { TransactionMessage => { MessageBrief => 'Already got that report' } },
            });
        }
        return SOAP::Result->new(method => {
            ServiceRequestIdentification => {
                ServiceRequestTechnicalKey => 'ABC',
                ReferenceValue => 1001,
            }
        });
    } elsif ($args[0] eq 'GetChangedServiceRequestRefVals') {
        my @request = $args[1]->value;
        is $request[0], '2019-09-25T00:00:00Z';
        return SOAP::Result->new(method => { RefVals => [
            { ReferenceValue => 1 }, { ReferenceValue => 2 }, { ReferenceValue => 3 }
        ] });
    } elsif ($args[0] eq 'GetGeneralServiceRequestByReferenceValue') {
        my @request = $args[1]->value;
        like $request[0], qr/^[123]$/;
        return SOAP::Result->new(result => {
        });
    } else {
        is $args[0], '';
    }
});

my $integ = Test::MockModule->new('Integrations::Uniform');
$integ->mock(config => sub {
    {
        endpoint_url => 'http://bexley-uniform.example.org/',
    }
});

my $end = Test::MockModule->new('Open311::Endpoint::Integration::Uniform');
$end->mock(endpoint_config => sub {
    {
        username => 'FMS',
        service_whitelist => {
            DOG => {
                name => 'Dog fouling',
            },
            FLY => {
                name => 'Fly tipping',
            },
        },
    }
});
$end->mock(integration_class => sub { 'Integrations::Uniform' });

use Open311::Endpoint::Integration::Uniform;

my $endpoint = Open311::Endpoint::Integration::Uniform->new;

subtest "GET services" => sub {
    my $res = $endpoint->run_test_request(
        GET => '/services.json',
    );
    ok $res->is_success, 'valid request'
        or diag $res->content;

    is_deeply decode_json($res->content), [
        {
          "service_code" => "DOG",
          "service_name" => "Dog fouling",
          "description" => "Dog fouling",
          "metadata" => "true",
          "group" => "",
          "keywords" => "",
          "type" => "realtime"
       }, {
          "service_code" => "FLY",
          "service_name" => "Fly tipping",
          "description" => "Fly tipping",
          "metadata" => "true",
          "group" => "",
          "keywords" => "",
          "type" => "realtime"
       }
    ], 'correct json returned';
};

subtest "GET service" => sub {
    my $res = $endpoint->run_test_request(
        GET => '/services/DOG.json',
    );
    ok $res->is_success, 'valid request'
        or diag $res->content;

    is_deeply decode_json($res->content), {
        "service_code" => "DOG",
       "attributes" => [
          {
             "datatype" => "number",
             "code" => "easting",
             "order" => 1,
             "required" => "true",
             "automated" => "server_set",
             "description" => "easting",
             "variable" => "false",
             "datatype_description" => ""
          },
          {
             "datatype" => "number",
             "code" => "northing",
             "order" => 2,
             "required" => "true",
             "automated" => "server_set",
             "description" => "northing",
             "datatype_description" => "",
             "variable" => "false"
          },
          {
             "datatype_description" => "",
             "variable" => "false",
             "description" => "external system ID",
             "automated" => "server_set",
             "required" => "true",
             "order" => 3,
             "code" => "fixmystreet_id",
             "datatype" => "string"
          },
       ],
    }, 'correct json returned';
};

subtest "POST Dog fouling Bad" => sub {
    # Tests of the generated SOAP call appear at the top in the mocked module
    my $res = $endpoint->run_test_request(
        POST => '/requests.json',
        api_key => 'test',
        service_code => 'DOG',
        first_name => 'Bob',
        last_name => 'Mould',
        description => "This is the details",
        lat => 51,
        long => -1,
        media_url => 'http://example.org/photo/1.jpeg',
        'attribute[easting]' => EASTING_BAD,
        'attribute[northing]' => NORTHING,
        'attribute[fixmystreet_id]' => 123,
    );
    ok !$res->is_success, 'invalid request'
        or diag $res->content;

    is_deeply decode_json($res->content),
        [ {
            "description" => "Already got that report\n",
            "code" => 500,
        } ], 'correct json returned';
};

subtest "POST Dog fouling OK" => sub {
    my $res = $endpoint->run_test_request(
        POST => '/requests.json',
        api_key => 'test',
        service_code => 'DOG',
        first_name => 'Bob',
        last_name => 'Mould',
        description => "This is the details",
        lat => 51,
        long => -1,
        media_url => 'http://example.org/photo/1.jpeg',
        'attribute[easting]' => EASTING_GOOD,
        'attribute[northing]' => NORTHING,
        'attribute[fixmystreet_id]' => 123,
    );
    ok $res->is_success, 'valid request'
        or diag $res->content;

    is_deeply decode_json($res->content),
        [ {
            "service_request_id" => 1001
        } ], 'correct json returned';
};

subtest 'fetching updates' => sub {
    my $res = $endpoint->run_test_request(
        GET => '/servicerequestupdates.json?start_date=2019-09-25T00:00:00Z&end_date=2019-09-25T02:00:00Z',
    );
    ok $res->is_success, 'valid request' or diag $res->content;
    is_deeply decode_json($res->content), [
        {
            "status" => "open",
            "media_url" => "",
            "service_request_id" => 1,
            "update_id" => "1_336d5ebc",
            "updated_datetime" => "2019-09-25T02:00:00Z",
            "description" => ""
        }, {
            "status" => "open",
            "media_url" => "",
            "service_request_id" => 2,
            "update_id" => "2_336d5ebc",
            "updated_datetime" => "2019-09-25T02:00:00Z",
            "description" => ""
        }, {
            "status" => "open",
            "media_url" => "",
            "service_request_id" => 3,
            "update_id" => "3_336d5ebc",
            "updated_datetime" => "2019-09-25T02:00:00Z",
            "description" => ""
        }
    ], 'correct json returned';
};

done_testing;
