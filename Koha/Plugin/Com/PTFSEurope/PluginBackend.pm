package Koha::Plugin::Com::PTFSEurope::PluginBackend;

use Modern::Perl;

use base            qw(Koha::Plugins::Base);
use Koha::DateUtils qw( dt_from_string );

use File::Basename qw( dirname );
use Cwd            qw(abs_path);
use CGI;
use JSON qw( encode_json decode_json );

use JSON           qw( to_json from_json );
use File::Basename qw( dirname );

use Koha::Libraries;
use Koha::Patrons;

our $VERSION = "1.0.0";

our $metadata = {
    name            => 'PluginBackend',
    author          => 'PTFS-Europe',
    date_authored   => '2023-10-30',
    date_updated    => '2023-10-04',
    minimum_version => '23.11.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin is an ILL backend plugin example'
};

=head2 Plugin methods

=head3 new

Required I<Koha::Plugin> method

=cut

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    $self->{config} = decode_json( $self->retrieve_data('pluginbackend_config') || '{}' );

    return $self;
}

=head3 new

Optional I<Koha::Plugin> method if it implements configuration

=cut

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );
        my $config   = $self->{config};

        $template->param(
            config => $self->{config},
            cwd    => dirname(__FILE__)
        );
        $self->output_html( $template->output() );
    } else {
        my %blacklist = ( 'save' => 1, 'class' => 1, 'method' => 1 );
        my $hashed    = { map { $_ => ( scalar $cgi->param($_) )[0] } $cgi->param };
        my $p         = {};

        my $processinginstructions = {};
        foreach my $key ( keys %{$hashed} ) {
            if ( !exists $blacklist{$key} ) {
                $p->{$key} = $hashed->{$key};
            }
        }

        use Data::Dumper;
        $Data::Dumper::Maxdepth = 2;
        warn Dumper( '##### 1 #######################################################line: ' . __LINE__ );
        warn Dumper($hashed);
        warn Dumper('##### end1 #######################################################');

        $self->store_data( { pluginbackend_config => scalar encode_json($p) } );
        print $cgi->redirect( -url =>
                '/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::Com::PTFSEurope::PluginBackend&method=configure' );
        exit;
    }
}

=head3 api_routes

Optional if this plugin implements REST API routes

=cut

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

=head3 api_namespace

Optional if this plugin implements REST API routes

=cut

sub api_namespace {
    my ($self) = @_;

    return 'pluginbackend';
}

sub install() {
    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    return 1;
}

sub uninstall() {
    return 1;
}

=head2 ILL backend methods

=head3 new_backend

Required method utilized by I<Koha::Illrequest> load_backend

=cut

sub new_backend {
    my ( $class, $params ) = @_;

    my $self = {};

    $self->{_logger} = $params->{logger} if ( $params->{logger} );
    $self->{_config} = $params->{config} if ( $params->{config} );

    bless( $self, $class );

    return $self;
}

=head3 create

Required method utilized by I<Koha::Illrequest> backend_create

=cut

