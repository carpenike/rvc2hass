#!/usr/bin/perl -w

use strict;
use warnings;
no warnings 'exiting';  # Suppress 'exiting' warnings for potential exit calls in loops
use File::Temp qw(tempdir);
use YAML::XS qw(LoadFile);
use JSON qw(encode_json decode_json);
use Net::MQTT::Simple;
use Try::Tiny;
use IO::Socket::UNIX;
use threads;
use Thread::Queue;
use Time::HiRes qw(sleep);
use File::Basename;
use Sys::Syslog qw(:standard :macros);
use Getopt::Long;

# Command-line options
my $debug = 0;
GetOptions("debug" => \$debug);

# Configuration Variables
my $mqtt_host = $ENV{MQTT_HOST} || "localhost";
my $mqtt_port = $ENV{MQTT_PORT} || 1883;
my $mqtt_username = $ENV{MQTT_USERNAME};
my $mqtt_password = $ENV{MQTT_PASSWORD};
my $max_retries = 5;
my $retry_delay = 5;  # Time to wait between retry attempts in seconds
my $watchdog_usec = $ENV{WATCHDOG_USEC} // 0;
my $watchdog_interval = $watchdog_usec ? int($watchdog_usec / 2 / 1_000_000) : 0;  # Convert microseconds to seconds and halve it for watchdog interval
my %sent_configs;  # Track sent configurations to avoid resending

# Log environment variables for debugging purposes
log_to_journald("Environment: " . join(", ", map { "$_=$ENV{$_}" } keys %ENV), LOG_DEBUG);
$ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;  # Allow unencrypted connection with credentials

# Initialize MQTT connection
my $mqtt = initialize_mqtt();

# Start Watchdog thread if configured
start_watchdog(\$mqtt, $watchdog_interval) if $watchdog_interval;

# Determine the script directory
my $script_dir = dirname(__FILE__);

# Load YAML files containing specifications and device configurations
my $decoders = LoadFile("$script_dir/config/rvc-spec.yml");
my $lookup = LoadFile("$script_dir/config/coach-devices.yml");

# Debug: Print out the lookup structure to verify template inclusion
use Data::Dumper;
log_to_journald("Loaded YAML structure: " . Dumper($lookup), LOG_DEBUG);

# Create a temporary directory for undefined DGNs
my $temp_dir = tempdir(CLEANUP => 1);
my $undefined_dgns_file = "$temp_dir/undefined_dgns.log";

# Log the creation of the temporary directory
log_to_journald("Temporary directory created at: $temp_dir", LOG_INFO);

# Notify systemd that the script has started successfully
systemd_notify("READY=1");

# Subscribe to Home Assistant's availability topic to monitor its state
$mqtt->subscribe('homeassistant/status' => sub {
    my ($topic, $message) = @_;
    if ($message eq 'online') {
        log_to_journald("Home Assistant is online. Resending configurations...", LOG_INFO);
        foreach my $ha_name (keys %sent_configs) {
            publish_mqtt($sent_configs{$ha_name}, undef, 1);  # Resend config on HA online
        }
    } elsif ($message eq 'offline') {
        log_to_journald("Home Assistant is offline.", LOG_INFO);
    }
});

# Open CAN bus data stream using candump
open my $file, '-|', 'candump', '-ta', 'can0' or die "Cannot start candump: $!\n";

# Indicate the start of CAN bus data processing
log_to_journald("Script startup complete. Processing CAN bus data...", LOG_INFO);
process_can_bus_data($file);

