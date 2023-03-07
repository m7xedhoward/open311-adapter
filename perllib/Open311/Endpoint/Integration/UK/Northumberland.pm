package Open311::Endpoint::Integration::UK::Northumberland;

use Moo;
use Data::Dumper;
extends 'Open311::Endpoint::Integration::AlloyV2';

around BUILDARGS => sub {
    my ($orig, $class, %args) = @_;
    $args{jurisdiction_id} = 'northumberland_alloy_v2';
    return $class->$orig(%args);
};

sub service_request_content {
    '/open311/service_request_extended'
}
sub process_attributes {
    my ($self, $args) = @_;

    my $attributes = $self->SUPER::process_attributes($args);

    # The way the reporter's contact information gets included with a
    # inspection is Northumberland-specific, so it's handled here.
    # Their Alloy set up attaches a "Contact" resource to the
    # inspection resource via the "caller" attribute.

    # Take the contact info from the service request and find/create
    # a matching contact
    my $contact_resource_id = $self->_find_or_create_contact($args);

    # For category we use the group and not the category
    my ( $group, $category ) = split('_', $args->{service_code});
    my $category_code = $self->_find_category_code($category);
    push @$attributes, {
        attributeCode => $self->config->{request_to_resource_attribute_manual_mapping}->{category},
        value => [ $category_code ],
    };
    
    my $group_code = $self->_find_group_code($group);
    push @$attributes, {
        attributeCode => $self->config->{request_to_resource_attribute_manual_mapping}->{group},
        value => [ $group_code ],
    };
    

    # Attach the caller to the inspection attributes
    push @$attributes, {
        attributeCode => $self->config->{contact}->{attribute_id},
        value => [ $contact_resource_id ],
    };

    return $attributes;

}



sub _find_category_code {
    my ($self, $category) = @_;

    my $results = $self->alloy->search( {
            properties => {
                dodiCode => $self->config->{category_list_code},
                attributes => ["all"],
                collectionCode => "Live"
            },
        }
    );

    for my $cat ( @{ $results } ) {
        my $a = $self->alloy->attributes_to_hash($cat);
        
        return $cat->{itemId} if $a->{$self->config->{category_title_attribute}} eq $category;
    }
}

sub _find_group_code {
    my ($self, $group) = @_;

    my $results = $self->alloy->search( {
            properties => {
                dodiCode => $self->config->{group_list_code},
                attributes => ["all"],
                collectionCode => "Live"
            },
        }
    );

    for my $cat ( @{ $results } ) {
        my $a = $self->alloy->attributes_to_hash($cat);
        return $cat->{itemId} if $a->{$self->config->{group_title_attribute}} eq $group;
    }
}

1;
