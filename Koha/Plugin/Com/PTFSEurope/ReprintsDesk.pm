package Koha::Plugin::Com::PTFSEurope::ReprintsDesk;

use Modern::Perl;

use base qw(Koha::Plugins::Base);
use Koha::DateUtils qw( dt_from_string );

use File::Basename qw( dirname );
use Cwd qw(abs_path);
use CGI;
use JSON qw( encode_json decode_json );

our $VERSION = "1.0.0";

our $metadata = {
    name            => 'Reprints Desk',
    author          => 'Andrew Isherwood',
    date_authored   => '2022-04-26',
    date_updated    => "2022-04-26",
    minimum_version => '18.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin provides Koha API routes enabling access to the Reprints Desk API' 
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    $self->{config} = decode_json($self->retrieve_data('reprintsdesk_config') || '{}');

    return $self;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });
        my $config = $self->{config};

        # Prepare processing instructions if necessary
        my @processinginstructions = ();
        if ($config->{processinginstructions}) {
            my @pairs = split '_', $config->{processinginstructions};
            foreach my $pair(@pairs) {
                my ($key, $value) = split ":", $pair;
                push @processinginstructions, { $key => $value };
            }
        }

        # Prepare customer references if necessary
        my @customerreferences = ();
        if ($config->{customerreferences}) {
            my @pairs = split '_', $config->{customerreferences};
            foreach my $pair(@pairs) {
                my ($key, $value) = split ":", $pair;
                push @customerreferences, { $key => $value };
            }
        }

        $template->param(
            config => $self->{config},
            processinginstructions => \@processinginstructions,
            processinginstructions_size => scalar @processinginstructions,
            customerreferences => \@customerreferences,
            customerreferences_size => scalar @customerreferences,
            cwd => dirname(__FILE__)
        );
        $self->output_html( $template->output() );
    } else {
        my %blacklist = ('save' => 1, 'class' => 1, 'method' => 1);
        my $hashed = { map { $_ => (scalar $cgi->param($_))[0] } $cgi->param };
        my $p = {};


        my $processinginstructions = {};
        foreach my $key (keys %{$hashed}) {
            if (!exists $blacklist{$key} && $key !~ /^processinginstructions/) {
                $p->{$key} = $hashed->{$key};
            }

            # Create a hash with key and value pairs together
            # Keys are the index of the instructions, so we can keep
            # them in order, values are concatenated instruction IDs and values
            if (
                $key =~ /^processinginstructions_id_(\d+)$/ &&
                length $hashed->{"processinginstructions_id_$1"} > 0 &&
                length $hashed->{"processinginstructions_value_$1"} > 0
            ) {
                $processinginstructions->{$1} = $hashed->{"processinginstructions_id_$1"} . ":" . $hashed->{"processinginstructions_value_$1"};
            }
        }

        # If we have any processing instructions to store, add them to our hash
        # Note we sort the keys here so they will remain in a predictable order
        my @processing_keys = sort keys %{$processinginstructions};
        if (scalar @processing_keys > 0) {
            my @processing_pairs = ();
            foreach my $processing_key(@processing_keys) {
                push @processing_pairs, $processinginstructions->{$processing_key};
            }
            $p->{processinginstructions} = join "_", @processing_pairs;
        }

        my $customerreferences = {};
        foreach my $key (keys %{$hashed}) {
            if (!exists $blacklist{$key} && $key !~ /^customerreferences/) {
                $p->{$key} = $hashed->{$key};
            }

            # Create a hash with key and value pairs together
            # Keys are the index of the references, so we can keep
            # them in order, values are concatenated references IDs and values
            if (
                $key =~ /^customerreferences_id_(\d+)$/ &&
                length $hashed->{"customerreferences_id_$1"} > 0 &&
                length $hashed->{"customerreferences_value_$1"} > 0
            ) {
                $customerreferences->{$1} = $hashed->{"customerreferences_id_$1"} . ":" . $hashed->{"customerreferences_value_$1"};
            }
        }

        $p->{use_borrower_details} =
            ( exists $hashed->{use_borrower_details} ) ? 1 : 0;

        # If we have any customer references to store, add them to our hash
        # Note we sort the keys here so they will remain in a predictable order
        my @references_keys = sort keys %{$customerreferences};
        if (scalar @references_keys > 0) {
            my @references_pairs = ();
            foreach my $references_key(@references_keys) {
                push @references_pairs, $customerreferences->{$references_key};
            }
            $p->{customerreferences} = join "_", @references_pairs;
        }

        $self->store_data({ reprintsdesk_config => scalar encode_json($p) });
        print $cgi->redirect(-url => '/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::Com::PTFSEurope::ReprintsDesk&method=configure');
        exit;
    }
}

sub api_routes {
    my ($self, $args) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'reprintsdesk';
}

sub install() {
    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data(
        { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') }
    );

    return 1;
}

sub uninstall() {
    return 1;
}

1;
