###############################################################################
# 
# Developed with Kate
#
#  (c) 2017 Copyright: Marko Oldenburg (leongaultier at gmail dot com)
#  All rights reserved
#
#  This script is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#
# $Id$
#
###############################################################################
##
##
## Das JSON Modul immer in einem eval aufrufen
# $data = eval{decode_json($data)};
#
# if($@){
#   Log3($SELF, 2, "$TYPE ($SELF) - error while request: $@");
#  
#   readingsSingleUpdate($hash, "state", "error", 1);
#
#   return;
# }
#
#######
#######
#  URLs zum Abrufen diverser Daten
# http://<ip-Powerwall>/api/system_status/soe 
# http://<ip-Powerwall>/api/meters/aggregates
# http://<ip-Powerwall>/api/site_info
# http://<ip-Powerwall>/api/sitemaster
# http://<ip-Powerwall>/api/powerwalls
# http://<ip-Powerwall>/api/networks
# http://<ip-Powerwall>/api/system/networks
# http://<ip-Powerwall>/api/operation
#
##
##



package main;


my $missingModul = "";

use strict;
use warnings;

use HttpUtils;
eval "use JSON;1" or $missingModul .= "JSON ";


my $version = "0.0.8";




# Declare functions
sub TeslaPowerwall2AC_Attr(@);
sub TeslaPowerwall2AC_Define($$);
sub TeslaPowerwall2AC_Initialize($);
sub TeslaPowerwall2AC_Get($@);
sub TeslaPowerwall2AC_GetData($@);
sub TeslaPowerwall2AC_Undef($$);
sub TeslaPowerwall2AC_ResponseProcessing($$$);
sub TeslaPowerwall2AC_ReadingsProcessing_Aggregates($$);
sub TeslaPowerwall2AC_ReadingsProcessing_Powerwalls($$);
sub TeslaPowerwall2AC_ErrorHandling($$$);
sub TeslaPowerwall2AC_WriteReadings($$$);
sub TeslaPowerwall2AC_Timer_GetData($);




my %paths = (   'statussoe'         => 'system_status/soe',
                'aggregates'        => 'meters/aggregates',
                'siteinfo'          => 'site_info',
                'sitemaster'        => 'sitemaster',
                'powerwalls'        => 'powerwalls'
);
my %readings = ();


sub TeslaPowerwall2AC_Initialize($) {

    my ($hash) = @_;
    
    # Consumer
    $hash->{GetFn}      = "TeslaPowerwall2AC_Get";
    $hash->{DefFn}      = "TeslaPowerwall2AC_Define";
    $hash->{UndefFn}    = "TeslaPowerwall2AC_Undef";
    
    $hash->{AttrFn}     = "TeslaPowerwall2AC_Attr";
    $hash->{AttrList}   = "interval ".
                          "disable:1 ".
                          $readingFnAttributes;
    
    foreach my $d(sort keys %{$modules{TeslaPowerwall2AC}{defptr}}) {
    
        my $hash = $modules{TeslaPowerwall2AC}{defptr}{$d};
        $hash->{VERSION}      = $version;
    }
}

sub TeslaPowerwall2AC_Define($$) {

    my ( $hash, $def ) = @_;
    
    my @a = split( "[ \t][ \t]*", $def );

    
    return "too few parameters: define <name> SmartPi <HOST>" if( @a != 3);
    return "Cannot define a HEOS device. Perl modul $missingModul is missing." if ( $missingModul );
    
    my $name                = $a[0];
    
    my $host                = $a[2];
    $hash->{HOST}           = $host;
    $hash->{INTERVAL}       = 300;
    $hash->{PORT}           = 80;
    $hash->{VERSION}        = $version;


    $attr{$name}{room} = "Tesla" if( !defined( $attr{$name}{room} ) );
    
    Log3 $name, 3, "TeslaPowerwall2AC ($name) - defined SmartPi Device with Host $host, Port $hash->{PORT} and Interval $hash->{INTERVAL}";
    
    
    if( $init_done ) {
        
        #TeslaPowerwall2AC_Timer_GetData($hash);
            
    } else {
        
        #InternalTimer( gettimeofday()+15, "TeslaPowerwall2AC_Timer_GetData", $hash, 0 );
    }
    
    $modules{TeslaPowerwall2AC}{defptr}{HOST} = $hash;

    return undef;
}

