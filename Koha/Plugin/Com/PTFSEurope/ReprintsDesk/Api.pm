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
use JSON qw( decode_json );

use Koha::Logger;
use Koha::Patrons;
use Mojo::Base 'Mojolicious::Controller';
use Koha::Plugin::Com::PTFSEurope::ReprintsDesk;

sub PlaceOrder2 {
    my $c = shift->openapi->valid_input or return;

    my $credentials = _get_credentials();

    my $body = $c->validation->param('body');

    my $metadata = $body->{metadata} || {};
    $metadata->{ordertypeid} = $config->{ordertypeid};
    $metadata->{deliverymethodid} = $config->{deliverymethodid};

    # Base request including passed metadata and credentials
    my $req = {
        input => {
            ClientAppName => "Koha Reprints Desk client",
            %{$credentials},
            %{$metadata}
        }
    };

    my $client = _build_client('PlaceOrder2');

    my $response = $client->($req);

    return $c->render(
        status => 200,
        openapi => {
            result => $response->{parameters}->{InsertRequestResult},
            errors => []
        }
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

sub _make_request {
    my ($client, $req, $response_element) = @_;

    my $credentials = _get_credentials();

    my $to_send = {
        %{$req},
        UserCredentials => {
            %{$credentials}
        }
    };

    my ($response, $trace) = $client->($to_send);
    print STDERR Dumper $trace->request;
    my $result = $response->{parameters}->{$response_element} || {};
    my $errors = $response->{error} ? [ $response->{error}->{reason} ] : [];

    return {
        result => $result,
        errors => $errors
    };
}

sub _build_client {
    my ($operation) = @_;

    open my $wsdl_fh, "<", dirname(__FILE__) . "/reprintsdesk.wsdl" || die "Can't open file $!";
    my $wsdl_file = do { local $/; <$wsdl_fh> };
    my $wsdl = XML::Compile::WSDL11->new($wsdl_file);

    my $client = $wsdl->compileClient(
        operation => $operation,
        port      => "MainSoap12"
    );

    return $client;
}

sub _get_credentials {

    my $plugin = Koha::Plugin::Com::PTFSEurope::ReprintsDesk->new();
    my $config = decode_json($plugin->retrieve_data("reprintsdesk_config") || {});

    my $doc = XML::LibXML::Document->new('1.0', 'UTF-8');
    my %data = (
        _doc => $doc,
        UserName => $doc->createCDATASection($config->{username}),
        Password => $doc->createCDATASection($config->{password}),
    );

    return \%data;
}

1;