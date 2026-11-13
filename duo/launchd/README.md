# Start the gate at login (optional)

`duo.sh ensure` starts the gate when the service is wanted (after `duo.sh start`, until `duo.sh stop`) and the gate is
not running. A LaunchAgent can run it at login and every two minutes. The gate then loads the pair at the first
request. Nothing is loaded at login by itself.

Install, on the Mac that runs `duo.sh` (no sudo; a per-user agent):

```sh
mkdir -p ~/Library/LaunchAgents
duo/duo.sh launchagent > ~/Library/LaunchAgents/local.strata-duo.ensure.plist
plutil -lint ~/Library/LaunchAgents/local.strata-duo.ensure.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.strata-duo.ensure.plist
```

Remove:

```sh
launchctl bootout gui/$(id -u)/local.strata-duo.ensure
rm ~/Library/LaunchAgents/local.strata-duo.ensure.plist
```

`duo.sh launchagent` fills `strata-duo.plist.template` with this checkout's paths (the script, the settings file, the
log `run/agent.log`). If you move the checkout, print and install it again. `LAUNCHD_LABEL` in `duo.conf` changes the
label; use the same name for the file.

Status of this part: `duo.sh ensure` was run by hand on the measured pair. Running it from launchd, and a start after a
full reboot, were not tested.