sub create {
    my ( $self, $params ) = @_;

    my $other = $params->{other};
    my $stage = $other->{stage};

    my $response = {
        cwd            => dirname(__FILE__),
        backend        => $self->name,
        method         => "create",
        stage          => $stage,
        branchcode     => $other->{branchcode},
        cardnumber     => $other->{cardnumber},
        status         => "",
        message        => "",
        error          => 0,
        field_map      => $self->fieldmap_sorted,
        field_map_json => to_json( $self->fieldmap() )
    };

    $response->{cardnumber} = $other->{cardnumber};

    # 'cardnumber' here could also be a surname (or in the case of
    # search it will be a borrowernumber).
    my ( $brw_count, $brw ) =
        _validate_borrower( $other->{'cardnumber'}, $stage );

    if ( $brw_count == 0 ) {
        $response->{status} = "invalid_borrower";
        $response->{value}  = $params;
        $response->{stage}  = "init";
        $response->{error}  = 1;
        return $response;
    } elsif ( $brw_count > 1 ) {

        # We must select a specific borrower out of our options.
        $params->{brw}     = $brw;
        $response->{value} = $params;
        $response->{stage} = "borrowers";
        $response->{error} = 0;
        return $response;
    } else {
        $other->{borrowernumber} = $brw->borrowernumber;
    }

    $self->{borrower} = $brw;

    # Initiate process
    if ( !$stage || $stage eq 'init' ) {

        # Pass the map of form fields in forms that can be used by TT
        # and JS
        $response->{field_map}      = $self->fieldmap_sorted;
        $response->{field_map_json} = to_json( $self->fieldmap() );

        # We just need to request the snippet that builds the Creation
        # interface.
        $response->{stage} = 'init';
        $response->{value} = $params;
        return $response;
    }

    # Validate form and perform search if valid
    elsif ( $stage eq 'validate' || $stage eq 'form' ) {

        if ( _fail( $other->{'branchcode'} ) ) {

            # Pass the map of form fields in forms that can be used by TT
            # and JS
            $response->{field_map}      = $self->fieldmap_sorted;
            $response->{field_map_json} = to_json( $self->fieldmap() );
            $response->{status}         = "missing_branch";
            $response->{error}          = 1;
            $response->{stage}          = 'init';
            $response->{value}          = $params;
            return $response;
        } elsif ( !Koha::Libraries->find( $other->{'branchcode'} ) ) {

            # Pass the map of form fields in forms that can be used by TT
            # and JS
            $response->{field_map}      = $self->fieldmap_sorted;
            $response->{field_map_json} = to_json( $self->fieldmap() );
            $response->{status}         = "invalid_branch";
            $response->{error}          = 1;
            $response->{stage}          = 'init';
            $response->{value}          = $params;
            return $response;
        } elsif ( !$self->_validate_metadata($other) ) {
            $response->{field_map}      = $self->fieldmap_sorted;
            $response->{field_map_json} = to_json( $self->fieldmap() );
            $response->{status}         = "invalid_metadata";
            $response->{error}          = 1;
            $response->{stage}          = 'init';
            $response->{value}          = $params;
            return $response;
        } else {
            my $result = $self->create_submission($params);
            $response->{stage}  = 'commit';
            $response->{next}   = "illview";
            $response->{params} = $params;
            return $response;
        }
    }
}

=head3 cancel

Required method utilized by I<Koha::Illrequest> backend_cancel

=cut

sub cancel {
    my ( $self, $params ) = @_;

    # Update the submission's status
    $params->{request}->status("CANCREQ")->store;
}

=head3 illview

Required method utilized by I<Koha::Illrequest> backend_illview

=cut

sub illview {
    my ( $self, $params ) = @_;

    return { method => "illview" };
}

=head3 edititem

Optional method utilized by this plugin's status_graph

=cut

sub edititem {
    my ( $self, $params ) = @_;

    # Don't allow editing of requested or completed submissions
    return {
        cwd    => dirname(__FILE__),
        method => 'illlist'
    } if ( $params->{request}->status eq 'REQ' || $params->{request}->status eq 'COMP' );

    my $other = $params->{other};
    my $stage = $other->{stage};
    if ( !$stage || $stage eq 'init' ) {
        my $attrs = $params->{request}->illrequestattributes->unblessed;
        foreach my $attr ( @{$attrs} ) {
            $other->{ $attr->{type} } = $attr->{value};
        }
        return {
            cwd            => dirname(__FILE__),
            error          => 0,
            status         => '',
            message        => '',
            method         => 'edititem',
            stage          => 'form',
            value          => $params,
            field_map      => $self->fieldmap_sorted,
            field_map_json => to_json( $self->fieldmap )
        };
    } elsif ( $stage eq 'form' ) {

        # Update submission
        my $submission = $params->{request};
        $submission->updated( DateTime->now );
        $submission->store;

        # We may be receiving a submitted form due to the user having
        # changed request material type, so we just need to go straight
        # back to the form, the type has been changed in the params
        if ( defined $other->{change_type} ) {
            delete $other->{change_type};
            return {
                cwd            => dirname(__FILE__),
                error          => 0,
                status         => '',
                message        => '',
                method         => 'edititem',
                stage          => 'form',
                value          => $params,
                field_map      => $self->fieldmap_sorted,
                field_map_json => to_json( $self->fieldmap )
            };
        }

        # ...Populate Illrequestattributes
        # generate $request_details
        # We do this with a 'dump all and repopulate approach' inside
        # a transaction, easier than catering for create, update & delete
        my $dbh    = C4::Context->dbh;
        my $schema = Koha::Database->new->schema;
        $schema->txn_do(
            sub {
                # Delete all existing attributes for this request
                $dbh->do(
                    q|
                    DELETE FROM illrequestattributes WHERE illrequest_id=?
                |, undef, $submission->id
                );

                # Insert all current attributes for this request
                my $fields = $self->fieldmap;

                foreach my $field ( %{$other} ) {
                    my $value = $other->{$field};
                    if ( $other->{$field}
                        && length $other->{$field} > 0 )
                    {
                        my @bind = ( $submission->id, 'PluginBackend', $field, $value, 0 );
                        $dbh->do(
                            q|
                            INSERT INTO illrequestattributes
                            (illrequest_id, backend, type, value, readonly) VALUES
                            (?, ?, ?, ?, ?)
                        |, undef, @bind
                        );
                    }
                }

                # Now insert our core equivalents, if an equivalently named Rapid field
                # doesn't already exist
                foreach my $field ( %{$other} ) {
                    my $value = $other->{$field};
                    if (   $other->{$field}
                        && $fields->{$field}->{ill}
                        && length $other->{$field} > 0
                        && !$fields->{ $fields->{$field}->{ill} } )
                    {
                        my @bind = ( $submission->id, $fields->{$field}->{ill}, $value, 0 );
                        $dbh->do(
                            q|
                            INSERT INTO illrequestattributes
                            (illrequest_id, type, value, readonly) VALUES
                            (?, ?, ?, ?)
                        |, undef, @bind
                        );
                    }
                }
            }
        );

        # Create response
        return {
            cwd            => dirname(__FILE__),
            error          => 0,
            status         => '',
            message        => '',
            method         => 'create',
            stage          => 'commit',
            next           => 'illview',
            value          => $params,
            field_map      => $self->fieldmap_sorted,
            field_map_json => to_json( $self->fieldmap )
        };
    }
}