sub TeslaPowerwall2AC_Undef($$) {

    my ( $hash, $arg )  = @_;
    
    my $name            = $hash->{NAME};


    Log3 $name, 3, "TeslaPowerwall2AC ($name) - Device $name deleted";
    delete $modules{TeslaPowerwall2AC}{defptr}{HOST} if( defined($modules{TeslaPowerwall2AC}{defptr}{HOST}) and $hash->{HOST} );

    return undef;
}

sub TeslaPowerwall2AC_Attr(@) {

    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash = $defs{$name};
    
    my $orig = $attrVal;

    if( $attrName eq "disable" ) {
        if( $cmd eq "set" ) {
            if( $attrVal eq "0" ) {
            
                readingsSingleUpdate ( $hash, "state", "enabled", 1 );
                Log3 $name, 3, "TeslaPowerwall2AC ($name) - enabled";
            } else {

                readingsSingleUpdate ( $hash, "state", "disabled", 1 );
                Log3 $name, 3, "TeslaPowerwall2AC ($name) - disabled";
            }
            
        } else {

            readingsSingleUpdate ( $hash, "state", "enabled", 1 );
            Log3 $name, 3, "TeslaPowerwall2AC ($name) - enabled";
        }
        
    } elsif( $attrName eq "interval" ) {
        if( $cmd eq "set" ) {
        
            $hash->{INTERVAL} = $attrVal;
            
        } else {

            $hash->{INTERVAL} = 300;
        }
    }
    
    return undef;
}

sub TeslaPowerwall2AC_Get($@) {
    
    my ($hash, $name, $cmd) = @_;
    my $arg;
    #my ($hash, $name, $cmd, @args)  = @_;
    #my ($arg, @params)              = @args;


    if( $cmd eq 'statusSOE' ) {

        $arg    = lc($cmd);
        
    } elsif( $cmd eq 'aggregates' ) {
    
        $arg    = lc($cmd);
    
    } elsif( $cmd eq 'siteinfo' ) {
    
        $arg    = lc($cmd);

    } elsif( $cmd eq 'powerwalls' ) {
    
        $arg    = lc($cmd);

    } else {
    
        my $list = 'statusSOE:noArg aggregates:noArg siteinfo:noArg sitemaster:noArg powerwalls:noArg';
        
        return "Unknown argument $cmd, choose one of $list";
    }

    #########
    # zum testen
        #my $json = '{"site":{"last_communication_time":"2017-10-04T21:40:58.189824673Z","instant_power":405.5284080505371,"instant_reactive_power":-489.71363067626953,"instant_apparent_power":635.8244488898933,"frequency":49.99971389770508,"energy_exported":86827,"energy_imported":74551,"instant_average_voltage":695.5163269042969,"instant_total_current":0,"i_a_current":0,"i_b_current":0,"i_c_current":0},"battery":{"last_communication_time":"2017-10-04T21:40:58.19075366Z","instant_power":-10,"instant_reactive_power":310,"instant_apparent_power":310.16124838541646,"frequency":50.011,"energy_exported":43300,"energy_imported":49580,"instant_average_voltage":229.60000000000002,"instant_total_current":-0.30000000000000004,"i_a_current":0,"i_b_current":0,"i_c_current":0},"load":{"last_communication_time":"2017-10-04T21:40:58.189824673Z","instant_power":410.06476697984374,"instant_reactive_power":95.1168869834601,"instant_apparent_power":420.95170187048524,"frequency":49.99971389770508,"energy_exported":0,"energy_imported":86641,"instant_average_voltage":695.5163269042969,"instant_total_current":0.58958323639219,"i_a_current":0,"i_b_current":0,"i_c_current":0},"solar":{"last_communication_time":"2017-10-04T21:40:58.190334999Z","instant_power":15.60922384262085,"instant_reactive_power":271.87248373031616,"instant_apparent_power":272.32020725363014,"frequency":50.049781799316406,"energy_exported":126771,"energy_imported":21574,"instant_average_voltage":695.6544494628906,"instant_total_current":0,"i_a_current":0,"i_b_current":0,"i_c_current":0},"busway":{"last_communication_time":"0001-01-01T00:00:00Z","instant_power":0,"instant_reactive_power":0,"instant_apparent_power":0,"frequency":0,"energy_exported":0,"energy_imported":0,"instant_average_voltage":0,"instant_total_current":0,"i_a_current":0,"i_b_current":0,"i_c_current":0},"frequency":{"last_communication_time":"0001-01-01T00:00:00Z","instant_power":0,"instant_reactive_power":0,"instant_apparent_power":0,"frequency":0,"energy_exported":0,"energy_imported":0,"instant_average_voltage":0,"instant_total_current":0,"i_a_current":0,"i_b_current":0,"i_c_current":0}}';
    
        #my $json = '{"powerwalls":[{"PackagePartNumber":"1234567-89-E","PackageSerialNumber":"A12B3456789"}]}';
        #TeslaPowerwall2AC_ResponseProcessing($hash,$arg,$json);
    
    
    TeslaPowerwall2AC_GetData($hash,$arg);

    return undef;
}

