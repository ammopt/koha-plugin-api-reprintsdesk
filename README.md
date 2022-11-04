# koha-plugin-api-reprintsdesk
This plugin provides Koha API routes enabling access to the Reprints Desk API. It can be used in conjunction with the [Reprints Desk ILL backend](https://github.com/PTFS-Europe/koha-ill-reprintsdesk) but it can be used in isolation if a authenticated JSON API to Reprints Desk is required.

This is a plugin for [Koha](https://koha-community.org/) that allows you to make queries to the [Reprints Desk API](https://wwwstg.reprintsdesk.com/webservice/main.asmx?wsdl) via a locally provided JSON API

## Getting Started

This plugin requires the following Perl modules:

[XML::Smart](https://metacpan.org/pod/XML::Smart)

[XML::Compile](https://metacpan.org/pod/XML::Compile)

[XML::Compile::SOAP](https://metacpan.org/pod/XML::Compile::SOAP)

[XML::Compile::WSDL11](https://metacpan.org/pod/XML::Compile::WSDL11)

[XML::Compile::SOAP11](https://metacpan.org/pod/XML::Compile::SOAP11)

[XML::Compile::SOAP12](https://metacpan.org/pod/XML::Compile::SOAP12)

[XML::Compile::Transport::SOAPHTTP](https://metacpan.org/dist/XML-Compile-SOAP/view/lib/XML/Compile/Transport/SOAPHTTP.pod)

[XML::Smart](https://metacpan.org/pod/XML::Smart)

Clone this repo and create the .kpz file: `zip -r koha-plugin-api-reprintsdesk.kpz Koha/`

The plugin system needs to be turned on by a system administrator.

To set up the Koha plugin system you must first make some changes to your install.

Change `<enable_plugins>0<enable_plugins>` to `<enable_plugins>1</enable_plugins>` in your `koha-conf.xml` file
Confirm that the path to `<pluginsdir>` exists, is correct, and is writable by the web server.
Restart your webserver.
Finally, on the "Koha Administration" page you will see the "Manage Plugins" option, select this to access the Plugins page.

### Installing

Once your Koha has plugins turned on, as detailed above, installing the plugin is then a case of selecting the "Upload plugin" 
button on the Plugins page and navigating to the .kpz file you downloaded

### Configuration

**The plugin requires configuration prior to usage**. To configure the plugin, select the "Actions" button listed by the plugin in the "Plugins" page, then select "Configure". On the configure page, you are required to supply your Reprints Desk API credentials, then click "Save configuration"

## Authors

* Andrew Isherwood
