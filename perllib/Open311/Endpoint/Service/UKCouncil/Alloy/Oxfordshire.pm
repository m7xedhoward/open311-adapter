package Open311::Endpoint::Service::UKCouncil::Alloy::Oxfordshire;
use Moo;
extends 'Open311::Endpoint::Service::UKCouncil::Alloy';

use Open311::Endpoint::Service::Attribute;

sub _build_attributes {
    my $self = shift;

    my @attributes = (
        @{ $self->SUPER::_build_attributes() },
        Open311::Endpoint::Service::Attribute->new(
            code => "usrn",
            description => "USRN",
            datatype => "string",
            required => 1,
            automated => 'hidden_field',
        ),
        Open311::Endpoint::Service::Attribute->new(
            code => "unit_number",
            description => "Unit number",
            datatype => "text",
            required => 1,
            automated => 'hidden_field',
        ),
        Open311::Endpoint::Service::Attribute->new(
            code => "mayrise_id",
            description => "Mayrise Identifier",
            datatype => "string",
            required => 1,
            automated => 'hidden_field',
        ),
    );

    return \@attributes;
}

1;
