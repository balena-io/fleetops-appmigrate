# fleetops-appmigrate

⚠️ Work in progress tooling. ⚠️

This repository includes tooling to move batches of devices on balenaCloud from one application to another, while also migrating the volume data from one of the application's original volumes, to one of the volumes in the new application. Thus it is most useful to migrate from a non-multicontainer application (single default `resin-data` volume) to a multicontainer application.

The aim of this tooling to be a stopgap solution while this functionality is not provided directly in balenaCloud. Once it is an actual production feature, this repository will be deprecated.

## Usage

Clone this repository on your local development machine, where you have [balenaCLI][balenaCLI] available. Log in to your account with `balena login`.

In this folder, copy `params.example` to a file called `params`, and fill out at least the `TOKEN` variable, and the `TARGET_APP_ID` variable:

* you can get a sutaible session token to add as `TOKEN`, in your balenaCloud [preferences page][preferences]. In the file you should have `TOKEN="eyJhbG...[snip]..."` (here the actual token was shortened for display's purposes).
* the `TARGET_APP_ID` value is the numerical value of the application you are planning to move the device to. You can get from the dashboard, for example by navigating to the application's summary page, and checking the URL. If the URL is for example `https://dashboard.balena-cloud.com/apps/12345/devices`, then your `TARGET_APP_ID=12345`
* the volumes where data is moved from and moved to are optional, in some circumstances:
  * if using a single-container application (your original application has no `docker-compose.yml` file, for example), the default `resin-data` volume can be used automatically. If that's not the right volume, then you should set `FROM_VOLUME=` to the correct volume name, such as `FROM_VOLUME="my-volume"`
  * if there's only a single volume in the target application, and `TO_VOLUME` is not set to a value, that single volume will be used automatically. If you want to force a specific volume, set `TO_VOLUME=` to solve value, such as `TO_VOLUME="another-volume"`. That volume has to exist in the target application for the migration to work.

Once `params` is set up, get a list of devices you would like to move/migrate between the apps, and add their UUIDs into a file called `batch`, one UUID per line.

To run the updates on them, trigger `./run.sh` which will create a migrator script from the input of `params` and `appmigrator_template.sh`, and then go through the devices provided in `batch` to run the script on each of them. Rerunning `./run.sh` skips any device that is found to be successuflly migrated in the process log. Unsuccessful attempts have logs shown for debugging purposes, also on each of the device at `/mnt/data/appmigrate/`.

For the migration to work properly, the device needs to have enough space available on the data partition to make a copy of the volume, and make a compressed archive of that copy, thus have enough free space for 1x (minimum) - 2x (worst case) of the current volume data that is migrated.

## Future

There are some future features that we are considering adding, but not currently supported

* allowing moving to a specific release of the new target application (with release pinning)
* multiple volume migration

[balenaCLI]: https://github.com/balena-io/balena-cli/#installation "balenaCLI GitHub repository"
[preferences]: https://dashboard.balena-cloud.com/preferences/access-tokens "balenaCloud preferences page"