sub TeslaPowerwall2AC_Timer_GetData($) {

    my $hash    = shift;
    my $name    = $hash->{NAME};
    
    
    if( not IsDisabled($name) ) {
    
        TeslaPowerwall2AC_GetData($hash,'all','all');
        
    } else {
    
        readingsSingleUpdate($hash,'state','disabled',1);
    }
    
    InternalTimer( gettimeofday()+$hash->{INTERVAL}, 'TeslaPowerwall2AC_Timer_GetData', $hash );
    Log3 $name, 4, "TeslaPowerwall2AC ($name) - Call InternalTimer TeslaPowerwall2AC_Timer_GetData";
}

sub TeslaPowerwall2AC_GetData($@) {

    my ($hash,$path)    = @_;
    my $name            = $hash->{NAME};
    my $host            = $hash->{HOST};
    my $port            = $hash->{PORT};

    my $uri             = $host . ':' . $port . '/api/' . $paths{$path};
    
    
    
    
    
    
    # ensure actionQueue exists
    $hash->{actionQueue} = [] if ( ! defined( $hash->{actionQueue} ) );

    # Queue if not yet retried and currently waiting
    if( defined( $hash->{doStatus}) and $hash->{doStatus} =~ /^WAITING/ and $retryCount == 0 ) {
        # add to queue
        Log3 $name, 4, "LoeweTV_SendRequest $name: add action to queue - args: ".$actionString;
        # RequestAccess will always be added to the beginning of the queue
        if ( ( $action eq "RequestAccess" ) )  {
            unshift( @{ $hash->{actionQueue} }, \@args );
        } else {
            push( @{ $hash->{actionQueue} }, \@args );
        }
        
        return;
    }
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    readingsSingleUpdate($hash,'state','fetch data',1);

    HttpUtils_NonblockingGet(
        {
            url         => "http://" . $uri,
            timeout     => 5,
            method      => 'GET',
            hash        => $hash,
            path        => $path,
            doTrigger   => 1,
            callback    => \&TeslaPowerwall2AC_ErrorHandling,
        }
    );
    
    Log3 $name, 5, "TeslaPowerwall2AC ($name) - Send with URI: $uri";
}

sub TeslaPowerwall2AC_ErrorHandling($$$) {

    my ($param,$err,$data)  = @_;
    
    my $hash                = $param->{hash};
    my $name                = $hash->{NAME};



    
    ### Begin Error Handling
    
    if( defined( $err ) ) {
        if( $err ne "" ) {
        
            readingsBeginUpdate( $hash );
            readingsBulkUpdateIfChanged ( $hash, 'state', $err, 1);
            readingsBulkUpdateIfChanged( $hash, 'lastRequestError', $err, 1 );
            readingsEndUpdate( $hash, 1 );
            
            Log3 $name, 3, "TeslaPowerwall2AC ($name) - RequestERROR: $err";
            
            return;
        }
    }

    if( $data eq "" and exists( $param->{code} ) && $param->{code} ne 200 ) {
    
        readingsBeginUpdate( $hash );
        readingsBulkUpdateIfChanged ( $hash, 'state', $param->{code}, 1 );

        readingsBulkUpdateIfChanged( $hash, 'lastRequestError', $param->{code}, 1 );

        Log3 $name, 3, "TeslaPowerwall2AC ($name) - RequestERROR: ".$param->{code};

        readingsEndUpdate( $hash, 1 );
    
        Log3 $name, 5, "TeslaPowerwall2AC ($name) - RequestERROR: received http code ".$param->{code}." without any data after requesting";

        return;
    }

    if( ( $data =~ /Error/i ) and exists( $param->{code} ) ) { 
    
        readingsBeginUpdate( $hash );
        
        readingsBulkUpdateIfChanged( $hash, 'state', $param->{code}, 1 );
        readingsBulkUpdateIfChanged( $hash, "lastRequestError", $param->{code}, 1 );

        readingsEndUpdate( $hash, 1 );
    
        Log3 $name, 3, "TeslaPowerwall2AC ($name) - statusRequestERROR: http error ".$param->{code};

        return;

        ### End Error Handling
    }


    $hash->{doStatus} = "";

    #########################
    # start next command in queue if available
    if( defined( $hash->{actionQueue}) and scalar( @{ $hash->{actionQueue}}) ) {
        my $ref = shift @{ $hash->{actionQueue} };
        Log3 $name, 4, "LoeweTV_HU_Callback $name: handle queued cmd with :@$ref[0]: ";
        LoeweTV_SendRequest( $hash, @$ref[0], @$ref[1], @$ref[2] );
    }
    
    
    Log3 $name, 4, "TeslaPowerwall2AC ($name) - Recieve JSON data: $data";
    
    TeslaPowerwall2AC_ResponseProcessing($hash,$param->{path},$data);
}

