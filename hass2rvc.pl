#!/usr/bin/perl -w

use strict;
use warnings;
use YAML::XS qw(LoadFile);
use JSON qw(decode_json);
use Net::MQTT::Simple;
use Try::Tiny;
use IO::Socket::UNIX;
use Sys::Syslog qw(:standard :macros);
use Getopt::Long;
use POSIX qw(strftime);
use File::Basename;
use threads;
use threads::shared;

# Command-line options for debugging and log level
my $debug = 0;
my $log_level = LOG_INFO;
GetOptions("debug" => \$debug, "log-level=i" => \$log_level);

# Set log level to DEBUG if debug flag is enabled
$log_level = LOG_DEBUG if $debug;

# Configuration Variables
my $mqtt_host = $ENV{MQTT_HOST} || "localhost";  # Default MQTT host is localhost
my $mqtt_port = $ENV{MQTT_PORT} || 1883;         # Default MQTT port
my $mqtt_username = $ENV{MQTT_USERNAME};
my $mqtt_password = $ENV{MQTT_PASSWORD};
my $max_retries = 5;  # Number of retries for MQTT connection
my $retry_delay = 5;  # Delay between retries
my $can_interface = 'can0';  # CAN interface name
my $watchdog_usec = $ENV{WATCHDOG_USEC} // 0;  # Watchdog interval in microseconds
my $watchdog_interval = $watchdog_usec ? int($watchdog_usec / 2 / 1_000_000) : 0;  # Watchdog interval in seconds
my $can_bus_mutex :shared;  # Mutex for thread safety when accessing CAN bus
my $keep_running :shared = 1;  # Shared variable to control main loop execution

# Log environment variables if debugging is enabled (excluding sensitive information)
log_to_journald("Environment: " . join(", ", map { "$_=$ENV{$_}" } grep { $_ !~ /PASSWORD|SECRET/ } keys %ENV), LOG_DEBUG) if $debug;

# Allow insecure MQTT logins (needed for certain MQTT brokers)
$ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;

# Initialize MQTT connection
my $mqtt = initialize_mqtt();

# Start Watchdog thread if configured
start_watchdog($mqtt, $watchdog_interval) if $watchdog_interval;

# Load YAML configuration files containing device specifications
my $script_dir = dirname(__FILE__);
my $lookup = LoadFile("$script_dir/config/coach-devices.yml");

# Signal handling for graceful shutdown
$SIG{'INT'} = sub { shutdown_gracefully("INT") };
$SIG{'TERM'} = sub { shutdown_gracefully("TERM") };

# Subscribe to MQTT topics for all devices
foreach my $dgn (keys %$lookup) {

    # Skip the templates section
    next if $dgn eq 'templates';

    foreach my $instance (keys %{$lookup->{$dgn}}) {
        foreach my $config (@{$lookup->{$dgn}->{$instance}}) {

            # Merge template values into configuration if present
            if (exists $config->{'<<'}) {
                my %merged_config = (%{$config->{'<<'}}, %$config);
                $config = \%merged_config;
                delete $config->{'<<'};
            }

            # Ensure that ha_name is defined before proceeding
            unless (defined $config->{ha_name}) {
                log_to_journald("Missing ha_name for DGN $dgn, instance $instance", LOG_ERR);
                next;
            }

            # Expand and subscribe to the command topic
            my $command_topic = expand_template($config->{command_topic}, $config->{ha_name});

            # Clear retained messages for command topic if defined
            $mqtt->retain($command_topic, '') if $command_topic;

            if ($command_topic) {
                if ($config->{device_class} && $config->{device_class} eq 'lock') {
                    # Subscribe specifically for lock/unlock commands
                    $mqtt->subscribe($command_topic => sub {
                        my ($topic, $message) = @_;
                        log_to_journald("Received Lock/Unlock command on $topic: $message", LOG_DEBUG);
                        process_mqtt_command($instance, $config, $message, 'lock');
                    });
                } else {
                    # Subscribe for other commands (state changes, etc.)
                    $mqtt->subscribe($command_topic => sub {
                        my ($topic, $message) = @_;
                        log_to_journald("Received MQTT message on $topic: $message", LOG_DEBUG);
                        process_mqtt_command($instance, $config, $message, 'state');
                    });
                }
            } else {
                log_to_journald("Failed to expand command topic for ha_name $config->{ha_name}", LOG_ERR);
            }

            # If the device is dimmable, expand and subscribe to the brightness command topic
            if ($config->{dimmable}) {
                my $brightness_command_topic = expand_template($config->{brightness_command_topic}, $config->{ha_name});

                # Clear retained messages for brightness command topic if defined
                $mqtt->retain($brightness_command_topic, '') if $brightness_command_topic;

                if ($brightness_command_topic) {
                    $mqtt->subscribe($brightness_command_topic => sub {
                        my ($topic, $message) = @_;
                        log_to_journald("Received brightness command on $topic: $message", LOG_DEBUG);
                        process_mqtt_command($instance, $config, $message, 'brightness');
                    });
                } else {
                    log_to_journald("Failed to expand brightness command topic for ha_name $config->{ha_name}", LOG_ERR);
                }
            }
        }
    }
}

