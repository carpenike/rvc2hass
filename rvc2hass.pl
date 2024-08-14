#!/usr/bin/perl -w

use strict;
use warnings;
use File::Temp qw(tempdir);
use YAML::Tiny;
use JSON qw(encode_json);
use Net::MQTT::Simple;
use Try::Tiny;
use IO::Socket::UNIX;
use threads;
use Time::HiRes qw(sleep);
use File::Basename;
use Sys::Syslog qw(:standard :macros);

# Pre-start checks
log_to_journald("Environment: " . join(", ", map { "$_=$ENV{$_}" } keys %ENV));

# Configuration
my $mqtt_host = "localhost";
my $mqtt_port = 1883;  # Define the MQTT port

# Create a temporary directory for undefined DGNs
my $temp_dir = tempdir(CLEANUP => 1);
my $undefined_dgns_file = "$temp_dir/undefined_dgns.log";

# Log the temp directory path to journald
log_to_journald("Temporary directory created at: $temp_dir");

# Get the directory of the currently running script
my $script_dir = dirname(__FILE__);

# Load YAML files
my $yaml_specs = YAML::Tiny->read("$script_dir/rvc-spec.yml");
my $decoders = $yaml_specs->[0] if $yaml_specs;

my $yaml_lookup = YAML::Tiny->read("$script_dir/coach-devices.yml");
my $lookup = $yaml_lookup->[0] if $yaml_lookup;

# MQTT initialization with retries
my $mqtt;
my $max_retries = 5;
my $retry_delay = 5;  # seconds

for (my $attempt = 1; $attempt <= $max_retries; $attempt++) {
    try {
        $mqtt = Net::MQTT::Simple->new("$mqtt_host:$mqtt_port");
        return;  # Exit the loop if connection is successful
    }
    catch {
        log_to_journald("Attempting to reconnect to MQTT: Attempt $attempt");
        sleep($retry_delay) if $attempt < $max_retries;
        log_to_journald("Failed to connect to MQTT after $max_retries attempts") if $attempt == $max_retries;
    }
}

# Systemd watchdog initialization
my $watchdog_interval = int($ENV{WATCHDOG_USEC} / 2 / 1_000_000);  # Convert microseconds to seconds and halve it

# Start watchdog thread
threads->create(sub {
    while (1) {
        systemd_notify("WATCHDOG=1");
        sleep($watchdog_interval);
    }
})->detach;

# Open CAN bus data stream
open my $file, 'candump -ta can0 |' or die "Cannot start candump: $!\n";

while (my $line = <$file>) {
    #print "Received line: $line\n";  # Debug line
    chomp $line;
    my @parts = split ' ', $line;
    process_packet(@parts);
}
close $file;

