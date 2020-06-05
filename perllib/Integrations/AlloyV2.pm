package Integrations::AlloyV2;

use DateTime::Format::W3CDTF;
use Moo;
use Cache::Memcached;
use LWP::UserAgent;
use HTTP::Headers;
use HTTP::Request;
use HTTP::Request::Common;
use URI;
use Try::Tiny;
use Encode qw(encode_utf8);
use JSON::MaybeXS qw(encode_json decode_json);

with 'Role::Config';
with 'Role::Logger';


has memcache_namespace  => (
    is => 'lazy',
    default => sub { $_[0]->config_filename }
);

has memcache => (
    is => 'lazy',
    default => sub {
        my $self = shift;
        new Cache::Memcached {
            'servers' => [ '127.0.0.1:11211' ],
            'namespace' => 'open311adapter:' . $self->memcache_namespace . ':',
            'debug' => 0,
            'compress_threshold' => 10_000,
        };
    },
);

sub api_call {
    my ($self, %args) = @_;
    my $call = $args{call};
    my $body = $args{body};

    my $ua = LWP::UserAgent->new(
        agent => "FixMyStreet/open311-adapter",
    );
    my $method = $args{method};
    $method = $body ? 'POST' : 'GET' unless $method;
    my $uri = URI->new( $self->config->{api_url} . $call );

    $args{params}->{token} = $self->config->{api_key};

    $uri->query_form(%{ $args{params} });
    my $request = HTTP::Request->new($method, $uri);
    if ($args{is_file}) {
        $request = HTTP::Request::Common::POST(
            $uri,
            Content_Type => 'form-data',
            Content => [ file => [undef, $args{params}->{'model.name'}, Content => $body] ]
        );
    } elsif ($body) {
        $request->content_type('application/json; charset=UTF-8');
        $request->content(encode_json($body));
        $self->logger->debug($call);
        $self->logger->debug(encode_json($body));
    }
    my $response = $ua->request($request);
    if ($response->is_success) {
        $self->logger->debug($response->content) if $body;
        return decode_json($response->content);
    } else {
        $self->logger->error($call);
        $self->logger->error(encode_json($body)) if $body and (ref $body eq 'HASH' || ref $body eq 'ARRAY');
        $self->logger->error($response->content);
        try {
            my $json_response = decode_json($response->content);
            die "Alloy API call failed: [$json_response->{errorCode} $json_response->{errorCodeString}] $json_response->{debugErrorMessage}";
        } catch {
            die $response->content;
        };
    }
}

sub get_designs {
    my $self = shift;

    my $design = $self->api_call(
        call => "design/" . $self->config->{rfs_design},
    );
    return ($design);
}

sub get_valuetype_mapping {
    my $self = shift;

    my $mapping = {
        BOOLEAN => "number", # 0/1?
        STRING => "text", # or maybe string?
        OPTION => "singlevaluelist",
        DATETIME => "datetime",
        DATE => "datetime", # this and TIME are obviously not perfect
        TIME => "datetime",
        INTEGER => "number",
        FLOAT => "number",
        GEOMETRY => "string", # err. Probably GeoJSON?
        IRG_REF => "string", # err. This is an item lookup
    };
    return $mapping;
    my $valuetypes = $self->api_call(call => "reference/value-type");
    my %mapping = map { $_->{valueTypeId} => $mapping->{$_->{code}} } @$valuetypes;
    return \%mapping;
}

sub get_parent_attributes {
    my $self = shift;
    my $source_type_id = shift;

    # TODO: What's the correct behaviour if there's none?
    return $self->api_call(
        call => "source-type/$source_type_id/linked-source-types",
        params => { irgConfigCode => $self->config->{irg_config_code} }
    );
}

sub get_sources {
    my $self = shift;

    my $key = "get_sources";
    my $expiry = 1800; # cache all these API calls for 30 minutes
    my $sources = $self->memcache->get($key);
    unless ($sources) {
        $sources = [];
        my $type_mapping = $self->get_valuetype_mapping();
        my @designs = $self->get_designs;
        for my $design (@designs) {

            my $source = {
                code => $design->{code},
                description => $design->{name},
            };

            my @attributes = ();
            my $design_attributes = $design->{attributes};
            for my $attribute (@$design_attributes) {
                next unless $attribute->{required};

                my $datatype = $type_mapping->{$attribute->{type}} || "string";
                my %values = ();
                if ($datatype eq 'singlevaluelist' && $attribute->{attributeOptionTypeId}) {
                    # Fetch all the options for this attribute from the API
                    my $options = $self->api_call(call => "attribute-option-type/$attribute->{attributeOptionTypeId}")->{optionList};
                    for my $option (@$options) {
                        $values{$option->{optionId}} = $option->{optionDescription};
                    }
                }

                push @attributes, {
                    description => $attribute->{name},
                    name => $attribute->{name},
                    id => $attribute->{code},
                    required => $attribute->{required},
                    datatype => $datatype,
                    values => \%values,
                };
            }
            $source->{attributes} = \@attributes;
            push @$sources, $source;
        }
        $self->memcache->set($key, $sources, $expiry);
    }
    return $sources;
}

sub update_attributes {
    my ($self, $values, $map, $attributes) = @_;

    for my $key ( keys %$map ) {
        push @$attributes, {
            attributeCode => $map->{$key},
            value => $values->{$key}
        }
    }

    return $attributes;
}

1;