# Notify systemd that the script has started successfully
systemd_notify("READY=1");

# Main loop to keep the script running
while ($keep_running) {
    try {
        $mqtt->tick();
    } catch {
        log_to_journald("Error during MQTT tick: $_", LOG_ERR);
    };
    sleep(1);  # Sleep to prevent high CPU usage
}

log_to_journald("Exiting main loop. Cleaning up...", LOG_INFO);
exit(0);

# Process incoming MQTT commands and convert to CAN bus messages
sub process_mqtt_command {
    my ($instance, $config, $message, $command_type) = @_;

    log_to_journald("Entering process_mqtt_command with message: $message, command_type: $command_type, ha_name: $config->{ha_name}", LOG_DEBUG);

    # Ensure instance is numeric or set to a default value (like 0)
    $instance = defined($instance) && $instance ne '' ? $instance : 0;

    my $command;
    my $brightness;
    my $duration = 0; # Default duration is 0 for state commands
    my $reverse;      # Variable for reverse ID

    if ($command_type eq 'state') {
        log_to_journald("Processing state command: $message", LOG_DEBUG);

        if ($message eq 'ON') {
            # Use the last brightness value if available, otherwise use default
            $brightness = $config->{last_brightness} // 125;  # Default brightness
            $command = 0;  # Set level command to turn on with the current brightness
            log_to_journald("State command ON for $config->{ha_name} with brightness $brightness", LOG_DEBUG);
        } elsif ($message eq 'OFF') {
            $command = 3;  # OFF command
            $brightness = undef;  # No brightness value when turning off
            log_to_journald("State command OFF for $config->{ha_name}", LOG_DEBUG);
        }

        # Construct CAN bus command for state commands (ON/OFF)
        log_to_journald("Constructing CAN bus command for state command: $message", LOG_DEBUG);

        my $prio = 6;
        my $dgnhi = '1FE';
        my $dgnlo = 'DB';
        my $srcAD = 99;
        $duration = 255;  # Default duration for state commands (lights)

        my $binCanId = sprintf("%b0%b%b%b", hex($prio), hex($dgnhi), hex($dgnlo), hex($srcAD));
        my $hexCanId = sprintf("%08X", oct("0b$binCanId"));
        $brightness = defined($brightness) ? int($brightness * 2) : 0xFF;  # Adjust brightness for CAN data
        my $hexData = sprintf("%02XFF%02X%02X%02X00FFFF", $instance, $brightness, $command, $duration);

        log_to_journald("Sending CAN bus command for lights: cansend $can_interface $hexCanId#$hexData", LOG_INFO);
        send_can_command($can_interface, $hexCanId, $hexData);

    } elsif ($command_type eq 'brightness') {
        log_to_journald("Processing brightness command: $message", LOG_DEBUG);

        $brightness = $message;
        $command = 0;  # Set level command
        $config->{last_brightness} = $brightness;  # Save brightness for subsequent ON commands
        log_to_journald("Brightness command set to $brightness for $config->{ha_name}", LOG_DEBUG);

        # Handle brightness changes
        log_to_journald("Handling brightness change for $config->{ha_name}", LOG_DEBUG);

        # Construct CAN bus command for brightness
        my $prio = 6;
        my $dgnhi = '1FE';
        my $dgnlo = 'DB';
        my $srcAD = 99;
        $duration = 255;  # Duration for brightness command

        my $binCanId = sprintf("%b0%b%b%b", hex($prio), hex($dgnhi), hex($dgnlo), hex($srcAD));
        my $hexCanId = sprintf("%08X", oct("0b$binCanId"));
        $brightness = int($brightness * 2);  # Convert brightness to appropriate scale
        my $hexData = sprintf("%02XFF%02X%02X%02X00FFFF", $instance, $brightness, $command, $duration);

        log_to_journald("Sending CAN bus command for brightness: cansend $can_interface $hexCanId#$hexData", LOG_INFO);
        send_can_command($can_interface, $hexCanId, $hexData);

        finalize_brightness_setting($instance, $config->{ha_name});

    } elsif ($command_type eq 'lock') {
        log_to_journald("Processing lock command: $message", LOG_DEBUG);

        # Extract instance from payload (LOCK_14 or UNLOCK_17)
        if ($message =~ /^LOCK_(\d+)$/) {
            $instance = $1;
            $reverse = 89;  # Reverse ID for lock command
            $command = 1;  # Lock command
            $duration = 1;  # Lock/Unlock action duration set to 1 second
            log_to_journald("Locking device $config->{ha_name} with instance $instance", LOG_INFO);
        } elsif ($message =~ /^UNLOCK_(\d+)$/) {
            $instance = $1;
            $reverse = 86;  # Reverse ID for unlock command
            $command = 1;  # Unlock command
            $duration = 1;  # Lock/Unlock action duration set to 1 second
            log_to_journald("Unlocking device $config->{ha_name} with instance $instance", LOG_INFO);
        } else {
            log_to_journald("Unknown command for lock: $message", LOG_ERR);
            return;
        }

        # Construct CAN bus command for stopping the opposing instance
        my $prio = 6;
        my $dgnhi = '1FE';
        my $dgnlo = 'DB';
        my $srcAD = 99;
        my $stop_command = 3;  # Stop command for the opposing instance
        my $stop_duration = 0; # Duration for stop command

        my $binCanId = sprintf("%b0%b%b%b", hex($prio), hex($dgnhi), hex($dgnlo), hex($srcAD));
        my $hexCanId = sprintf("%08X", oct("0b$binCanId"));

        # Send stop command for opposing instance
        my $stopHexData = sprintf("%02XFF%02X%02X%02X00FFFF", $reverse, 0, $stop_command, $stop_duration);
        log_to_journald("Sending CAN bus command to stop opposing instance: cansend $can_interface $hexCanId#$stopHexData", LOG_INFO);
        send_can_command($can_interface, $hexCanId, $stopHexData);

        # Construct CAN bus command for lock/unlock
        my $desired_level = 200;  # Desired level to 100% (200 in decimal or C8 in hex)
        my $hexData = sprintf("%02XFF%02X%02X%02X00FFFF", $instance, $desired_level, $command, $duration);

        log_to_journald("Sending CAN bus command: cansend $can_interface $hexCanId#$hexData", LOG_INFO);

        # Send the lock/unlock CAN bus command
        send_can_command($can_interface, $hexCanId, $hexData);

    } else {
        log_to_journald("Unknown command type: $command_type for $config->{ha_name}", LOG_ERR);
    }
}

