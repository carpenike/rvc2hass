# RVC to Home Assistant MQTT Bridge

The rvc2hass service is a Perl-based tool that bridges RV-C (Recreational Vehicle-CAN) data with Home Assistant, enabling you to monitor and control your RV devices via Home Assistant. This tool reads CAN bus data, decodes it, and publishes relevant information to an MQTT broker, making it available for Home Assistant to consume.

## WARNING

Use this tool at your own risk. This tool is unsupported and provided free of charge and without warranty. Making changes to an RV-C network outside of the vendor supplied tools brings with it inherent risk and may damage or destroy components in the system if not careful; IE -- do not attempt to send dimmer RV-C codes to a switch. The code is well documented, review the code to ensure you understand what it is doing prior to using the solution.

## Features

- **CAN Bus Monitoring**: Captures and processes data from the RV-C network using `candump`.
- **Home Assistant Integration**: Auto-discovers devices and entities in Home Assistant through MQTT.
- **MQTT Integration**: Publishes decoded data to an MQTT broker for integration with Home Assistant.
- **Device Handling**: Supports a variety of RV devices, including lights, switches, and sensors, with the ability to handle dimmable lights.
- **Retry Logic**: Robust MQTT connection logic with retries and Last Will and Testament (LWT) support.
- **Watchdog Monitoring**: Ensures continuous operation by monitoring the health of the system and the MQTT connection.
- **Dynamic Configuration**: Loads device configurations and specifications from YAML files, allowing for easy customization.

## TO DO

- **Command and Control**: This service handles reading state from the canbus. Future updates will also include a script for allowing Home Assistant to control the RV-C Devices.

## Prerequisites

- Perl 5.x
- `Net::MQTT::Simple` module
- `YAML::XS` module
- `Sys::Syslog` module
- `candump` tool from `can-utils`
- A working MQTT broker
- Home Assistant instance

## Installation

1. Install the required Perl modules:
    ```
    cpanm install YAML::XS JSON Net::MQTT::Simple Try::Tiny IO::Socket::UNIX threads Thread::Queue Time::HiRes File::Basename Sys::Syslog Getopt::Long POSIX
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

## Example `coach-devices.yml` Configuration

```yaml
templates:
  dimmable_light_template: &dimmable_light_template
    state_topic: "homeassistant/light/{{ ha_name }}/state"
    command_topic: "homeassistant/light/{{ ha_name }}/set"
    value_template: "{{ value_json.state }}"
    device_class: light
    dimmable: true  # Explicitly mark as dimmable
    brightness_state_topic: "homeassistant/light/{{ ha_name }}/state"
    brightness_command_topic: "homeassistant/light/{{ ha_name }}/brightness/set"
    brightness_value_template: "{{ value_json.brightness }}"
    brightness_command_template: "{{ value }}"
    payload_on: "ON"
    payload_off: "OFF"
    state_value_template: "{{ value_json.state }}"

  switchable_light_template: &switchable_light_template
    state_topic: "homeassistant/light/{{ ha_name }}/state"
    command_topic: "homeassistant/light/{{ ha_name }}/set"
    value_template: "{{ value_json.state }}"
    device_class: light
    dimmable: false  # Explicitly mark as non-dimmable
    payload_on: "ON"
    payload_off: "OFF"
    state_value_template: "{{ value_json.state }}"

# Dimmable Lights
1FEDA:
  30:
    - ha_name: master_bath_ceiling_light
      friendly_name: Master Bathroom Ceiling Light
      <<: *dimmable_light_template

  31:
    - ha_name:  master_bath_lav_light
      friendly_name: Master Bathroom Lavatory Light
      <<: *dimmable_light_template
  32:
    - ha_name:  master_bath_accent_light
      friendly_name: Master Bathroom Accent Light
      <<: *dimmable_light_template
...

# Non-dimmable Lights
  51:
    - ha_name:  exterior_driver_side_awning_light
      friendly_name: Exterior Driver Side Awning Light
      <<: *switchable_light_template
  52:
    - ha_name:  exterior_passenger_side_awning_light
      friendly_name: Exterior Passenger Side Awning Light
      <<: *switchable_light_template

```

## MQTT Entries from Dimmable Light Status:

Topic: homeassistant/light/master_bath_ceiling_light/config

```json
{
  "brightness_scale": 100,
  "availability": [
    {
      "topic": "rvc2hass/status",
      "payload_not_available": "offline",
      "payload_available": "online"
    }
  ],
  "device_class": "light",
  "brightness": true,
  "supported_color_modes": [
    "brightness"
  ],
  "brightness_value_template": "{{ value_json.brightness }}",
  "command_topic": "homeassistant/light/master_bath_ceiling_light/set",
  "unique_id": "master_bath_ceiling_light",
  "brightness_command_topic": "homeassistant/light/master_bath_ceiling_light/brightness/set",
  "brightness_command_template": "{{ value }}",
  "state_value_template": "{{ value_json.state }}",
  "name": "Master Bathroom Ceiling Light",
  "payload_on": "ON",
  "payload_off": "OFF",
  "state_topic": "homeassistant/light/master_bath_ceiling_light/state",
  "brightness_state_topic": "homeassistant/light/master_bath_ceiling_light/state"
}
```

Topic: homeassistant/light/master_bath_ceiling_light/state

```json
{
  "state": "ON",
  "brightness": 60
}
```

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

## Credit

Many thanks to the creators of the now unmaintained [CoachProxy](https://coachproxy.com/) for the initial code.

Also thanks to [eRVin](https://myervin.com/) for the guidance on determining where the Entegra devices are on the RV-C network