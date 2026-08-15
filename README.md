# MG iSMART for LoxBerry

A LoxBerry plugin that connects MG cars with iSMART connectivity (MG S6 EV, MG4, MG5, ZS, …) to the Loxone Miniserver over MQTT.

The plugin does not talk to the vehicle itself. It installs and operates **[saic-python-mqtt-gateway](https://github.com/SAIC-iSmart-API/saic-python-mqtt-gateway)**, which logs in to the SAIC cloud, publishes the vehicle data over MQTT and accepts commands for the car — many thanks to that project and to the [SAIC-iSmart-API](https://github.com/SAIC-iSmart-API) community. What this plugin adds is a one-click installation on LoxBerry, a web interface for the settings, control and supervision of the gateway process, and updates of the gateway software.

## Requirements

- LoxBerry 4.0.0 or newer
- An iSMART account with the vehicle registered to it (create it in the iSMART app)
- The LoxBerry MQTT broker and MQTT Gateway

## What the plugin does

- **Gateway tab** — process state with start, stop and restart, plus the state of the cloud connection: online/offline, last successful login, last login error and the version the running gateway reports. A gateway whose credentials are wrong looks healthy as a process, so that distinction is shown explicitly.
- **Settings tab** — iSMART account, region, MQTT topic prefix and Home Assistant discovery, an *Advanced* section for the refresh intervals and battery capacity mapping, and a free-form field for any gateway environment variable the plugin does not expose (ABRP, OsmAnd, OpenWB).
- **Update tab** — installed and available version of the gateway software, a choice between releases only and releases including prereleases, and an update button.
- **Log files tab** — the `gateway`, `watchdog` and `update` logs.
- **Healthcheck** — reports process, software, configuration and cloud state to the LoxBerry healthcheck, which notifies you when something is wrong.

## How it is put together

The gateway is installed from a GitHub release tarball into the plugin's data directory, with its Python dependencies in a **private venv**. Nothing is installed system-wide, so a gateway update can never disturb another plugin, and uninstalling removes every trace.

The process is supervised by `bin/watchdog.pl` rather than systemd: it runs as the `loxberry` user, its output goes into a registered LoxBerry log file, a cron job restarts it if it dies, and a manual stop is remembered across reboots and plugin upgrades.

The gateway configuration (`.env`) is **regenerated on every start**. That is how the MQTT broker credentials and the log level always match what LoxBerry currently has, without anyone having to copy them over.

## MQTT

The gateway publishes below `<prefix>/<iSMART user>/…`, by default with the prefix `saic`. The exact topic is shown on the Gateway tab.

**Subscribe to that topic in the LoxBerry MQTT Gateway** — the plugin deliberately does not change that configuration for you. MQTT Gateway V2 subscribes per topic, and which values you want forwarded to the Miniserver is your decision.

Commands to the vehicle are sent on topics ending in `/set` below the same prefix — locking, climate, charging, and so on. The available commands and their value ranges are documented in the [gateway README](https://github.com/SAIC-iSmart-API/saic-python-mqtt-gateway#commands-over-mqtt). Build your Loxone virtual outputs from those.

## Licence

Apache License 2.0, see [LICENSE](LICENSE).
