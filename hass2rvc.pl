#!/usr/bin/perl -w

use strict;
use warnings;
use Net::MQTT::Simple;
use Try::Tiny;
use IO::Socket::UNIX;
use Sys::Syslog qw(:standard :macros);
use Getopt::Long;
use threads;
use Thread::Queue;
use Time::HiRes qw(sleep);
use YAML::Tiny;

# Command-line options
my $debug = 0;
GetOptions("debug" => \$debug);

# Pre-start checks
log_to_journald("Environment: " . join(", ", map { "$_=$ENV{$_}" } keys %ENV));

# Configuration
my $mqtt_host = $ENV{'MQTT_HOST'} // 'localhost';
my $mqtt_port = $ENV{'MQTT_PORT'} // 1883;
my $mqtt_username = $ENV{'MQTT_USERNAME'};
my $mqtt_password = $ENV{'MQTT_PASSWORD'};
my $max_retries = 5;
my $retry_delay = 5;  # seconds

# MQTT initialization with retries
my $mqtt;
for (my $attempt = 1; $attempt <= $max_retries; $attempt++) {
    try {
        my $connection_string = $mqtt_username && $mqtt_password 
            ? "$mqtt_username:$mqtt_password\@$mqtt_host:$mqtt_port" 
            : "$mqtt_host:$mqtt_port";
        
        $mqtt = Net::MQTT::Simple->new($connection_string);
        last;  # Exit the loop if connection is successful
    }
    catch {
        log_to_journald("Attempting to reconnect to MQTT: Attempt $attempt");
        sleep($retry_delay) if $attempt < $max_retries;
        log_to_journald("Failed to connect to MQTT after $max_retries attempts") if $attempt == $max_retries;
    }
}

# Check if the MQTT connection was successful before trying to subscribe
unless (defined $mqtt) {
    die "Failed to connect to MQTT broker after $max_retries attempts.";
}

# Global MQTT subscription for command topics
foreach my $dgn (keys %$lookup) {
    foreach my $instance (keys %{$lookup->{$dgn}}) {
        my $configs = $lookup->{$dgn}->{$instance};
        foreach my $config (@$configs) {
            my $command_topic = $config->{command_topic};  # If command_topic is defined
            if ($command_topic) {
                $mqtt->subscribe($command_topic => sub {
                    my ($topic, $message) = @_;
                    log_to_journald("Received command on topic $topic: $message");
                    my $command_message = decode_json($message);
                    process_command($config, $command_message);
                    log_to_journald("Processed command on topic $topic for device $config->{ha_name}");
                });
            }
        }
    }
}

# Main loop or other logic goes here...

# Subroutine for handling commands
sub process_command {
    my ($config, $command_message) = @_;

    # Example logic for processing a command
    if ($config->{device_type} eq 'light') {
        my $dgn = $config->{dgn};
        my $instance = $config->{instance};

        my $command;
        my $brightness;

        # Determine the command based on the incoming message
        if (exists $command_message->{state}) {
            if ($command_message->{state} eq 'ON') {
                $command = 17;  # Example command for turning on a dimmable light
                $brightness = 100;  # Default to full brightness if not specified
            } elsif ($command_message->{state} eq 'OFF') {
                $command = 3;  # Example command for turning off the light
                $brightness = 0;
            }
        }

        # Handle brightness level if specified
        if (exists $command_message->{brightness}) {
            $brightness = $command_message->{brightness};
            $command = 17 if !defined $command;  # Set command to adjust brightness if not already set
        }

        # Lock before sending CAN bus message
        {
            lock($canbus_mutex);

            # Construct CAN bus message
            if (defined $command && defined $brightness) {
                my $prio = 6;  # Priority level (adjust as needed)
                my $dgnhi = substr($dgn, 0, 3);  # High part of the DGN
                my $dgnlo = substr($dgn, 3, 2);  # Low part of the DGN
                my $srcAD = 99;  # Source address (adjust as needed)

                my $binCanId = sprintf("%b0%b%b%b", hex($prio), hex($dgnhi), hex($dgnlo), hex($srcAD));
                my $hexCanId = sprintf("%08X", oct("0b$binCanId"));
                my $hexData = sprintf("%02XFF%02X%02X%02X00FFFF", $instance, $brightness * 2, $command, 255);

                # Send the command to the CAN bus
                system('cansend can0 '.$hexCanId."#".$hexData);
                log_to_journald("Sent CAN bus message: $hexCanId#$hexData for light $config->{ha_name}");
            } else {
                log_to_journald("Invalid command or brightness value for light $config->{ha_name}");
            }
        }
    } else {
        log_to_journald("process_command received a non-light device type: $config->{device_type}");
    }
}

# Subroutine for logging to journald
sub log_to_journald {
    my ($message) = @_;

    # Open a connection to syslog
    openlog('hass2rvc', 'cons,pid', LOG_USER);

    # Log the message
    syslog(LOG_INFO, $message);

    # Close the connection to syslog
    closelog();
}

# Other subroutines and logic...

