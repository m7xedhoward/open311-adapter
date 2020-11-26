package Open311::Endpoint::Integration::UK::CentralBedfordshire;

# use SOAP::Lite +trace => [ qw/method debug/ ];

use Moo;
extends 'Open311::Endpoint::Integration::Symology';

has jurisdiction_id => (
    is => 'ro',
    default => 'centralbedfordshire_symology',
);

# Updates from FMS should always have a GN11 code, meaning "Customer called"
sub event_action_event_type { 'GN11'}

sub process_service_request_args {
    my $self = shift;

    my $area_code = (delete $_[0]->{attributes}->{area_code}) || '';
    my @args = $self->SUPER::process_service_request_args(@_);
    my $response = $args[0];

    my $lookup = $self->endpoint_config->{area_to_username};
    $response->{NextActionUserName} ||= $lookup->{$area_code};

    return @args;
}

sub _get_csvs {
    my $self = shift;

    my $dir = $self->endpoint_config->{updates_sftp}->{out};
    my @files = glob "$dir/*.CSV";
    return \@files;
}

sub _event_description {
    my ($self, $event) = @_;

    # return join " :: ", $event->{HistoryType}, $event->{HistoryEventType}, $event->{HistoryEventDescription}, $event->{HistoryEvent}, $event->{HistoryReference}, $event->{HistoryDescription};
    # XXX Should this happen for all events or only certain types?
    return $event->{HistoryDescription};
}

sub _event_status {
    my ($self, $event) = @_;

    my $map = $self->endpoint_config->{event_status_mapping}->{$event->{HistoryType}};
    return unless $map;
    return $map->{$event->{HistoryEventType}};
}

sub get_service_request_updates {
    my ($self, $args) = @_;

    my $w3c = DateTime::Format::W3CDTF->new;
    my $start_time = $w3c->parse_datetime($args->{start_date});
    my $end_time = $w3c->parse_datetime($args->{end_date});

    # Unlike Bexley, the CSV from the SFTP doesn't have everything we need to
    # build the ServiceRequestUpdates. We can get the full picture from the
    # Symology API by calling the GetRequestAdditionalGroup method for each
    # enquiry mentioned in the CSVs and looking at the history entries there.

    my %seen;
    my $csv_files = $self->_get_csvs;
    foreach (@$csv_files) {
        open my $fh, '<', $_;

        my $csv = Text::CSV->new;
        $csv->header($fh, { munge_column_names => {
            "History Date/Time" => "date_history",
        } });

        while (my $row = $csv->getline_hr($fh)) {
            next unless $row->{CRNo} && $row->{date_history};
            my $dt = $self->date_formatter->parse_datetime($row->{date_history});
            next unless $dt >= $start_time && $dt <= $end_time;

            $seen{$row->{CRNo}} = 1;
        }
    }

    my @updates;
    push(@updates, @{ $self->_updates_for_crno($_, $start_time, $end_time) }) for keys %seen;
    return @updates;
}

sub _updates_for_crno {
    my ($self, $crno, $start, $end) = @_;

    my $response = $self->get_integration->GetRequestAdditionalGroup(
        "SERV",
        $crno
    );

    if (($response->{StatusCode}//-1) != 0) {
        my $error = $response->{StatusMessage};
        $self->log_and_die("Couldn't call GetRequestAdditionalGroup for CRNo $crno: $error");
    }

    my $history = $response->{Request}->{EventHistory}->{EventHistoryGet};
    my @updates;
    my $w3c = DateTime::Format::W3CDTF->new;
    for my $event (@$history) {
        # The event datetime is stored in two fields - both of which are datetimes
        # but HistoryTime has today's date and HistoryDate has a midnight timestamp.
        # So we need to reconstruct it.
        my $date = $w3c->parse_datetime($event->{HistoryDate});
        my $time = $w3c->parse_datetime($event->{HistoryTime});
        $date->set(hour => $time->hour, minute => $time->minute, second => $time->second);
        $date->set_time_zone("Europe/London");
        next unless $date >= $start && $date <= $end;

        my $update = $self->_update_for_history_event($event, $crno, $date);
        next unless $update;
        push @updates, $update;
    }

    return \@updates;
}

sub _update_for_history_event {
    my ($self, $event, $crno, $dt) = @_;

    my $status = $self->_event_status($event);
    return unless $status;
    my $description = $self->_event_description($event);
    my $update_id = $crno . '_' . $event->{LineNo};
    my $external_status = $event->{HistoryType};
    $external_status = "${external_status}_" . $event->{HistoryEventType} if $external_status eq '21';

    return Open311::Endpoint::Service::Request::Update::mySociety->new(
        status => $status,
        update_id => $update_id,
        service_request_id => $crno,
        description => $description,
        updated_datetime => $dt,
        external_status_code => $external_status,
    );
}


1;
