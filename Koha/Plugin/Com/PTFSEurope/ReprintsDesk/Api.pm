package Koha::Plugin::Com::PTFSEurope::ReprintsDesk::Api;

use Modern::Perl;
use strict;
use warnings;

use File::Basename qw( dirname );
use XML::LibXML;
use XML::Compile;
use XML::Compile::WSDL11;
use XML::Compile::SOAP12;
use XML::Compile::SOAP11;
use XML::Compile::Transport::SOAPHTTP;
use XML::Smart;
use JSON qw( decode_json );

use Koha::Logger;
use Koha::Patrons;
use Mojo::Base 'Mojolicious::Controller';
use Koha::Plugin::Com::PTFSEurope::ReprintsDesk;

sub PlaceOrder2 {
    my $c = shift->openapi->valid_input or return;

    my $body = $c->validation->param('body');

    my $plugin = Koha::Plugin::Com::PTFSEurope::ReprintsDesk->new();
    my $config = decode_json($plugin->retrieve_data("reprintsdesk_config") || {});

    my $metadata = $body || {};

    $metadata->{orderdetail}->{ordertypeid} = $config->{ordertypeid};
    $metadata->{orderdetail}->{deliverymethodid} = $config->{deliverymethodid};
    $metadata->{user}->{billingreference} = $config->{billingreference};

    my $processinginstructions = _get_processing_instructions();
    $metadata->{processinginstructions} = ${$processinginstructions}[0];

    my $customerreferences = _get_customer_references();
    $metadata->{customerreferences} = ${$customerreferences}[0];

    # Some deliveryprofile fields may need completing with fallback values from the config
    # if the requesting borrower doesn't have them populated.
    my $check_populated_delivery_profile = [ 'address1', 'city', 'zip', 'phone', 'email' ];
    # If the config says we should use borrower properties for deliveryprofile values
    # use as many as we can, these should have come in the payload
    _populate_missing_properties(
        $c,
        $metadata,
        $config,
        $check_populated_delivery_profile,
        'deliveryprofile',
        'Missing deliveryprofile data required to place a request'
    );

    # Some user fields may need completing with fallback values from the config
    # if the requesting borrower doesn't have them populated. username is annoying because
    # it needs to be populated with the email field, so we convey that here
    my $check_populated_user = [ 'email', { 'username' => 'email' } ];
    # If the config says we should use borrower properties for deliveryprofile values
    # use as many as we can, these should have come in the payload
    _populate_missing_properties(
        $c,
        $metadata,
        $config,
        $check_populated_user,
        'user',
        'Missing user data required to place a request'
    );


    # Manually check statename & statecode since they need special treatment depending on
    # countrycode
    # 
    # First we use the country code defined in the config, it is very unlikely
    # the value specified in the payload will be an ISO 3166 two character
    # country code and we have to supply something.
    my $cc = $config->{countrycode};
    $metadata->{deliveryprofile}->{countrycode} = $cc;

    if ($cc eq 'US') {
        # If the borrower doesn't have a two character state provided
        if (!$metadata->{deliveryprofile}->{state} || scalar $metadata->{deliveryprofile}->{state} != 2) {
            # ...attempt to use the one from the config
            if ($config->{statecode}) {
                $metadata->{deliveryprofile}->{statecode} = $config->{statecode};
            } else {
                return $c->render(
                    status => 400,
                    openapi => {
                        result => {},
                        errors => [{ message => "Country code 'US' selected but no state code provided" }]
                    }
                );
            }
        } else {
            $metadata->{deliveryprofile}->{statecode} = $metadata->{deliveryprofile}->{state};
        }
        # Despite not being required, the Reprints Desk API will complain if we don't include a
        # statename element, so here it is...
        $metadata->{deliveryprofile}->{statename} = ".";
    } else {
        # If the borrower doesn't have a state name provided
        if (!$metadata->{deliveryprofile}->{state}) {
            # ...attempt to use the one from the config
            if ($config->{statename}) {
                $metadata->{deliveryprofile}->{statename} = $config->{statename};
            } else {
                return $c->render(
                    status => 400,
                    openapi => {
                        result => {},
                        errors => [{ message => "Non-US country code 'US' selected but no state name provided" }]
                    }
                );
            }
        } else {
            $metadata->{deliveryprofile}->{statename} = $metadata->{deliveryprofile}->{state};
        }
        # Despite not being required, the Reprints Desk API will complain if we don't include a
        # statecode element, so here it is...
        $metadata->{deliveryprofile}->{statecode} = ".";
    }

    # Despite not being required, the Reprints Desk API will complain if we don't include a
    # fax element, so include one if it's not already there
    if (!defined $metadata->{deliveryprofile}->{fax} || length $metadata->{deliveryprofile}->{fax} == 0) {
        $metadata->{deliveryprofile}->{fax} = '.';
    }

    my $client = _build_client('Order_PlaceOrder2');

    my $smart = XML::Smart->new;
    $smart->{wrapper} = { xmlNode => { order => $metadata  } };

    # All orderdetail, user, deliveryprofile properties should be elements
    # So we need to force that
    # This also ensures we have elements for each as seemingly the API will
    # complain if some non-required elements are not present
    my $to_tag = {
        'orderdetail'     => ['deliverymethodid', 'ordertypeid', 'comment', 'aulast', 'aufirst', 'issn', 'eissn', 'isbn', 'title', 'atitle', 'volume', 'issue', 'spage', 'epage', 'pages', 'date', 'doi', 'pubmedid'],
        'user'            => ['firstname', 'lastname', 'email', 'username', 'billingreference'],
        'deliveryprofile' => ['firstname', 'lastname', 'companyname', 'address1', 'address2', 'city', 'statecode', 'statename', 'zip', 'countrycode', 'email', 'phone', 'fax']
    };
    foreach my $tag_key(keys %{$to_tag}) {
        foreach my $key(@{$to_tag->{$tag_key}}) {
            $smart->{order}->{$tag_key}->{$key}->set_tag;
        }
    }

    # orderdetail properties that should be CDATA
    foreach my $cdata(@{$to_tag->{orderdetail}}) {
        $smart->{wrapper}->{xmlNode}->{order}->{orderdetail}->{$cdata}->set_cdata;
    }

    # user properties that should be CDATA
    foreach my $cdata(@{$to_tag->{user}}) {
        $smart->{wrapper}->{xmlNode}->{order}->{user}->{$cdata}->set_cdata;
    }

    # deliveryprofile properties that should be CDATA
    foreach my $cdata(@{$to_tag->{deliveryprofile}}) {
        $smart->{wrapper}->{xmlNode}->{order}->{deliveryprofile}->{$cdata}->set_cdata;
    }

    $smart->{wrapper}->{xmlNode}->{order}->{xmlns} = '';

    my $dom = XML::LibXML->load_xml(string => $smart->data(noheader => 1, nometagen => 1));
    my @nodes = $dom->findnodes('/root/wrapper/xmlNode');

    my $response = _make_request($client, { xmlNode => $nodes[0] }, 'Order_PlaceOrder2Response');

    my $code = scalar @{$response->{errors}} > 0 ? 500 : 200;

    return $c->render(
        status => $code,
        openapi => $response
    );
}