sub process_packet {
    my @parts = @_;
    my $binCanId = sprintf("%b", hex($parts[2]));
    my $dgn = sprintf("%05X", oct("0b" . substr($binCanId, 4, 17)));  # DGN extraction

    # Extract instance from packet
    my $instance = $result->{'instance'};

    # Check if the DGN and instance exist in the lookup
    if (exists $lookup->{$dgn} && exists $lookup->{$dgn}->{$instance}) {
        my $configs = $lookup->{$dgn}->{$instance};
        my $result = decode($dgn, join '', @parts[4..$#parts]);

        if ($result) {
            foreach my $config (@$configs) {
                publish_mqtt($config, $result);
            }
        } else {
            log_to_journald("No data to publish for DGN $dgn and instance $instance");
        }
    } else {
        log_to_temp_file($dgn);
    }
}


sub publish_mqtt {
    my ($dgn, $result) = @_;  # Declare parameters for the function
    my $config = $lookup->{$dgn};

    # Ensure we have a configuration
    return unless $config;

    my $ha_name = $config->{ha_name};
    my $friendly_name = $config->{friendly_name};
    my $state_topic = $config->{state_topic};

    # Determine the discovery topic based on the device_type
    my $device_type = $config->{device_type} // 'sensor';  # Default to 'sensor' if not defined
    my $config_topic = "homeassistant/$device_type/$ha_name/config";

    # Prepare the MQTT configuration message
    my %config_message = (
        name => $friendly_name,
        state_topic => $state_topic,
        value_template => $config->{value_template},
        device_class => $config->{device_class},  # Include device_class if applicable
        unique_id => $ha_name,  # Ensure unique ID for the device
        json_attributes_topic => $state_topic
    );

    my $config_json = encode_json(\%config_message);
    $mqtt->retain($config_topic, $config_json);

    # Publish the state message
    my $state_json = encode_json($result);
    $mqtt->retain($state_topic, $state_json);
}


sub decode {
    my ($dgn, $data) = @_;
    print "Decoding DGN: $dgn with data: $data\n";  # Debug line
    my %result;

    # Fetch the decoder configuration for the given DGN from rvc-spec.yml
    my $decoder = $decoders->{$dgn};
    unless ($decoder) {
        print "No decoder found for DGN: $dgn\n";  # Debug line
        return;
    }

    try {
        # Process each parameter based on the decoder's specifications
        foreach my $param (@{$decoder->{parameters}}) {
            my $bytes = get_bytes($data, $param->{byte});  # Adjusted to handle byte ranges
            my $value = $bytes;

            # Handle bit-level extraction if specified
            if (defined $param->{bit}) {
                my $bit_range = $param->{bit};
                my ($start_bit, $end_bit) = split('-', $bit_range);
                $value = extract_bits($value, $start_bit, $end_bit);
            }

            # Convert the value to the appropriate type (e.g., integer, hex)
            $result{$param->{name}} = hex($value);  # Example conversion, adjust as needed
        }
        return \%result;
    }
    catch {
        log_to_journald("Error decoding DGN $dgn: $_");
        return undef;  # Return undef on error
    }
}

sub get_bytes {
    my ($data, $byterange) = @_;

    my ($start_byte, $end_byte) = split(/-/, $byterange);
    $end_byte = $start_byte if !defined $end_byte;  # If no range, end_byte is the same as start_byte

    my $byte_str = substr($data, $start_byte * 2, ($end_byte - $start_byte + 1) * 2);  # Extract the byte(s)

    # Swap the order of bytes if a range is requested (LSB first)
    $byte_str = join '', reverse split(/(..)/, $byte_str) if $start_byte != $end_byte;

    return $byte_str;
}

sub extract_bits {
    my ($value, $start_bit, $end_bit) = @_;
    my $bits = unpack('B*', pack('H*', $value));  # Convert hex to binary
    return substr($bits, $start_bit, $end_bit - $start_bit + 1);
}

sub log_to_temp_file {
    my ($dgn) = @_;

    # Read the file to check if the DGN is already logged
    open my $fh, '<', $undefined_dgns_file;
    while (my $line = <$fh>) {
        chomp $line;
        return if $line eq $dgn;  # DGN already logged, exit the subroutine
    }
    close $fh;

    # If not already logged, append the DGN to the file
    open $fh, '>>', $undefined_dgns_file or do {
        log_to_journald("Failed to open log file for undefined DGN $dgn: $!");
        die "Cannot open undefined DGN log file: $!";
    };
    print $fh "$dgn\n";
    close $fh;

    log_to_journald("Logged undefined DGN $dgn to temporary file: $undefined_dgns_file");
}

sub log_to_journald {
    my ($message) = @_;

    # Open a connection to syslog
    openlog('rvc2hass', 'cons,pid', LOG_USER);

    # Log the message
    syslog(LOG_INFO, $message);

    # Close the connection to syslog
    closelog();
}

sub systemd_notify {
    my ($state) = @_;
    my $socket_path = $ENV{NOTIFY_SOCKET} // return;

    socket(my $socket, PF_UNIX, SOCK_DGRAM, 0) or die "socket: $!";
    my $dest = sockaddr_un($socket_path);
    send($socket, $state, 0, $dest) or die "send: $!";
    close($socket);
}
