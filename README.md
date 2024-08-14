# RVC to Home Assistant CAN Bus Monitor

This project is a Perl script that monitors the CAN bus for RVC (RV-C) messages and publishes relevant data to an MQTT broker, making the data available for Home Assistant integration.

## Features

- Monitors CAN bus messages and decodes them using a specified YAML configuration.
- Publishes decoded data to an MQTT broker for Home Assistant auto-discovery.
- Supports systemd service for automatic startup and watchdog functionality.

## Files

### `rvc2hass.pl`

The main Perl script that performs the monitoring, decoding, and publishing.

### `rvc-spec.yml`

A YAML file that contains the decoding specifications for each DGN (Data Group Number) on the CAN bus.

### `coach-devices.yml`

A YAML file that maps specific DGN instances to Home Assistant entities.

### `rvc2hass.service`

A systemd service file for managing the script as a service on Linux systems.

## Installation

1. **Clone the Repository**
   
   ```bash
   git clone https://github.com/carpenike/rvc2hass.git
   cd rvc2hass
   ```

2. **Configure the YAML Files**

   Edit `rvc-spec.yml` and `coach-devices.yml` according to your RV-C network setup.

3. **Install Dependencies**

   Make sure Perl and the required Perl modules are installed on your system.

4. **Set Up the Systemd Service**

   Copy the `rvc2hass.service` file to the systemd directory and reload the daemon.

   ```bash
   sudo cp rvc2hass.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable rvc2hass
   ```

5. **Start the Service**

   Start the service and check its status.

   ```bash
   sudo systemctl start rvc2hass
   sudo systemctl status rvc2hass
   ```

## Example `coach-devices.yml` Configuration

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

## MQTT Entries from Dimmable Light Status:

Topic: homeassistant/light/master_bath_ceiling_light/state

```json
{
  "load status definition": "undefined",
  "data": "1E7CC6FCFF0404FF",
  "last command": 4,
  "overcurrent status": 3,
  "enable status definition": "undefined",
  "interlock status": 0,
  "override status": 3,
  "interlock status definition": "undefined",
  "last command definition": "stop",
  "load status": 1,
  "instance": 30,
  "enable status": 3,
  "delay/duration": 255,
  "name": "DC_DIMMER_STATUS_3",
  "operating status (brightness)": 99,
  "lock status definition": "undefined",
  "dgn": "1FEDA",
  "overcurrent status definition": "undefined",
  "group": "01111100",
  "lock status": 0,
  "override status definition": "undefined"
}
```

Topic: homeassistant/light/master_bath_ceiling_light/config

```json
{
  "value_template": "{{ value_json['operating status (brightness)'] }}",
  "name": "Master Bathroom Ceiling Light",
  "state_topic": "homeassistant/light/master_bath_ceiling_light/state",
  "json_attributes_topic": "homeassistant/light/master_bath_ceiling_light/state",
  "unique_id": "master_bath_ceiling_light",
  "device_class": "light"
}
```

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for more details.

## Credit

Many thanks to the creators of the now unmaintained [CoachProxy](https://coachproxy.com/) for the initial code.

Also thanks to [eRVin](https://myervin.com/) for the guidance on determining where the Entegra devices are on the RV-C network