=head3 do_join

If a field should be joined with another field for storage as a core
value or display, then do it

=cut

sub do_join {
    my ( $self, $field, $metadata ) = @_;
    my $fields = $self->fieldmap;
    my $value  = $metadata->{$field};
    my $join   = $fields->{$field}->{join};
    if ( $join && $metadata->{$join} && $value ) {
        my @to_join = ( $value, $metadata->{$join} );
        $value = join " ", @to_join;
    }
    return $value;
}

=head3 mark_completed

Mark a request as completed (status = COMP).

=cut

sub mark_completed {
    my ($self) = @_;
    $self->status('COMP')->store;
    $self->completed( dt_from_string() )->store;
    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'mark_completed',
        stage   => 'commit',
        next    => 'illview',
    };
}

=head3 ready

Mark this request as 'READY'

=cut

sub ready {
    my ( $self, $params ) = @_;
    my $other = $params->{other};

    my $request = Koha::Illrequests->find( $other->{illrequest_id} );

    $request->status('READY');
    $request->updated( DateTime->now );
    $request->store;

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'ready',
        stage   => 'commit',
        next    => 'illview',
        value   => $params,
    };
}

=head3 mark_new

Mark this request as 'NEW'

=cut

sub mark_new {
    my ( $self, $params ) = @_;
    my $other = $params->{other};

    my $request = Koha::Illrequests->find( $other->{illrequest_id} );

    $request->status('NEW');
    $request->updated( DateTime->now );
    $request->store;

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'mark_new',
        stage   => 'commit',
        next    => 'illview',
        value   => $params,
    };
}

=head3 migrate

Migrate a request into or out of this backend

=cut

sub migrate {
    my ( $self, $params ) = @_;
    my $other = $params->{other};

    my $stage = $other->{stage};
    my $step  = $other->{step};

    my $request = Koha::Illrequests->find( $other->{illrequest_id} );

    # Record where we're migrating from, so we can log that
    my $migrating_from = $request->backend;

    # Cancel the original if appropriate
    if ( $request->status eq 'REQ' ) {
        $request->_backend_capability( 'cancel', { request => $request } );

        # The orderid is no longer applicable
        $request->orderid(undef);
    }
    $request->status('MIG');
    $request->backend( $self->name );
    $request->updated( DateTime->now );
    $request->store;

    # Handle metadata conversion here if needed

    # Log that the migration took place if needed

    return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'migrate',
        stage   => 'commit',
        next    => 'illview',
        value   => $params,
    };

}

=head3 _validate_metadata

Ensure the metadata we've got conforms to the order
API specification

