# RVC to Home Assistant MQTT Bridge

This service reads data from the CAN bus and translates it into MQTT messages for Home Assistant auto-discovery. It is designed to interface with an RV's CAN bus system, decode messages, and make the relevant data available in Home Assistant.

## Features

- **CAN Bus Monitoring**: Listens to the CAN bus and decodes relevant data using a YAML configuration file.
- **Home Assistant Integration**: Auto-discovers devices and entities in Home Assistant through MQTT.
- **MQTT Connectivity**: Handles MQTT connectivity with retry logic and Last Will and Testament (LWT) for device availability.
- **Systemd Integration**: Includes a watchdog to ensure the service remains active and responsive.
- **Dynamic Configuration**: Uses YAML files to define device configurations and decode CAN bus messages.

## TO DO

- **Command and Control**: This service handles reading state from the canbus. Future updates will also include a script for allowing Home Assistant to control the RV-C Devices.

## Prerequisites

- Perl 5.x
- `Net::MQTT::Simple` module
- `YAML::Tiny` module
- `Sys::Syslog` module
- `candump` tool from `can-utils`
- A working MQTT broker
- Home Assistant instance

## Installation

1. Install the required Perl modules:
    ```
    cpan install Net::MQTT::Simple YAML::Tiny Sys::Syslog
    ```

2. Ensure `candump` from `can-utils` is installed:
    ```
    sudo apt-get install can-utils
    ```

3. Clone this repository and navigate to the directory:
    ```
    git clone https://github.com/carpenike/rvc2hass.git
    cd rvc2hass
    ```

4. Edit the YAML configuration files in the `config` directory to match your setup.

## Usage

To run the script manually, use:
```
perl rvc2hass.pl --debug
```

This will start the script in debug mode, printing additional logs to the console.

## Systemd Integration

To run this script as a service on a Linux system using systemd:

1. Copy the `rvc2hass.service` file to `/etc/systemd/system/`:
    ```
    sudo cp rvc2hass.service /etc/systemd/system/
    ```

2. Create a directory for environment overrides:
    ```
    sudo mkdir -p /etc/systemd/system/rvc2hass.service.d/
    ```

3. Create an `env.conf` file inside this directory to set environment variables:
    ```
    sudo nano /etc/systemd/system/rvc2hass.service.d/env.conf
    ```

    Example `env.conf` file content:
    ```
    [Service]
    Environment="MQTT_HOST=192.168.1.100"
    Environment="MQTT_PORT=1883"
    Environment="MQTT_USERNAME=your_mqtt_username"
    Environment="MQTT_PASSWORD=your_mqtt_password"
    Environment="WATCHDOG_USEC=30000000"
    ```

4. Reload systemd to recognize the new service:
    ```
    sudo systemctl daemon-reload
    ```

5. Enable and start the service:
    ```
    sudo systemctl enable rvc2hass
    sudo systemctl start rvc2hass
    ```

6. Check the status of the service:
    ```
    sudo systemctl status rvc2hass
    ```

## Configuration Files

- `rvc-spec.yml`: Defines the structure and interpretation of CAN bus messages.
- `coach-devices.yml`: Maps specific CAN bus data to Home Assistant entities and devices.

## Logging

The script logs important events to `journald`, viewable with:
```
journalctl -u rvc2hass.service
```

For more detailed debugging output, start the script with the `--debug` flag or set `Environment="DEBUG=1"` in the systemd `env.conf`.

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.