# Subroutine to finalize brightness setting
sub finalize_brightness_setting {
    my ($instance, $ha_name) = @_;

    log_to_journald("Finalizing brightness setting for $ha_name", LOG_INFO);

    my $command = 21;  # Command for ramp up/down
    my $duration = 0;
    my $prio = 6;
    my $dgnhi = '1FE';
    my $dgnlo = 'DB';
    my $srcAD = 99;

    my $binCanId = sprintf("%b0%b%b%b", hex($prio), hex($dgnhi), hex($dgnlo), hex($srcAD));
    my $hexCanId = sprintf("%08X", oct("0b$binCanId"));

    # Ramp Up/Down Command
    my $hexData = sprintf("%02XFF%02X%02X%02X00FFFF", $instance, 0, $command, $duration);
    send_can_command($can_interface, $hexCanId, $hexData);

    # Stop Command
    $command = 4;
    $hexData = sprintf("%02XFF%02X%02X%02X00FFFF", $instance, 0, $command, $duration);
    send_can_command($can_interface, $hexCanId, $hexData);
}

# Subroutine to send CAN bus command
sub send_can_command {
    my ($can_interface, $hexCanId, $hexData) = @_;

    # Acquire the mutex lock before sending the CAN bus command
    {
        lock($can_bus_mutex);

        # Log the CAN bus command that would be sent
        log_to_journald("CAN bus command: cansend $can_interface $hexCanId#$hexData", LOG_INFO);

        try {
            # Uncomment the line below to enable CAN bus sending
            system("cansend $can_interface $hexCanId#$hexData") if (!$debug);
        } catch {
            log_to_journald("Error sending CAN bus command: $_", LOG_ERR);
        };
    }
}