=cut

sub _validate_metadata {
    my ( $self, $metadata ) = @_;
    return 1;
}

=head3 create_submission

Create a local submission

=cut

sub create_submission {
    my ( $self, $params ) = @_;

    my $patron = Koha::Patrons->find( $params->{other}->{borrowernumber} );

    my $request = $params->{request};
    $request->borrowernumber( $patron->borrowernumber );
    $request->branchcode( $params->{other}->{branchcode} );
    $request->status('NEW');
    $request->batch_id(
        $params->{other}->{ill_batch_id} ? $params->{other}->{ill_batch_id} : $params->{other}->{batch_id} );
    $request->backend( $self->name );
    $request->placed( DateTime->now );
    $request->updated( DateTime->now );

    $request->store;

    $params->{other}->{type} = 'article';

    # Store the request attributes
    $self->create_illrequestattributes( $request, $params->{other} );

    # Now store the core equivalents
    $self->create_illrequestattributes( $request, $params->{other}, 1 );

    return $request;
}

=head3

Store metadata for a given request

=cut

sub create_illrequestattributes {
    my ( $self, $request, $metadata, $core ) = @_;

    # Get the canonical list of metadata fields
    my $fields = $self->fieldmap;

    # Get any existing illrequestattributes for this request,
    # so we can avoid trying to create duplicates
    my $existing_attrs = $request->illrequestattributes->unblessed;
    my $existing_hash  = {};
    foreach my $a ( @{$existing_attrs} ) {
        $existing_hash->{ lc $a->{type} } = $a->{value};
    }

    # Iterate our list of fields
    foreach my $field ( keys %{$fields} ) {
        if (
            # If we're working with core metadata, check if this field
            # has a core equivalent
            ( ( $core && $fields->{$field}->{ill} ) || !$core )
            && $metadata->{$field}
            && length $metadata->{$field} > 0
            )
        {
            my $att_type  = $core ? $fields->{$field}->{ill} : $field;
            my $att_value = $metadata->{$field};

            # If core, we might need to join
            if ($core) {
                $att_value = $self->do_join( $field, $metadata );
            }

            # If it doesn't already exist for this request
            if ( !exists $existing_hash->{ lc $att_type } ) {
                my $data = {
                    illrequest_id => $request->illrequest_id,

                    # Check required for compatibility with installations before bug 33970
                    backend  => "PluginBackend",
                    type     => $att_type,
                    value    => $att_value,
                    readonly => 0
                };
                Koha::Illrequestattribute->new($data)->store;
            }
        }
    }
}

=head3 create_request

Take a previously created submission and request it

=cut

sub create_request {
    my ( $self, $submission ) = @_;

    # create logic here

    # Add the supplier ID to the orderid field if needed

    # Update the submission status
    $submission->status('REQ')->store;

    # Add log here if needed

    return { success => 1 };

}

=head3 confirm

A wrapper around create_request allowing us to
provide the "confirm" method required by
the status graph

=cut

sub confirm {
    my ( $self, $params ) = @_;

    my $return = $self->create_request( $params->{request} );

    my $return_value = {
        cwd     => dirname(__FILE__),
        error   => 0,
        status  => "",
        message => "",
        method  => "create",
        stage   => "commit",
        next    => "illview",
        value   => {},
        %{$return}
    };

    return $return_value;
}

=head3 backend_metadata

Required method utilized by I<Koha::Illrequest> metadata

=cut

sub backend_metadata {
    my ( $self, $request ) = @_;
    my $attrs       = $request->illrequestattributes;
    my $metadata    = {};
    my @ignore      = ( 'requested_partners', 'type', 'type_disclaimer_value', 'type_disclaimer_date' );
    my $core_fields = _get_core_fields();
    while ( my $attr = $attrs->next ) {
        my $type = $attr->type;
        if ( !grep { $_ eq $type } @ignore ) {
            my $name;
            $name = $core_fields->{$type} || ucfirst($type);
            $metadata->{$name} = $attr->value;
        }
    }
    return $metadata;
}

=head3 _get_core_fields

Return a hashref of core fields

=cut

