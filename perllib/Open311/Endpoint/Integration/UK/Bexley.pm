package Open311::Endpoint::Integration::UK::Bexley;

use Moo;
extends 'Open311::Endpoint';
with 'Open311::Endpoint::Role::mySociety';

use Module::Pluggable
    search_path => ['Open311::Endpoint::Integration::UK::Bexley'],
    instantiate => 'new';

use Open311::Endpoint::Schema;

has jurisdiction_id => (
    is => 'ro',
    default => 'bexley',
);

has integrations => (
    is => 'lazy',
    default => sub {
        my @integrations = map {
            (my $ref = ref $_) =~ s/.*:://;
            { name => $ref, class => $_ }
        } $_[0]->plugins;
        \@integrations;
    },
);

sub _call {
    my ($self, $fn, $integration, @args) = @_;
    foreach (@{$self->integrations}) {
        next unless $_->{name} eq $integration;
        return $_->{class}->$fn(@args);
    }
}

sub _all {
    my ($self, $fn, $args) = @_;
    my @all;
    foreach (@{$self->integrations}) {
        my $name = $_->{name};
        my @results = $_->{class}->$fn($args);
        @results = map { [ $name, $_ ] } @results;
        push @all, @results;
    }
    return @all;
}

sub _map_with_new_id {
    my ($self, $attribute, @results) = @_;
    @results = map {
        my ($name, $result) = @$_;
        (ref $result)->new(%$result, $attribute => "$name-" . $result->$attribute);
    } @results;
    return @results;
}

=item

Loops through all children, extracting their services and rewriting their codes
to include which child the service has come from (in case any codes overlap).

=cut

sub services {
    my ($self, $args) = @_;
    my @services = $self->_all(services => $args);
    @services = $self->_map_with_new_id(service_code => @services);
    return @services;
}

=item

Given a combined service ID (integration-code), extract the integration and
code, call the relevant integration with the code, then return it with the code
prefixed again.

=cut

sub service {
    my ($self, $service_id, $args) = @_;
    # Extract integration from service code and pass to correct child
    my ($integration, $service_code) = $service_id =~ /^(.*?)-(.*)/;
    my $service = $self->_call('service', $integration, $service_code, $args);
    ($service) = $self->_map_with_new_id(service_code => [$integration, $service]);
    return $service;
}

=item

As with an individual service, work out which integration to pass the call to,
but we also need to restore the original combined code before leaving, as the
parent will be calling service() again.

=cut

sub post_service_request {
    my ($self, $service, $args) = @_;
    # Extract integration from service code and set up to pass to child
    my ($integration, $service_code) = $service->service_code =~ /^(.*?)-(.*)/;
    my $integration_args = { %$args, service_code => $service_code };
    # Strip off the integration part of the service code from the service object
    my $integration_service = (ref $service)->new(%$service, service_code => $service_code);

    my $result = $self->_call('post_service_request', $integration, $integration_service, $integration_args);
    ($result) = $self->_map_with_new_id(service_request_id => [$integration, $result]);
    return $result;
}

sub post_service_request_update {
    my ($self, $args) = @_;

    # Bexley knows to also send the service code through with updates already
    my ($integration, $service_code) = $args->{service_code} =~ /^(.*?)-(.*)/;
    my ($integration2, $service_request_id) = $args->{service_request_id} =~ /^(.*?)-(.*)/;
    die "$integration did not equal $integration2\n" if $integration ne $integration2;

    my $integration_args = {
        %$args,
        service_code => $service_code,
        service_request_id => $service_request_id,
    };

    my $result = $self->_call('post_service_request_update', $integration, $integration_args);
    ($result) = $self->_map_with_new_id(update_id => [$integration, $result]);
    return $result;
}

sub get_service_request_updates {
    my ($self, $args) = @_;
    my @updates = $self->_all(get_service_request_updates => $args);
    @updates = $self->_map_with_new_id(update_id => @updates);
    return @updates;
}

sub get_service_requests {
    my ($self, $args) = @_;
    my @requests = $self->_all(get_service_requests => $args);
    @requests = $self->_map_with_new_id(service_request_id => @requests);
    return @requests;
}

__PACKAGE__->run_if_script;