sub GetOrderInfo {
    my $c = shift->openapi->valid_input or return;

    my $client = _build_client('Order_GetOrderInfo');

    my $body = $c->validation->param('body');

    my $metadata = $body || {};

    my $smart = XML::Smart->new;
    $smart->{wrapper} = { inputXmlNode => { input => $metadata  } };

    $smart->{wrapper}->{inputXmlNode}->{input}->{schemaversionid} = '1';
    $smart->{wrapper}->{inputXmlNode}->{input}->{orderid}->set_tag;
    $smart->{wrapper}->{inputXmlNode}->{input}->{xmlns} = '';

    my $dom = XML::LibXML->load_xml(string => $smart->data(noheader => 1, nometagen => 1));
    my @nodes = $dom->findnodes('/wrapper/inputXmlNode');

    my $response = _make_request($client, { inputXmlNode => $nodes[0] }, 'Order_GetOrderInfoResponse');


    my $code = scalar @{$response->{errors}} > 0 ? 500 : 200;

    return $c->render(
        status => $code,
        openapi => $response
    );

}

sub NotYetDownloaded {
    my $c = shift->openapi->valid_input or return;

    my $client = _build_client('Orders_NotYetDownloaded');

    my $response = _make_request($client, { }, 'Order_GetOrderInfoResponse');
    my $code = scalar @{$response->{errors}} > 0 ? 500 : 200;

    return $c->render(
        status => $code,
        openapi => $response
    );


}

sub Account_GetIntendedUses {
    my $c = shift->openapi->valid_input or return;

    my $client = _build_client('Account_GetIntendedUses');

    my $response = _make_request($client, {}, 'Account_GetIntendedUsesResult');

    return $c->render(
        status => 200,
        openapi => $response
    );
}