sub _get_core_fields {
    return {
        article_author  => 'Article author',
        article_title   => 'Article title',
        associated_id   => 'Associated ID',
        author          => 'Author',
        chapter_author  => 'Chapter author',
        chapter         => 'Chapter',
        conference_date => 'Conference date',
        doi             => 'DOI',
        editor          => 'Editor',
        institution     => 'Institution',
        isbn            => 'ISBN',
        issn            => 'ISSN',
        issue           => 'Issue',
        item_date       => 'Date',
        pages           => 'Pages',
        pagination      => 'Pagination',
        paper_author    => 'Paper author',
        paper_title     => 'Paper title',
        part_edition    => 'Part / Edition',
        publication     => 'Publication',
        published_date  => 'Publication date',
        published_place => 'Place of publication',
        publisher       => 'Publisher',
        sponsor         => 'Sponsor',
        title           => 'Title',
        type            => 'Type',
        venue           => 'Venue',
        volume          => 'Volume',
        year            => 'Year'
    };
}

=head3 capabilities

    $capability = $backend->capabilities($name);

Return the sub implementing a capability selected by NAME, or 0 if that
capability is not implemented.

=cut

sub capabilities {
    my ( $self, $name ) = @_;
    my $capabilities = {

        # View and manage a request
        illview => sub { illview(@_); },

        # Migrate
        migrate => sub { $self->migrate(@_); },

        # Return whether we can create the request
        # i.e. the create form has been submitted
        can_create_request => sub { _can_create_request(@_) },

        # This is required for compatibility
        # with Koha versions prior to bug 33716
        should_display_availability => sub { _can_create_request(@_) },

        provides_batch_requests => sub { return 1; },

        # We can create ILL requests with data passed from the API
        create_api => sub { $self->create_api(@_) }
    };

    return $capabilities->{$name};
}

=head3 _can_create_request

Given the parameters we've been passed, should we create the request

=cut

sub _can_create_request {
    my ($params) = @_;
    return ( defined $params->{'stage'} ) ? 1 : 0;
}

=head3 status_graph

ILL request statuses specific to this backend

=cut

sub status_graph {
    return {
        EDITITEM => {
            prev_actions   => ['NEW'],
            id             => 'EDITITEM',
            name           => 'Edited item metadata',
            ui_method_name => 'Edit item metadata',
            method         => 'edititem',
            next_actions   => [],
            ui_method_icon => 'fa-edit',
        },
        ERROR => {
            prev_actions   => [],
            id             => 'ERROR',
            name           => 'Request error',
            ui_method_name => 0,
            method         => 0,
            next_actions   => [ 'MARK_NEW', 'COMP', 'EDITITEM', 'STANDBY', 'READY', 'MIG', 'KILL' ],
            ui_method_icon => 0,
        },
        READY => {
            prev_actions   => [ 'ERROR', 'STANDBY' ],
            id             => 'READY',
            name           => 'Request ready',
            ui_method_name => 'Mark request READY',
            method         => 'ready',
            next_actions   => [],
            ui_method_icon => 'fa-check',
        },
        NEW => {
            prev_actions   => [],
            id             => 'NEW',
            name           => 'New request',
            ui_method_name => 'New request',
            method         => 'create',
            next_actions   => [ 'GENREQ', 'KILL', 'MIG', 'EDITITEM' ],
            ui_method_icon => 'fa-plus'
        },
    };
}

sub name {
    return "PluginBackend";
}

=head3 _fail

=cut

sub _fail {
    my @values = @_;
    foreach my $val (@values) {
        return 1 if ( !$val or $val eq '' );
    }
    return 0;
}

=head3 find_illrequestattribute

=cut

sub find_illrequestattribute {
    my ( $self, $attributes, $prop ) = @_;
    foreach my $attr ( @{$attributes} ) {
        if ( $attr->{type} eq $prop ) {
            return 1;
        }
    }
}

=head3 create_api

Optional method if this backend supports ILL requests batches
Utilized by I<Koha/REST/V1/Illrequests>

=cut

sub create_api {
    my ( $self, $body, $request ) = @_;

    # logic here

    return 1;
}

=head3 fieldmap_sorted

Return the fieldmap sorted by "order"
Note: The key of the field is added as a "key"
property of the returned hash

=cut

sub fieldmap_sorted {
    my ($self) = @_;

    my $fields = $self->fieldmap;

    my @out = ();

    foreach my $key ( sort { $fields->{$a}->{position} <=> $fields->{$b}->{position} } keys %{$fields} ) {
        my $el = $fields->{$key};
        $el->{key} = $key;
        push @out, $el;
    }

    return \@out;
}