# Initialize and connect to the MQTT broker, with retry logic and LWT
sub initialize_mqtt {
    my $mqtt;
    my $success = 0;  # Flag to track if connection was successful
    
    for (my $attempt = 1; $attempt <= $max_retries; $attempt++) {
        try {
            my $connection_string = "$mqtt_host:$mqtt_port";
            
            # Create and configure MQTT client
            log_to_journald("Connecting to $mqtt_host:$mqtt_port...", LOG_INFO);
            $mqtt = Net::MQTT::Simple->new($connection_string);
            log_to_journald("MQTT client created.", LOG_INFO);
            $mqtt->login($mqtt_username, $mqtt_password) if $mqtt_username && $mqtt_password;
            log_to_journald("MQTT login successful.", LOG_INFO);

            # Set Last Will and Testament (LWT) for availability
            $mqtt->last_will("rvc2hass/status", "offline", 1);  # Set LWT with topic, message, and retain flag
            log_to_journald("LWT set to 'offline' on rvc2hass/status", LOG_INFO);

            # Publish "online" status after successful connection
            $mqtt->retain("rvc2hass/status", "online");

            # Test MQTT connection by subscribing and publishing to a test topic
            my $test_topic = "rvc2hass/connection_check";
            my $message_received;
            $mqtt->subscribe($test_topic => sub {
                my ($topic, $message) = @_;
                log_to_journald("Received message on $test_topic: $message", LOG_DEBUG);
                $message_received = $message;
            });

            # Publish a test message to confirm connectivity
            $mqtt->publish($test_topic, "MQTT startup successful");

            # Wait for a confirmation message from the broker
            for (my $wait = 0; $wait < 5; $wait++) {
                last if $message_received;
                $mqtt->tick();  # Process incoming messages
                sleep(1);
            }

            if ($message_received && $message_received eq "MQTT startup successful") {
                log_to_journald("Successfully connected to MQTT broker on attempt $attempt.", LOG_INFO);
                $success = 1;
                last;  # Exit loop on success
            } else {
                log_to_journald("Failed to receive confirmation message on attempt $attempt.", LOG_WARNING);
                $mqtt = undef;  # Reset $mqtt on failure
            }
        }
        catch {
            my $error_msg = $_;  # Capture the error message
            log_to_journald("Error caught: $error_msg", LOG_ERR);

            if ($error_msg =~ /connect: Connection refused/) {
                log_to_journald("Connection refused by MQTT broker. Please check if the broker is running and accessible.", LOG_ERR);
            } else {
                log_to_journald("Failed to connect to MQTT on attempt $attempt: $error_msg", LOG_ERR);
            }
            $mqtt = undef;  # Reset $mqtt on failure
            sleep($retry_delay) if $attempt < $max_retries;  # Delay before retrying
        };
    }

    # Check if the connection was successful
    if ($success) {
        return $mqtt;  # Return MQTT object on success
    } else {
        log_to_journald("Failed to connect to MQTT broker after $max_retries attempts. Exiting.", LOG_ERR);
        die "Failed to connect to MQTT broker after $max_retries attempts.";
    }
}

# Start the watchdog thread to monitor the system's health and MQTT connectivity
sub start_watchdog {
    my $heartbeat_topic = "rvc2hass/heartbeat";
    my $heartbeat_received = 0;

    # Subscribe to the heartbeat topic to listen for confirmation messages
    $mqtt->subscribe($heartbeat_topic => sub {
        my ($topic, $message) = @_;
        log_to_journald("Received heartbeat on $heartbeat_topic: $message", LOG_DEBUG);
        if ($message eq "Heartbeat message from watchdog") {
            $heartbeat_received = 1;
        }
    });

    # Start a detached thread to handle watchdog functionality
    my $watchdog_thread = threads->create(sub {
        while (1) {
            my $mqtt_success = 0;

            try {
                # Reset the heartbeat_received flag
                $heartbeat_received = 0;

                # Publish a heartbeat message to MQTT
                $mqtt->publish($heartbeat_topic, "Heartbeat message from watchdog");
                log_to_journald("Published heartbeat message to MQTT", LOG_DEBUG);

                # Wait for a confirmation message
                for (my $wait = 0; $wait < 10; $wait++) {
                    for (1..10) { $mqtt->tick(); sleep(0.1); }  # Check frequently
                    if ($heartbeat_received) {
                        $mqtt_success = 1;
                        last;
                    }
                }

                if (!$mqtt_success) {
                    log_to_journald("Failed to receive heartbeat confirmation. Exiting.", LOG_ERR);
                    die "Error in watchdog loop: Failed to receive heartbeat confirmation. Exiting.";
                }

            } catch {
                log_to_journald("Error in watchdog loop: $_. Exiting.", LOG_ERR);
                die "Error in watchdog loop: $_. Exiting.";
            };

            # Notify systemd that the process is still alive
            if ($mqtt_success) {
                log_to_journald("Notifying systemd watchdog.", LOG_DEBUG);
                if (systemd_notify("WATCHDOG=1")) {
                    log_to_journald("Systemd watchdog notified successfully.", LOG_INFO);
                } else {
                    log_to_journald("Failed to notify systemd watchdog.", LOG_ERR);
                }
            }

            sleep($watchdog_interval);
        }
    });

    $watchdog_thread->detach();  # Detach the thread to allow it to run independently
}