# Handle shutdown gracefully
sub shutdown_gracefully {
    my ($signal) = @_;
    log_to_journald("Received $signal signal. Shutting down...", LOG_INFO);
    $keep_running = 0;  # Signal the main loop to exit
}

# Initialize and connect to the MQTT broker, with retry logic and LWT
sub initialize_mqtt {
    my $mqtt;
    my $success = 0;

    for (my $attempt = 1; $attempt <= $max_retries; $attempt++) {
        no warnings 'exiting';
        try {
            my $connection_string = "$mqtt_host:$mqtt_port";
            
            # Create and configure MQTT client
            log_to_journald("Connecting to $mqtt_host:$mqtt_port...", LOG_INFO);
            $mqtt = Net::MQTT::Simple->new($connection_string);
            log_to_journald("MQTT client created.", LOG_INFO);
            $mqtt->login($mqtt_username, $mqtt_password) if $mqtt_username && $mqtt_password;
            log_to_journald("MQTT login successful.", LOG_INFO);

            # Set Last Will and Testament (LWT) for availability
            $mqtt->last_will("hass2rvc/status", "offline", 1);  # Set LWT with topic, message, and retain flag
            log_to_journald("LWT set to 'offline' on hass2rvc/status", LOG_INFO);

            # Publish "online" status after successful connection
            $mqtt->retain("hass2rvc/status", "online");

            # Test MQTT connection by subscribing and publishing to a test topic
            my $test_topic = "hass2rvc/connection_check";
            my $message_received;
            $mqtt->subscribe($test_topic => sub {
                my ($topic, $message) = @_;
                log_to_journald("Received message on $test_topic: $message", LOG_DEBUG) if $debug;
                $message_received = $message;
            });

            # Publish a test message to confirm connectivity
            $mqtt->publish($test_topic, "MQTT startup successful");

            # Wait for a confirmation message from the broker
            for (my $wait = 0; $wait < 5; $wait++) {
                last if $message_received;
                $mqtt->tick();
                sleep(1);
            }

            if ($message_received && $message_received eq "MQTT startup successful") {
                log_to_journald("Successfully connected to MQTT broker on attempt $attempt.", LOG_INFO);
                $success = 1;
                last;
            } else {
                log_to_journald("Failed to receive confirmation message on attempt $attempt.", LOG_WARNING);
                $mqtt = undef;
            }
        }
        catch {
            my $error_msg = $_;
            log_to_journald("Error caught: $error_msg", LOG_ERR);

            if ($error_msg =~ /connect: Connection refused/) {
                log_to_journald("Connection refused by MQTT broker. Please check if the broker is running and accessible.", LOG_ERR);
            } else {
                log_to_journald("Failed to connect to MQTT on attempt $attempt: $error_msg", LOG_ERR);
            }
            $mqtt = undef;
            sleep($retry_delay) if $attempt < $max_retries;
        };
    }

    # Check if the connection was successful
    if ($success) {
        # Return MQTT object on success
        return $mqtt;
    } else {
        log_to_journald("Failed to connect to MQTT broker after $max_retries attempts. Exiting.", LOG_ERR);
        die "Failed to connect to MQTT broker after $max_retries attempts.";
    }
}