sub fieldmap {
    return {
        title => {
            exclude        => 1,
            type           => "string",
            label          => "Journal title",
            ill            => "title",
            api_max_length => 255,
            position       => 0
        },
        atitle => {
            exclude        => 1,
            type           => "string",
            label          => "Article title",
            ill            => "article_title",
            api_max_length => 255,
            position       => 1
        },
        article_title => {
            exclude        => 1,
            type           => "string",
            label          => "Article title",
            ill            => "article_title",
            api_max_length => 255,
            no_submit      => 1,
            position       => 1
        },
        aufirst => {
            type           => "string",
            label          => "Author's first name",
            ill            => "article_author",
            api_max_length => 50,
            position       => 2,
            join           => "aulast"
        },
        aulast => {
            type           => "string",
            label          => "Author's last name",
            api_max_length => 50,
            position       => 3
        },
        volume => {
            type           => "string",
            label          => "Volume number",
            ill            => "volume",
            api_max_length => 50,
            position       => 4
        },
        issue => {
            type           => "string",
            label          => "Journal issue number",
            ill            => "issue",
            api_max_length => 50,
            position       => 5
        },
        date => {
            type           => "string",
            ill            => "year",
            api_max_length => 50,
            position       => 7,
            label          => "Item publication date"
        },
        pages => {
            type           => "string",
            label          => "Pages in journal",
            ill            => "pages",
            api_max_length => 50,
            position       => 8
        },
        spage => {
            type           => "string",
            label          => "First page of article in journal",
            ill            => "spage",
            api_max_length => 50,
            position       => 8
        },
        epage => {
            type           => "string",
            label          => "Last page of article in journal",
            ill            => "epage",
            api_max_length => 50,
            position       => 9
        },
        doi => {
            type           => "string",
            label          => "DOI",
            ill            => "doi",
            api_max_length => 96,
            position       => 10
        },
        pubmedid => {
            type           => "string",
            label          => "PubMed ID",
            ill            => "pubmedid",
            api_max_length => 16,
            position       => 11
        },
        isbn => {
            type           => "string",
            label          => "ISBN",
            ill            => "isbn",
            api_max_length => 50,
            position       => 12
        },
        issn => {
            type           => "string",
            label          => "ISSN",
            ill            => "issn",
            api_max_length => 50,
            position       => 13
        },
        eissn => {
            type           => "string",
            label          => "EISSN",
            ill            => "eissn",
            api_max_length => 50,
            position       => 14
        },
        orderdateutc => {
            type      => "string",
            label     => "Order date UTC",
            exclude   => 1,
            no_submit => 1,
            position  => 99
        },
        statusdateutc => {
            type      => "string",
            label     => "Status date UTC",
            exclude   => 1,
            no_submit => 1,
            position  => 99
        },
        author => {
            type      => "string",
            label     => "Author",
            ill       => "author",
            exclude   => 1,
            no_submit => 1,
            position  => 99
        },
        year => {
            type      => "string",
            ill       => "year",
            exclude   => 1,
            label     => "Year",
            no_submit => 1,
            position  => 99
        },
        type => {
            type      => "string",
            ill       => "type",
            exclude   => 1,
            label     => "Type",
            no_submit => 1,
            position  => 99
        },
    };
}

=head3 _validate_borrower

aux function

=cut

sub _validate_borrower {

    # Perform cardnumber search.  If no results, perform surname search.
    # Return ( 0, undef ), ( 1, $brw ) or ( n, $brws )
    my ($input) = @_;
    my $patrons = Koha::Patrons->new;
    my ( $count, $brw );
    my $query = { cardnumber => $input };

    my $brws = $patrons->search($query);
    $count = $brws->count;
    my @criteria = qw/ surname userid firstname end /;
    while ( $count == 0 ) {
        my $criterium = shift @criteria;
        return ( 0, undef ) if ( "end" eq $criterium );
        $brws  = $patrons->search( { $criterium => $input } );
        $count = $brws->count;
    }
    if ( $count == 1 ) {
        $brw = $brws->next;
    } else {
        $brw = $brws;    # found multiple results
    }
    return ( $count, $brw );
}

=head3 ill_backend

Required method for 'ill_backend' I<Koha::Plugin> category

=cut

sub ill_backend {
    my ( $class, $args ) = @_;
    return 'PluginBackend';
}

1;
