# RVC to Home Assistant MQTT Integration

This project is designed to process RV-C (Recreational Vehicle Controller Area Network) messages, decode the data according to the RVC specification, and publish the information to a local MQTT broker for discovery by Home Assistant.

## Table of Contents

- [RVC to Home Assistant MQTT Integration](#rvc-to-home-assistant-mqtt-integration)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Features](#features)
  - [Installation](#installation)
  - [Configuration Files](#configuration-files)
    - [rvc-spec.yml](#rvc-specyml)
    - [coach-devices.yml](#coach-devicesyml)
  - [Script Usage](#script-usage)
  - [Home Assistant Integration](#home-assistant-integration)
  - [Using the Systemd Service](#using-the-systemd-service)
  - [License](#license)

## Overview

This script reads CAN bus data, decodes it based on the RV-C specification, and publishes relevant information to an MQTT broker. This allows the decoded data to be easily integrated into Home Assistant for monitoring and control of various RV systems such as lighting, HVAC, and other devices.

## Features

- **CAN Bus Monitoring**: Captures and processes messages from the RV-C network.
- **MQTT Integration**: Publishes data to an MQTT broker, allowing seamless integration with Home Assistant.
- **Configurable Device Mapping**: Define which devices and parameters should be processed using the `coach-devices.yml` configuration file.
- **Systemd Integration**: Includes watchdog functionality to ensure reliable operation.

## Installation

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/yourusername/rvc2mqtt.git
   cd rvc2mqtt
   ```

2. **Install Dependencies**:
   Ensure that Perl and necessary Perl modules are installed:
   ```bash
   sudo apt-get install perl libyaml-tiny-perl libnet-mqtt-simple-perl libio-socket-unix-perl
   ```

3. **Set Up CAN Interface**:
   Configure your CAN interface (e.g., `can0`) on your RV-C network. 

4. **Edit Configuration Files**:
   Customize the `rvc-spec.yml` and `coach-devices.yml` files to match your specific RV-C setup.

## Configuration Files

### rvc-spec.yml

This file contains the RV-C message definitions, including DGNs and their associated parameters. Here is an example entry:

```yaml
1FEDA:
  name: DC_DIMMER_STATUS_3
  parameters:
    - byte: 0
      name: instance
      type: uint8
    - byte: 2
      name: operating status (brightness)
      type: uint8
      unit: Pct
    - byte: 3
      name: lock status
      type: bit2
      bit: 0-1
      values:
        00: load is unlocked
        01: load is locked
        11: lock command is not supported
    - byte: 3
      name: overcurrent status
      type: bit2
      bit: 2-3
      values:
        00: load is not in overcurrent
        01: load is in overcurrent
        11: overcurrent status is unavailable or not supported
    - byte: 3
      name: override status
      type: bit2
      bit: 4-5
      values:
        00: external override is inactive
        01: external override is active
        11: override status is unavailable or not supported
    - byte: 3
      name: enable status
      type: bit2
      bit: 6-7
      values:
        00: load is enabled
        01: load is disabled
        11: enable status is unavailable or not supported
    - byte: 4
      name: delay/duration
      type: uint8
    - byte: 5
      name: last command
      type: uint8
      values:
        0: set brightness
        1: on duration
        2: on delay
        3: off
        4: stop
        5: toggle
        6: memory off
        17: ramp brightness
        18: ramp toggle
        19: ramp up
        20: ramp down
        21: ramp up/down
        33: lock
        34: unlock
        49: flash
        50: flash momentarily
    - byte: 6
      name: interlock status
      type: bit2
      bit: 0-1
      values:
        00: interlock command is not active
        01: interlock command is active
        11: interlock command is not supported
    - byte: 6
      name: load status
      type: bit2
      bit: 2-3
      values:
        00: operating status is zero
        01: operating status is non-zero or flashing
        11: interlock command is not supported
```

### coach-devices.yml

This file defines which RV-C devices and parameters should be processed and published to MQTT. It allows filtering based on instance IDs. Here’s an updated example:

```yaml
# Dimmable Lights
1FEDA:
  30:
    - ha_name: master_bath_ceiling_light
      friendly_name: Master Bathroom Ceiling Light
      state_topic: "homeassistant/light/master_bath_ceiling_light/state"
      value_template: "{{ value_json['operating status (brightness)'] }}"
      device_class: light
      device_type: light
  31:
    - ha_name: master_bath_lav_light
      friendly_name: Master Bathroom Lavatory Light
      state_topic: "homeassistant/light/master_bath_lav_light/state"
      value_template: "{{ value_json['operating status (brightness)'] }}"
      device_class: light
      device_type: light
  32:
    - ha_name: master_bath_accent_light
      friendly_name: Master Bathroom Accent Light
      state_topic: "homeassistant/light/master_bath_accent_light/state"
      value_template: "{{ value_json['operating status (brightness)'] }}"
      device_class: light
      device_type: light
```

This example shows how to define multiple dimmable lights, each with a unique instance ID, `ha_name`, and `friendly_name`. Each light is configured to be discovered as a light entity in Home Assistant, with the brightness level (`operating status (brightness)`) being reported as the state.

## Script Usage

Run the script to start monitoring the CAN bus and publishing to MQTT:

```bash
perl rvc2hass.pl
```

You can pass a `--debug` flag to enable debug mode, which will log additional information:

```bash
perl rvc2hass.pl --debug
```

## Home Assistant Integration

Once the MQTT topics are published, Home Assistant will automatically discover the devices based on the `config_topic` and start displaying their states.

## Using the Systemd Service

The project includes a systemd service file (`rvc2hass.service`) to run the script automatically as a service. Follow these steps to use it:

1. **Copy the Service File**:
   ```bash
   sudo cp rvc2hass.service /etc/systemd/system/
   ```

2. **Reload Systemd**:
   After copying the service file, reload the systemd daemon to recognize the new service:
   ```bash
   sudo systemctl daemon-reload
   ```

3. **Enable the Service**:
   Enable the service to start automatically on boot:
   ```bash
   sudo systemctl enable rvc2hass.service
   ```

4. **Start the Service**:
   Start the service immediately:
   ```bash
   sudo systemctl start rvc2hass.service
   ```

5. **Check the Status**:
   Verify that the service is running correctly:
   ```bash
   sudo systemctl status rvc2hass.service
   ```

This service file uses `Type=notify`, which expects the script to notify systemd when it has started successfully. The script also uses the systemd watchdog to ensure that it remains running. If the script fails, systemd will automatically attempt to restart it.

## License

This project is licensed under the GNU General Public License v3.0. See the [LICENSE](LICENSE) file for more details.