# Start the watchdog thread to monitor the system's health and MQTT connectivity
sub start_watchdog {
    my $heartbeat_topic = "hass2rvc/heartbeat";
    my $heartbeat_received = 0;

    # Subscribe to the heartbeat topic to listen for confirmation messages
    $mqtt->subscribe($heartbeat_topic => sub {
        my ($topic, $message) = @_;
        log_to_journald("Received heartbeat on $heartbeat_topic: $message", LOG_DEBUG) if $debug;
        if ($message eq "Heartbeat message from watchdog") {
            $heartbeat_received = 1;  # Set the flag when the correct heartbeat is received
        }
    });

    # Start a detached thread to handle watchdog functionality
    my $watchdog_thread = threads->create(sub {
        while ($keep_running) {
            my $mqtt_success = 0;

            try {
                # Reset the heartbeat_received flag for each watchdog loop iteration
                $heartbeat_received = 0;

                # Publish a heartbeat message to MQTT
                $mqtt->publish($heartbeat_topic, "Heartbeat message from watchdog");
                log_to_journald("Published heartbeat message to MQTT", LOG_DEBUG) if $debug;

                # Wait for a confirmation message, checking periodically
                for (my $wait = 0; $wait < 5; $wait++) {  # Reduced the loop for quicker feedback
                    for (1..10) { 
                        $mqtt->tick(); 
                        sleep(0.1);  # Shorter sleep, making it more responsive
                    }
                    if ($heartbeat_received) {  # If heartbeat is received, break the loop
                        $mqtt_success = 1;
                        last;
                    }
                }

                # If no heartbeat was received, log an error and exit
                if (!$mqtt_success) {
                    log_to_journald("Failed to receive heartbeat confirmation. Exiting.", LOG_ERR);
                    die "Error in watchdog loop: Failed to receive heartbeat confirmation. Exiting.";
                }

            } catch {
                # Catch and log any errors that occur in the watchdog loop
                log_to_journald("Error in watchdog loop: $_. Exiting.", LOG_ERR);
                die "Error in watchdog loop: $_. Exiting.";
            };

            # Notify systemd that the process is still alive if MQTT was successful
            if ($mqtt_success) {
                log_to_journald("Notifying systemd watchdog.", LOG_DEBUG) if $debug;
                if (systemd_notify("WATCHDOG=1")) {
                    log_to_journald("Systemd watchdog notified successfully.", LOG_INFO) if $debug;
                } else {
                    log_to_journald("Failed to notify systemd watchdog.", LOG_ERR);
                }
            }

            sleep($watchdog_interval);  # Sleep for the specified interval before next loop
        }
    });

    # Detach the thread to allow it to run independently
    $watchdog_thread->detach();

    # Cleanup hook for thread termination
    $SIG{'INT'} = sub { 
        log_to_journald("Received INT signal. Exiting watchdog thread.", LOG_INFO);
        $keep_running = 0;
    };
    $SIG{'TERM'} = sub { 
        log_to_journald("Received TERM signal. Exiting watchdog thread.", LOG_INFO);
        $keep_running = 0;
    };
}

# Function to replace template variables in topics
sub expand_template {
    my ($template, $ha_name) = @_;

    if (!defined $ha_name || $ha_name eq '') {
        log_to_journald("Undefined or empty ha_name in template expansion", LOG_ERR);
        return $template;
    }

    # Perform the substitution
    $template =~ s/\{\{ ha_name \}\}/$ha_name/g;

    # Debug log to verify template expansion if debugging is enabled
    log_to_journald("Expanded template for ha_name $ha_name: $template", LOG_DEBUG) if $debug;

    return $template;
}

# Log messages to journald
sub log_to_journald {
    my ($message, $level) = @_;
    
    $level //= LOG_INFO;  # Default log level is INFO
    return if $level > $log_level;  # Skip logging if message level is higher than current log level

    openlog('hass2rvc', 'cons,pid', LOG_USER);
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