sub TeslaPowerwall2AC_ResponseProcessing($$$) {

    my ($hash,$path,$json)        = @_;
    
    my $name                = $hash->{NAME};
    my $decode_json;
    my $readings;


    $decode_json    = eval{decode_json($json)};
    if($@){

        Log3 $name, 4, "TeslaPowerwall2AC ($name) - error while request: $@";
        readingsSingleUpdate($hash, "state", "json error", 1);
        $readings{$path.'LastJsonError'}  = $@;

        return TeslaPowerwall2AC_WriteReadings($hash,$path,$readings);;
    }
    
    #### Verarbeitung der Readings zum passenden Path
    
    if( $path eq 'aggregates') {
        $readings = TeslaPowerwall2AC_ReadingsProcessing_Aggregates($hash,$decode_json);
        
    } elsif( $path eq 'powerwalls') {
        $readings = TeslaPowerwall2AC_ReadingsProcessing_Powerwalls($hash,$decode_json);
        
    } else {
        $readings = $decode_json;
    }
    
    TeslaPowerwall2AC_WriteReadings($hash,$path,$readings);
}

sub TeslaPowerwall2AC_WriteReadings($$$) {

    my ($hash,$path,$readings)    = @_;
    
    my $name                = $hash->{NAME};
    
    
    Log3 $name, 4, "TeslaPowerwall2AC ($name) - Write Readings";
    
    
    readingsBeginUpdate($hash);
    while( my ($r,$v) = each %{$readings} ) {
        readingsBulkUpdateIfChanged($hash,$path.'-'.$r,$v);
    }

    readingsBulkUpdateIfChanged($hash,'state','ready');
    readingsEndUpdate($hash,1);
}

sub TeslaPowerwall2AC_ReadingsProcessing_Aggregates($$) {
    
    my ($hash,$decode_json)     = @_;
    
    my $name                    = $hash->{NAME};
    my %readings;
    
    
    while( my $obj = each %{$decode_json} ) {
        while( my ($r,$v) = each %{$decode_json->{$obj}} ) {
            $readings{$obj.'-'.$r}   = $v;
        }
    }
    
    return \%readings;
}

sub TeslaPowerwall2AC_ReadingsProcessing_Powerwalls($$) {
    
    my ($hash,$decode_json)     = @_;
    
    my $name                    = $hash->{NAME};
    my %readings;
    
    
    if( ref($decode_json->{powerwalls}) eq "ARRAY" and scalar(@{$decode_json->{powerwalls}}) > 0 ) {
    
        foreach my $powerwall (@{$decode_json->{powerwalls}}) {
            if( ref($powerwall) eq "HASH" ) {
            
                while( my ($r,$v) = each %{$powerwall} ) {
                    $readings{$r}   = $v;
                }
            }
        }
    }
    
    return \%readings;
}




1;


=pod

=item device
=item summary    
=item summary_DE 

=begin html

<a name="TeslaPowerwall2AC"></a>
<h3>Tesla Powerwall 2 AC</h3>
<ul>
    <a name="TeslaPowerwall2ACreadings"></a>
    <b>Readings</b>
    <ul>
        <li> </li>
    </ul>
    <a name="TeslaPowerwall2ACget"></a>
    <b>get</b>
    <ul>
        <li> </li>
    </ul>
</ul>

=end html
=begin html_DE

<a name="TeslaPowerwall2AC"></a>
<h3>Tesla Powerwall 2 AC</h3>

=end html_DE
=cut