sub Test_Credentials {

    my $c = shift->openapi->valid_input or return;

    my $client = _build_client('Test_Credentials');

    my $response = _make_request($client, {}, 'Test_CredentialsResult');

    return $c->render(
        status => 200,
        openapi => $response
    );
}


sub _populate_missing_properties {
    my ($c, $metadata, $config, $check_populated, $section, $error) = @_;

    for my $element(@{$check_populated}) {
        # We may be dealing with a single element anonymous hash, in which case,
        # key is the metadata property name the value is the config property name
        my $metadata_name;
        my $config_name;
        if (ref $element eq 'HASH' ) {
            my @k = keys %{$element};
            $metadata_name = $k[0];
            $config_name = $element->{$metadata_name};
        } else {
            $metadata_name = $element;
            $config_name = $element;
        }
        if (defined $config->{use_borrower_details}) {
            if (!$metadata->{$section}->{$metadata_name}) {
                # The borrower doesn't have the necessary bit of info
                # attempt to use the value from the config
                if ($config->{$config_name}) {
                    # The config has the required value
                    $metadata->{$section}->{$metadata_name} = $config->{$config_name};
                } else {
                    # Neither the borrower or the config have the required value
                    return $c->render(
                        status => 400,
                        openapi => {
                            result => {},
                            errors => [ { message => "$error: $metadata_name" } ]
                        }
                    );
                }
            }
        } else {
            if ($config->{$config_name}) {
                # The config has the required value
                $metadata->{$section}->{$metadata_name} = $config->{$config_name};
            } else {
                # The config does not have the required value
                return $c->render(
                    status => 400,
                    openapi => {
                        result => {},
                        errors => [ { message => "$error $metadata_name" } ]
                    }
                );
            }
        }
    }
}


sub _make_request {
    my ($client, $req, $response_element) = @_;

    my $credentials = _get_credentials();

    my $to_send = {%{$req}, UserCredentials => {%{$credentials}}};

    my ($response, $trace) = $client->($to_send);

    my $result = $response->{parameters} || {};
    my $errors = $response->{error} ? [ { message => $response->{error}->{reason} } ] : [];

    return {
        result => $result,
        errors => $errors
    };
}


sub _build_client {
    my ($operation) = @_;

    open my $wsdl_fh, "<", dirname(__FILE__) . "/reprintsdesk.wsdl" || die "Can't open file $!";
    my $wsdl_file = do { local $/; <$wsdl_fh> };
    my $wsdl = XML::Compile::WSDL11->new(
        $wsdl_file,
        # The API has a fit if some of the elements are correctly prefixed
        # so override the prefixing.
        prefixes => { '' => 'http://reprintsdesk.com/webservices/' }
    );

    my $client = $wsdl->compileClient(
        operation => $operation,
        port      => "MainSoap"
    );

    return $client;
}


sub _get_credentials {
    my $plugin = Koha::Plugin::Com::PTFSEurope::ReprintsDesk->new();
    my $config = decode_json($plugin->retrieve_data("reprintsdesk_config") || {});

    my $doc = XML::LibXML::Document->new('1.0', 'UTF-8');
    my %data = (
        UserName => $doc->createCDATASection($config->{username}),
        Password => $doc->createCDATASection($config->{password}),
    );

    return \%data;
}

sub _get_processing_instructions {
    my $plugin = Koha::Plugin::Com::PTFSEurope::ReprintsDesk->new();
    my $config = decode_json($plugin->retrieve_data("reprintsdesk_config") || {});

    my @processinginstructions = ();

    if ($config->{processinginstructions}) {
        my @pairs = split '_', $config->{processinginstructions};
        foreach my $pair(@pairs) {
            my ($key, $value) = split ":", $pair;
            push @processinginstructions, { processinginstruction => { id => $key, value => $value } };
        }
    }

    return \@processinginstructions;
}

sub _get_customer_references {
    my $plugin = Koha::Plugin::Com::PTFSEurope::ReprintsDesk->new();
    my $config = decode_json($plugin->retrieve_data("reprintsdesk_config") || {});

    my @customerreferences = ();

    if ($config->{customerreferences}) {
        my @pairs = split '_', $config->{customerreferences};
        foreach my $pair(@pairs) {
            my ($key, $value) = split ":", $pair;
            push @customerreferences, { customerreference => { id => $key, value => $value } };
        }
    }

    return \@customerreferences;
}

1;