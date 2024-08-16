#!/usr/bin/perl -w

use strict;
use warnings;
use File::Temp qw(tempdir);
use YAML::Tiny;
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

# Pre-start checks
log_to_journald("Environment: " . join(", ", map { "$_=$ENV{$_}" } keys %ENV));

# Allow unencrypted connection with credentials
$ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;

# Configuration
my $mqtt_host = $ENV{MQTT_HOST} || "localhost";
my $mqtt_port = $ENV{MQTT_PORT} || 1883;
my $mqtt_username = $ENV{MQTT_USERNAME};
my $mqtt_password = $ENV{MQTT_PASSWORD};
my $mqtt_clientid = $ENV{MQTT_CLIENTID} || "rvc";
my $max_retries = 5;
my $retry_delay = 5;  # seconds

# MQTT initialization with retries
my $mqtt;
for (my $attempt = 1; $attempt <= $max_retries; $attempt++) {
    try {
        my $connection_string = "$mqtt_host:$mqtt_port";
        
        # Create the MQTT client with a specific client ID
        $mqtt = Net::MQTT::Simple->new($connection_string);
        $mqtt->login($mqtt_username, $mqtt_password) if $mqtt_username && $mqtt_password;
        $mqtt->set_client_id($mqtt_clientid);  # Set the client ID

        # Test the connection by attempting to publish to a known topic
        $mqtt->publish("test/connection", "MQTT connection successful");
        log_to_journald("Successfully connected to MQTT broker on attempt $attempt.");
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
    log_to_journald("Failed to connect to MQTT broker after $max_retries attempts.");
    die "Failed to connect to MQTT broker after $max_retries attempts.";  # Exit the script
}

# Systemd watchdog initialization
my $watchdog_usec = $ENV{WATCHDOG_USEC} // 0;
my $watchdog_interval = $watchdog_usec ? int($watchdog_usec / 2 / 1_000_000) : 0;

# Start watchdog thread if watchdog is enabled
if ($watchdog_interval) {
    threads->create(sub {
        while (1) {
            systemd_notify("WATCHDOG=1");
            sleep($watchdog_interval);
        }
    })->detach;
}

# Get the directory of the currently running script
my $script_dir = dirname(__FILE__);

# Load YAML files
my $yaml_specs = YAML::Tiny->read("$script_dir/config/rvc-spec.yml");
my $decoders = $yaml_specs->[0] if $yaml_specs;

my $yaml_lookup = YAML::Tiny->read("$script_dir/config/coach-devices.yml");
my $lookup = $yaml_lookup->[0] if $yaml_lookup;

# Create a temporary directory for undefined DGNs
my $temp_dir = tempdir(CLEANUP => 1);
my $undefined_dgns_file = "$temp_dir/undefined_dgns.log";

# Log the temp directory path to journald
log_to_journald("Temporary directory created at: $temp_dir");

# Open CAN bus data stream
open my $file, '-|', 'candump', '-ta', 'can0' or die "Cannot start candump: $!\n";

# Notify systemd of successful startup
systemd_notify("READY=1");

while (my $line = <$file>) {
    chomp $line;
    my @parts = split ' ', $line;
    process_packet(@parts);
}
close $file;

sub process_packet {
    my @parts = @_;
    return unless @parts >= 5;  # Ensure there are enough parts to process

    my $can_id_hex = $parts[2];
    my $binCanId = sprintf("%029b", hex($can_id_hex));  # Ensure leading zeros
    my $dgn_bin = substr($binCanId, 4, 17);  # Extract bits 4 to 20
    my $dgn = sprintf("%05X", oct("0b$dgn_bin"));  # DGN extraction

    my $data_bytes = join '', @parts[4..$#parts];
    my $result = decode($dgn, $data_bytes);

    if ($result) {
        my $instance = $result->{'instance'} // 'default';  # Use 'default' if instance is not found

        if (exists $lookup->{$dgn} && exists $lookup->{$dgn}->{$instance}) {
            my $configs = $lookup->{$dgn}->{$instance};
            foreach my $config (@$configs) {
                if ($config->{device_type} eq 'light') {
                    handle_dimmable_light($config, $result);
                } else {
                    publish_mqtt($config, $result);
                }
            }
        } elsif (exists $lookup->{$dgn} && exists $lookup->{$dgn}->{default}) {
            # Use 'default' if no specific instance is found
            my $configs = $lookup->{$dgn}->{default};
            foreach my $config (@$configs) {
                publish_mqtt($config, $result);
            }
        } else {
            log_debug("No matching config found for DGN $dgn and instance $instance");
            log_to_temp_file($dgn);
        }
    } else {
        log_debug("No data to publish for DGN $dgn");
    }
}

sub handle_dimmable_light {
    my ($config, $result) = @_;

    # Extract and calculate brightness and command state
    my $brightness = $result->{'operating status (brightness)'};
    my $command = ($brightness == 100) ? 'on' : ($brightness > 0) ? 'dim' : 'off';

    # Add these calculated values to the result hash to be passed to publish_mqtt
    $result->{'calculated_brightness'} = $brightness;
    $result->{'calculated_command'} = $command;

    # Call the publish_mqtt function with the updated result
    publish_mqtt($config, $result);
}

sub publish_mqtt {
    my ($config, $result) = @_;

    my $ha_name = $config->{ha_name};
    my $friendly_name = $config->{friendly_name};
    my $state_topic = $config->{state_topic};
    my $command_topic = $config->{command_topic};  # If command_topic is defined

    # Prepare the MQTT configuration message
    my %config_message = (
        name => $friendly_name,
        state_topic => $state_topic,
        command_topic => $command_topic,
        value_template => $config->{value_template},
        device_class => $config->{device_class},  # Include device_class if applicable
        unique_id => $ha_name,  # Ensure unique ID for the device
        json_attributes_topic => $state_topic,
    );

    # If the device is a light, include brightness settings
    if ($config->{device_type} eq 'light') {
        $config_message{brightness} = JSON::true;
        $config_message{brightness_scale} = 100;
        $config_message{payload_on} = "ON";
        $config_message{payload_off} = "OFF";
        $config_message{brightness_state_topic} = $state_topic;
        $config_message{brightness_command_topic} = $command_topic;
    }

    my $config_json = encode_json(\%config_message);
    $mqtt->retain("homeassistant/$config->{device_type}/$ha_name/config", $config_json);

    # Prepare the state message
    my %state_message = ();
    if ($config->{device_type} eq 'light') {
        $state_message{brightness} = $result->{'calculated_brightness'} if exists $result->{'calculated_brightness'};
    }
    $state_message{state} = $result->{'calculated_command'} if exists $result->{'calculated_command'};

    # Merge with existing result data
    my $state_json = encode_json({ %$result, %state_message });
    $mqtt->retain($state_topic, $state_json);
}

sub decode {
    my ($dgn, $data) = @_;
    my %result;

    my $decoder = $decoders->{$dgn};
    unless ($decoder) {
        log_debug("No decoder found for DGN $dgn");
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

    return \%result;
}

sub get_bytes {
    my ($data, $byterange) = @_;

    my ($start_byte, $end_byte) = split(/-/, $byterange);
    $end_byte = $start_byte if !defined $end_byte;
    my $length = ($end_byte - $start_byte + 1) * 2;
    
    return '' if $start_byte * 2 >= length($data);
    
    my $sub_bytes = substr($data, $start_byte * 2, $length);
    my @byte_pairs = $sub_bytes =~ /(..)/g;
    my $bytes = join '', reverse @byte_pairs;

    return $bytes;
}

sub get_bits {
    my ($bytes, $bitrange) = @_;
    return unless length($bytes);

    my $bits = hex2bin($bytes);
    return unless defined $bits && length($bits);

    my ($start_bit, $end_bit) = split(/-/, $bitrange);
    $end_bit = $start_bit if not defined $end_bit;

    return substr($bits, 7 - $end_bit, $end_bit - $start_bit + 1);
}

sub hex2bin {
    my $hex = shift;
    return unpack("B8", pack("C", hex $hex)) if length($hex) == 2;
    return '';
}

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

sub round {
    my ($value, $precision) = @_;
    return int($value / $precision + 0.5) * $precision;
}

sub tempC2F {
    my ($tempC) = @_;
    return int((($tempC * 9 / 5) + 32) * 10) / 10;
}

sub log_to_temp_file {
    my ($dgn) = @_;

    if (-e $undefined_dgns_file) {
        open my $fh, '<', $undefined_dgns_file or do {
            log_to_journald("Failed to open log file for reading undefined DGN $dgn: $!");
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
        log_to_journald("Failed to open log file for appending undefined DGN $dgn: $!");
        return;
    };
    print $fh "$dgn\n";
    close $fh;

    log_to_journald("Logged undefined DGN $dgn to temporary file: $undefined_dgns_file");
}

sub log_to_journald {
    my ($message) = @_;

    openlog('rvc2hass', 'cons,pid', LOG_USER);
    syslog(LOG_INFO, $message);
    closelog();
}

sub systemd_notify {
    my ($state) = @_;
    my $socket_path = $ENV{NOTIFY_SOCKET} // return;

    socket(my $socket, PF_UNIX, SOCK_DGRAM, 0) or do {
        log_to_journald("Failed to create UNIX socket: $!");
        return;
    };
    my $dest = sockaddr_un($socket_path);
    send($socket, $state, 0, $dest) or do {
        log_to_journald("Failed to send systemd notification: $!");
    };
    close($socket);
}

sub log_debug {
    my ($message) = @_;
    print "DEBUG: $message\n" if $debug;
}
