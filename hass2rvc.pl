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
use threads::shared;  # Required for shared variables and locks

# Command-line options
my $debug = 0;
my $log_level = LOG_INFO;
GetOptions("debug" => \$debug, "log-level=i" => \$log_level);

# Set log level for debugging
$log_level = LOG_DEBUG if $debug;

# Configuration Variables
my $mqtt_host = $ENV{MQTT_HOST} || "localhost";
my $mqtt_port = $ENV{MQTT_PORT} || 1883;
my $mqtt_username = $ENV{MQTT_USERNAME};
my $mqtt_password = $ENV{MQTT_PASSWORD};
my $max_retries = 5;
my $retry_delay = 5;  # Time to wait between retry attempts in seconds
my $can_interface = 'can0';
my $watchdog_usec = $ENV{WATCHDOG_USEC} // 0;
my $watchdog_interval = $watchdog_usec ? int($watchdog_usec / 2 / 1_000_000) : 0;  # Convert microseconds to seconds and halve it for watchdog interval
my $can_bus_mutex :shared; # Mutex to ensure only one CAN bus message is sent at a time

# Only log environment variables if debugging is enabled
log_to_journald("Environment: " . join(", ", map { "$_=$ENV{$_}" } grep { $_ !~ /PASSWORD|SECRET/ } keys %ENV), LOG_DEBUG) if $debug;

$ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;  # Allow unencrypted connection with credentials

# Initialize MQTT connection
my $mqtt = initialize_mqtt();

# Start Watchdog thread if configured
start_watchdog(\$mqtt, $watchdog_interval) if $watchdog_interval;

# Load YAML files containing specifications and device configurations
my $script_dir = dirname(__FILE__);
my $lookup = LoadFile("$script_dir/config/coach-devices.yml");

# Subscribe to MQTT topics for all devices
foreach my $dgn (keys %$lookup) {
    foreach my $instance (keys %{$lookup->{$dgn}}) {
        my $config = $lookup->{$dgn}->{$instance};
        my $command_topic = expand_template($config->{command_topic}, $config->{ha_name});
        $mqtt->subscribe($command_topic => sub {
            my ($topic, $message) = @_;
            process_mqtt_command($config, $message, 'state');
        });

        if ($config->{dimmable}) {
            my $brightness_command_topic = expand_template($config->{brightness_command_topic}, $config->{ha_name});
            $mqtt->subscribe($brightness_command_topic => sub {
                my ($topic, $message) = @_;
                process_mqtt_command($config, $message, 'brightness');
            });
        }
    }
}

# Add a simple loop to keep the script running
while (1) {
    $mqtt->tick();
    sleep(1);  # Adjust sleep duration as needed to control tick frequency
}

# Process incoming MQTT commands and convert to CAN bus messages
sub process_mqtt_command {
    my ($config, $message, $command_type) = @_;
    my $instance = $config->{instance};
    my $command = 0;
    my $brightness = 125;  # Default brightness

    # Determine command based on message type
    if ($command_type eq 'state') {
        $command = ($message eq 'ON') ? 2 : 3;  # ON -> command 2, OFF -> command 3
        $brightness = '' if $message eq 'OFF';
    } elsif ($command_type eq 'brightness') {
        $brightness = $message;
        $command = ($brightness > 0) ? 0 : 3;  # If brightness > 0, set level, else OFF
    }

    # Convert brightness percentage to scale
    $brightness = int($brightness * 2) if $brightness ne '';

    # Construct CAN bus command
    my $prio = 6;
    my $dgnhi = '1FE';
    my $dgnlo = 'DB';
    my $srcAD = 99;
    my $duration = 255;
    my $bypass = 0;

    my $binCanId = sprintf("%b0%b%b%b", hex($prio), hex($dgnhi), hex($dgnlo), hex($srcAD));
    my $hexData = sprintf("%02XFF%02X%02X%02X00FFFF", $instance, $brightness, $command, $duration);
    my $hexCanId = sprintf("%08X", oct("0b$binCanId"));

    # Send the main CAN bus command
    send_can_command($can_interface, $hexCanId, $hexData);

    # If $command is 0 or 17, additional commands would be sent
    if ($command == 0 || $command == 17) {
        # Prepare and send the first additional command
        $brightness = 0;
        $command = 21;
        $duration = 0;
        $hexData = sprintf("%02XFF%02X%02X%02X00FFFF", $instance, $brightness, $command, $duration);
        send_can_command($can_interface, $hexCanId, $hexData);

        # Prepare and send the second additional command
        $command = 4;
        $hexData = sprintf("%02XFF%02X%02X%02X00FFFF", $instance, $brightness, $command, $duration);
        send_can_command($can_interface, $hexCanId, $hexData);
    }
}

# Subroutine to send CAN bus command
sub send_can_command {
    my ($can_interface, $hexCanId, $hexData) = @_;

    # Acquire the mutex lock before sending the CAN bus command
    {
        lock($can_bus_mutex);

        # Log the CAN bus command that would be sent
        log_to_journald("CAN bus command: cansend $can_interface $hexCanId#$hexData", LOG_INFO);

        # Actually send the command to the CAN bus
        #system("cansend $can_interface $hexCanId#$hexData") if (!$debug);
    }
}

# Initialize and connect to the MQTT broker, with retry logic and LWT
sub initialize_mqtt {
    my $mqtt;
    my $success = 0;  # Flag to track if connection was successful
    
    for (my $attempt = 1; $attempt <= $max_retries; $attempt++) {
        no warnings 'exiting';  # Suppress 'exiting' warnings within this scope
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
    my $heartbeat_topic = "hass2rvc/heartbeat";
    my $heartbeat_received = 0;
    my $keep_running = 1;

    # Subscribe to the heartbeat topic to listen for confirmation messages
    $mqtt->subscribe($heartbeat_topic => sub {
        my ($topic, $message) = @_;
        log_to_journald("Received heartbeat on $heartbeat_topic: $message", LOG_DEBUG) if $debug;
        if ($message eq "Heartbeat message from watchdog") {
            $heartbeat_received = 1;
        }
    });

    # Start a detached thread to handle watchdog functionality
    my $watchdog_thread = threads->create(sub {
        while ($keep_running) {
            my $mqtt_success = 0;

            try {
                # Reset the heartbeat_received flag
                $heartbeat_received = 0;

                # Publish a heartbeat message to MQTT
                $mqtt->publish($heartbeat_topic, "Heartbeat message from watchdog");
                log_to_journald("Published heartbeat message to MQTT", LOG_DEBUG) if $debug;

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
                if ($debug) {
                    log_to_journald("Notifying systemd watchdog.", LOG_DEBUG);
                }
                if (systemd_notify("WATCHDOG=1")) {
                    log_to_journald("Systemd watchdog notified successfully.", LOG_INFO) if $debug;
                } else {
                    log_to_journald("Failed to notify systemd watchdog.", LOG_ERR);
                }
            }

            sleep($watchdog_interval);
        }
    });

    $watchdog_thread->detach();  # Detach the thread to allow it to run independently

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

    # Check if the template is defined and non-empty
    if (!defined $template || $template eq '') {
        log_to_journald("Undefined or empty template provided for ha_name: $ha_name", LOG_ERR);
        return '';  # Return an empty string to avoid further issues
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
    
    $level //= LOG_INFO;  # Default log level if not provided
    return if $level > $log_level;  # Skip logging if below the current log level

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