# Process CAN bus data by reading and handling each line of input
sub process_can_bus_data {
    my $can_file = shift;

    while (my $line = <$can_file>) {
        chomp $line;
        my @parts = split ' ', $line;
        process_packet(@parts);
    }
    close $can_file;
}

# Process a single CAN bus packet, decoding and publishing to MQTT as needed
sub process_packet {
    my @parts = @_;
    # log_to_journald("Processing packet: @parts", LOG_DEBUG);

    return unless @parts >= 5;  # Ensure there are enough parts to process

    my $can_id_hex = $parts[2];
    my $binCanId = sprintf("%029b", hex($can_id_hex));  # Ensure leading zeros for CAN ID
    my $dgn_bin = substr($binCanId, 4, 17);  # Extract DGN from CAN ID
    my $dgn = sprintf("%05X", oct("0b$dgn_bin"));  # Convert binary DGN to hex

    log_to_journald("DGN: $dgn, Data: @parts[4..$#parts]", LOG_DEBUG);

    my $data_bytes = join '', @parts[4..$#parts];
    my $result = decode($dgn, $data_bytes);

    if ($result) {
        log_to_journald("Decoded result: " . encode_json($result), LOG_DEBUG);
        my $instance = $result->{'instance'} // 'default';  # Default to 'default' if instance not found

        if (exists $lookup->{$dgn} && exists $lookup->{$dgn}->{$instance}) {
            my $configs = $lookup->{$dgn}->{$instance};
            foreach my $config (@$configs) {
                # Ensure device_class is defined before checking its value
                if (defined $config->{device_class} && $config->{device_class} eq 'light') {
                    # Handle dimmable light specifically
                    handle_dimmable_light($config, $result);
                } else {
                    # Handle non-dimmable lights or other devices
                    publish_mqtt($config, $result);
                }
            }
        } elsif (exists $lookup->{$dgn} && exists $lookup->{$dgn}->{default}) {
            # Handle default instance if specific instance not found
            my $configs = $lookup->{$dgn}->{default};
            foreach my $config (@$configs) {
                if (defined $config->{device_class} && $config->{device_class} eq 'light') {
                    handle_dimmable_light($config, $result);
                } else {
                    publish_mqtt($config, $result);
                }
            }
        } else {
            log_to_journald("No matching config found for DGN $dgn and instance $instance", LOG_DEBUG);
            log_to_temp_file($dgn);
        }
    } else {
        log_to_journald("No data to publish for DGN $dgn", LOG_DEBUG);
    }
}

# Handle dimmable light packets, calculating brightness and command state
sub handle_dimmable_light {
    my ($config, $result) = @_;

    # Ensure $result is defined
    if (defined $result) {
        my $brightness = $result->{'operating status (brightness)'};

        # Ensure brightness is defined and valid
        if (defined $brightness && $brightness =~ /^\d+$/) {
            log_to_journald("Decoded brightness for $config->{ha_name}: $brightness", LOG_DEBUG);

            # Calculate command based on brightness
            my $command = ($brightness > 0) ? 'ON' : 'OFF';
            log_to_journald("Calculated command: $command for device: $config->{ha_name}", LOG_DEBUG);

            # Store calculated values in the result hash
            $result->{'calculated_brightness'} = $brightness;
            $result->{'calculated_command'} = $command;

            # Additional log to ensure brightness is set correctly
            log_to_journald("Brightness in handle_dimmable_light: " . ($result->{'calculated_brightness'} // 'undefined'), LOG_DEBUG);
            
            # Publish the MQTT message
            publish_mqtt($config, $result);
            log_to_journald("Published state update for $config->{ha_name}: $command with brightness $brightness", LOG_INFO);
        } else {
            log_to_journald("Invalid brightness value for $config->{ha_name}: '$brightness'", LOG_WARNING);
            $result->{'calculated_brightness'} = 0;  # Default to 0 brightness
            $result->{'calculated_command'} = 'OFF';
            publish_mqtt($config, $result);
        }
    } else {
        log_to_journald("No result data provided for light handling.", LOG_WARNING);
    }
}

# Publish MQTT messages, handling configuration and state updates
sub publish_mqtt {
    my ($config, $result, $resend) = @_;

    # Flatten the configuration by merging the template values
    if (exists $config->{'<<'}) {
        my %merged_config = (%{$config->{'<<'}}, %$config);
        $config = \%merged_config;
        delete $config->{'<<'};  # Remove the merged template reference
    }

    my $ha_name = $config->{ha_name} // '';
    my $friendly_name = $config->{friendly_name} // '';

    # Ensure `ha_name` is defined before expanding templates
    if ($ha_name eq '') {
        log_to_journald("Undefined ha_name for configuration.");
        return;
    }

    # Ensure device_class is defined and sanitize any empty fields
    $config->{device_class} //= '';  # Default to empty string if not defined
    $config->{device_class} =~ s/^\s+|\s+$//g;  # Trim any whitespace
    $config->{device_class} = 'default' if $config->{device_class} eq '';  # Use 'default' if empty

    # Expand templates, ensuring each template variable is properly initialized
    my $state_topic = expand_template($config->{state_topic}, $ha_name);
    my $command_topic = expand_template($config->{command_topic}, $ha_name);
    my $brightness_state_topic = expand_template($config->{brightness_state_topic}, $ha_name);
    my $brightness_command_topic = expand_template($config->{brightness_command_topic}, $ha_name);

    # Ensure the configuration for the MQTT topics is defined before attempting to use them
    if (!$state_topic || !$command_topic || ($config->{device_class} eq 'light' && (!$brightness_state_topic || !$brightness_command_topic))) {
        log_to_journald("Undefined or invalid topic template for ha_name: $ha_name");
        return;
    }

    # Sanitize topics to remove double slashes
    $state_topic =~ s/\/{2,}/\//g;
    $command_topic =~ s/\/{2,}/\//g;
    $brightness_state_topic =~ s/\/{2,}/\//g if defined $brightness_state_topic;
    $brightness_command_topic =~ s/\/{2,}/\//g if defined $brightness_command_topic;

    # Log the final MQTT topics for debugging
    log_to_journald("Publishing MQTT for ha_name $ha_name with topics: state: $state_topic, command: $command_topic", LOG_DEBUG);

    # Send /config message only if not already sent or if resending
    if ($resend || !exists $sent_configs{$ha_name}) {
        # Prepare the MQTT configuration message
        my %config_message = (
            name => $friendly_name,
            state_topic => $state_topic,
            command_topic => $command_topic,
            device_class => $config->{device_class},  # Include device_class if applicable
            unique_id => $ha_name,  # Ensure unique ID for the device
            payload_on => "ON",
            payload_off => "OFF",
            state_value_template => '{{ value_json.state }}',
            availability => [
                {
                    topic => "rvc2hass/status",
                    payload_available => "online",
                    payload_not_available => "offline"
                }
            ]
        );

        # If the device is a light, include brightness settings
        if ($config->{device_class} eq 'light') {
            $config_message{supported_color_modes} = ["brightness"];
            $config_message{brightness} = JSON::true;
            $config_message{brightness_scale} = 100;
            $config_message{brightness_state_topic} = $brightness_state_topic;  # Colocate brightness and state
            $config_message{brightness_command_topic} = $brightness_command_topic;  # Separate command topic for brightness
            $config_message{brightness_command_template} = '{{ value }}';
            $config_message{brightness_value_template} = '{{ value_json.brightness }}';
        }

        # Publish the configuration message to the /config topic
        my $config_json = encode_json(\%config_message);
        $mqtt->retain("homeassistant/$config->{device_class}/$ha_name/config", $config_json);

        # Log that a new device's /config was pushed
        log_to_journald("Published /config for device: $ha_name ($friendly_name)");

        # Track that this config has been sent
        $sent_configs{$ha_name} = $config;
    }

    # Log the brightness and command before publishing
    log_to_journald("Brightness in publish_mqtt: " . ($result->{'calculated_brightness'} // 'undefined'), LOG_DEBUG);
    log_to_journald("Command in publish_mqtt: " . ($result->{'calculated_command'} // 'undefined'), LOG_DEBUG);

    # Determine the correct state based on brightness for lights, or use ON/OFF for switches
    my $calculated_state;
    if ($config->{device_class} eq 'light') {
        $calculated_state = ($result->{'calculated_brightness'} && $result->{'calculated_brightness'} > 0) ? 'ON' : 'OFF';
    } elsif ($config->{device_class} eq 'switch') {
        $calculated_state = ($result->{'calculated_command'} && $result->{'calculated_command'} eq 'ON') ? 'ON' : 'OFF';
    }

    # Prepare the state message
    my %state_message = (
        state => $calculated_state,
        brightness => $result->{'calculated_brightness'} // 'undefined'
    );

    # Publish the state message to the /state topic
    log_to_journald("Final state to publish: $calculated_state with brightness: " . ($result->{'calculated_brightness'} // 'undefined'), LOG_INFO);
    my $state_json = encode_json(\%state_message);
    $mqtt->retain($state_topic, $state_json);

    # Debug log the state message being published
    log_to_journald("Published /state for device: $ha_name ($friendly_name) with state: $state_json", LOG_DEBUG);
}

# Function to replace template variables in topics
sub expand_template {
    my ($template, $ha_name) = @_;

    # Check if the template is defined and non-empty
    if (!defined $template || $template eq '') {
        log_to_journald("Undefined or empty template provided for ha_name: $ha_name", LOG_ERR);
        return '';  # Return an empty string to avoid further issues
    }

    # Perform the substitution
    $template =~ s/\{\{ ha_name \}\}/$ha_name/g;

    # Debug log to verify template expansion
    log_to_journald("Expanded template for ha_name $ha_name: $template", LOG_DEBUG);

    return $template;
}

# Decode the DGN and data bytes to extract relevant parameters and values
sub decode {
    my ($dgn, $data) = @_;
    my %result;

    my $decoder = $decoders->{$dgn};
    unless ($decoder) {
        log_to_journald("No decoder found for DGN $dgn", LOG_DEBUG);
        return;
    }

    $result{dgn} = $dgn;
    $result{data} = $data;
    $result{name} = $decoder->{name} || "UNKNOWN-$dgn";

    my @parameters;
    push(@parameters, @{$decoders->{$decoder->{alias}}->{parameters}}) if ($decoder->{alias});
    push(@parameters, @{$decoder->{parameters}}) if ($decoder->{parameters});

    foreach my $parameter (@parameters) {
        my $name = $parameter->{name};
        my $type = $parameter->{type} // 'uint';
        my $unit = $parameter->{unit};
        my $values = $parameter->{values};

        my $bytes = get_bytes($data, $parameter->{byte});
        my $value = hex($bytes);

        if (defined $parameter->{bit}) {
            my $bits = get_bits($bytes, $parameter->{bit});
            $value = oct('0b' . $bits) if defined $bits;
        }

        if (defined $unit) {
            $value = convert_unit($value, $unit, $type);
        }

        $result{$name} = $value;

        if (defined $unit && lc($unit) eq 'deg c') {
            $result{$name . " F"} = tempC2F($value) if $value ne 'n/a';
        }

        if ($values) {
            my $value_def = 'undefined';
            $value_def = $values->{$value} if ($values->{$value});
            $result{"$name definition"} = $value_def;
        }
    }

    $result{instance} = $result{instance} // undef;

    # Additional log to ensure the result is being decoded correctly
    log_to_journald("Decoded values for DGN $dgn: " . encode_json(\%result), LOG_DEBUG);

    return \%result;
}

# Extract bytes from the data using the specified byte range
sub get_bytes {
    my ($data, $byterange) = @_;

    my ($start_byte, $end_byte) = split(/-/, $byterange);
    $end_byte = $start_byte if not defined $end_byte;
    my $length = ($end_byte - $start_byte + 1) * 2;
    
    return '' if $start_byte * 2 >= length($data);
    
    my $sub_bytes = substr($data, $start_byte * 2, $length);
    my @byte_pairs = $sub_bytes =~ /(..)/g;
    my $bytes = join '', reverse @byte_pairs;

    return $bytes;
}

# Extract bits from the specified range within a byte
sub get_bits {
    my ($bytes, $bitrange) = @_;
    return unless length($bytes);

    my $bits = hex2bin($bytes);
    return unless defined $bits && length($bits);

    my ($start_bit, $end_bit) = split(/-/, $bitrange);
    $end_bit = $start_bit if not defined $end_bit;

    return substr($bits, 7 - $end_bit, $end_bit - $start_bit + 1);
}

# Convert hexadecimal to binary representation
sub hex2bin {
    my $hex = shift;
    return unpack("B8", pack("C", hex $hex)) if length($hex) == 2;
    return '';
}

# Convert values between different units
sub convert_unit {
    my ($value, $unit, $type) = @_;
    my $new_value = $value;

    if (lc($unit) eq 'pct') {
        $new_value = 'n/a';
        $new_value = $value / 2 unless ($value == 255);
    } elsif (lc($unit) eq 'deg c') {
        $new_value = 'n/a';
        if ($type eq 'uint8') {
            $new_value = $value - 40 unless ($value == 255);
        } elsif ($type eq 'uint16') {
            $new_value = round($value * 0.03125 - 273, 0.1) unless ($value == 65535);
        }
    } elsif (lc($unit) eq 'v') {
        $new_value = 'n/a';
        if ($type eq 'uint8') {
            $new_value = $value unless ($value == 255);
        } elsif ($type eq 'uint16') {
            $new_value = round($value * 0.05, 0.1) unless ($value == 65535);
        }
    } elsif (lc($unit) eq 'a') {
        $new_value = 'n/a';
        if ($type eq 'uint8') {
            $new_value = $value;
        } elsif ($type eq 'uint16') {
            $new_value = round($value * 0.05 - 1600, 0.1) unless ($value == 65535);
        } elsif ($type eq 'uint32') {
            $new_value = round($value * 0.001 - 2000000, 0.01) unless $value == 4294967295;
        }
    } elsif (lc($unit) eq 'hz') {
        if ($type eq 'uint8') {
            $new_value = $value;
        } elsif ($type eq 'uint16') {
            $new_value = round($value / 128, 0.1);
        }
    } elsif (lc($unit) eq 'sec') {
        if ($type eq 'uint8') {
            if ($value > 240 && $value < 251) {
                $new_value = (($value - 240) + 4) * 60;
            }
        } elsif ($type eq 'uint16') {
            $new_value = $value * 2;
        }
    } elsif (lc($unit) eq 'bitmap') {
        $new_value = sprintf('%08b', $value);
    }

    return $new_value;
}

# Round a value to a specified precision
sub round {
    my ($value, $precision) = @_;
    return int($value / $precision + 0.5) * $precision;
}

# Convert temperature from Celsius to Fahrenheit
sub tempC2F {
    my ($tempC) = @_;
    return int((($tempC * 9 / 5) + 32) * 10) / 10;
}

# Log undefined DGN entries to a temporary file
sub log_to_temp_file {
    my ($dgn) = @_;

    if (-e $undefined_dgns_file) {
        open my $fh, '<', $undefined_dgns_file or do {
            log_to_journald("Failed to open log file for reading undefined DGN $dgn: $!", LOG_ERR);
            return;
        };
        while (my $line = <$fh>) {
            chomp $line;
            if ($line eq $dgn) {
                close $fh;
                return;
            }
        }
        close $fh;
    }

    open my $fh, '>>', $undefined_dgns_file or do {
        log_to_journald("Failed to open log file for appending undefined DGN $dgn: $!", LOG_ERR);
        return;
    };
    print $fh "$dgn\n";
    close $fh;

    log_to_journald("Logged undefined DGN $dgn to temporary file: $undefined_dgns_file", LOG_INFO);
}

# Log messages to journald
sub log_to_journald {
    my ($message, $level) = @_;
    
    $level //= LOG_INFO;  # Default log level if not provided
    openlog('rvc2hass', 'cons,pid', LOG_USER);
    syslog($level, $message);
    closelog();
}

# Send notifications to systemd
sub systemd_notify {
    my ($state) = @_;
    my $socket_path = $ENV{NOTIFY_SOCKET} // return;

    socket(my $socket, PF_UNIX, SOCK_DGRAM, 0) or do {
        log_to_journald("Failed to create UNIX socket: $!", LOG_ERR);
        return;
    };
    my $dest = sockaddr_un($socket_path);
    send($socket, $state, 0, $dest) or do {
        log_to_journald("Failed to send systemd notification: $!", LOG_ERR);
    };
    close($socket);
}
