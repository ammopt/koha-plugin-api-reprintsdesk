# koha ILL backend plugin
Example ILL backend plugin

# Converting old ILL backend into a plugin
Use this project as a guideline:
* Create your plugin, copy the contents from your old ILL backend into the plugin folder.
* Copy the code from your old Base.pm file into the plugin file named after the plugin.
* Rename the old backend 'metadata' method to 'backend_metadata'.
* Rename the old backend 'new' method to 'new_backend'.
* Add the required plugin methods (new, install, upgrade, uninstall)
* You should be good to go!