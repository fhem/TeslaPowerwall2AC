###############################################################################
#
# Developed with Kate
#
#  (c) 2017-2019 Copyright: Marko Oldenburg (leongaultier at gmail dot com)
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
# https://<ip-Powerwall>/api/system_status/soe
# https://<ip-Powerwall>/api/meters/aggregates
# https://<ip-Powerwall>/api/site_info
# https://<ip-Powerwall>/api/sitemaster
# https://<ip-Powerwall>/api/powerwalls
# https://<ip-Powerwall>/api/networks
# https://<ip-Powerwall>/api/system/networks
# https://<ip-Powerwall>/api/operation
#
##
##

package FHEM::TeslaPowerwall2AC;

use strict;
use warnings;
use FHEM::Meta;
use GPUtils qw(GP_Import GP_Export);
use HttpUtils;
use Data::Dumper;

# try to use JSON::MaybeXS wrapper
#   for chance of better performance + open code
eval {
    require JSON::MaybeXS;
    import JSON::MaybeXS qw( decode_json encode_json );
    1;
};

if ($@) {
    $@ = undef;

    # try to use JSON wrapper
    #   for chance of better performance
    eval {

        # JSON preference order
        local $ENV{PERL_JSON_BACKEND} =
          'Cpanel::JSON::XS,JSON::XS,JSON::PP,JSON::backportPP'
          unless ( defined( $ENV{PERL_JSON_BACKEND} ) );

        require JSON;
        import JSON qw( decode_json encode_json );
        1;
    };

    if ($@) {
        $@ = undef;

        # In rare cases, Cpanel::JSON::XS may
        #   be installed but JSON|JSON::MaybeXS not ...
        eval {
            require Cpanel::JSON::XS;
            import Cpanel::JSON::XS qw(decode_json encode_json);
            1;
        };

        if ($@) {
            $@ = undef;

            # In rare cases, JSON::XS may
            #   be installed but JSON not ...
            eval {
                require JSON::XS;
                import JSON::XS qw(decode_json encode_json);
                1;
            };

            if ($@) {
                $@ = undef;

                # Fallback to built-in JSON which SHOULD
                #   be available since 5.014 ...
                eval {
                    require JSON::PP;
                    import JSON::PP qw(decode_json encode_json);
                    1;
                };

                if ($@) {
                    $@ = undef;

                    # Fallback to JSON::backportPP in really rare cases
                    require JSON::backportPP;
                    import JSON::backportPP qw(decode_json encode_json);
                    1;
                }
            }
        }
    }
}

## Import der FHEM Funktionen
#-- Run before package compilation
BEGIN {

    # Import from main context
    GP_Import(
        qw(
          readingsSingleUpdate
          readingsBulkUpdate
          readingsBulkUpdateIfChanged
          readingsBeginUpdate
          readingsEndUpdate
          CommandAttr
          defs
          Log3
          readingFnAttributes
          HttpUtils_NonblockingGet
          AttrVal
          ReadingsVal
          IsDisabled
          deviceEvents
          init_done
          gettimeofday
          InternalTimer
          RemoveInternalTimer)
    );
}

#-- Export to main context with different name
GP_Export(
    qw(
      Initialize
      Timer_GetData
      )
);

my %paths = (
    'statussoe'      => 'system_status/soe',
    'aggregates'     => 'meters/aggregates',
    'meterssite'     => 'meters/site',
    'meterssolar'    => 'meters/solar',
    'siteinfo'       => 'site_info',
    'sitename'       => 'site_info/site_name',
    'sitemaster'     => 'sitemaster',
    'powerwallsstop' => 'sitemaster/stop',
    'powerwallsrun'  => 'sitemaster/run',
    'powerwalls'     => 'powerwalls',
    'registration'   => 'customer/registration',
    'status'         => 'status',
    'login'          => 'login/Basic',
    'gridstatus'     => 'system_status/grid_status',
);

sub Initialize($) {

    my ($hash) = @_;

    # Consumer
    $hash->{GetFn}    = 'FHEM::TeslaPowerwall2AC::Get';
    $hash->{SetFn}    = 'FHEM::TeslaPowerwall2AC::Set';
    $hash->{DefFn}    = 'FHEM::TeslaPowerwall2AC::Define';
    $hash->{UndefFn}  = 'FHEM::TeslaPowerwall2AC::Undef';
    $hash->{NotifyFn} = 'FHEM::TeslaPowerwall2AC::Notify';

    $hash->{AttrFn} = 'FHEM::TeslaPowerwall2AC::Attr';
    $hash->{AttrList} =
      'interval ' . 'disable:1 ' . 'devel:1 ' . $readingFnAttributes;

    return FHEM::Meta::InitMod( __FILE__, $hash );
}

sub Define($$) {
    my ( $hash, $def ) = @_;
    my @a = split( '[ \t][ \t]*', $def );

    return $@ unless ( FHEM::Meta::SetInternals($hash) );
    use version 0.60; our $VERSION = FHEM::Meta::Get( $hash, 'version' );

    return 'too few parameters: define <name> TeslaPowerwall2AC <HOST>'
      if ( @a != 3 );

    my $name = $a[0];

    my $host = $a[2];
    $hash->{HOST}        = $host;
    $hash->{INTERVAL}    = 300;
    $hash->{VERSION}     = version->parse($VERSION)->normal;
    $hash->{NOTIFYDEV}   = "global,$name";
    $hash->{actionQueue} = [];

    CommandAttr( undef, $name . ' room Tesla' )
      if ( AttrVal( $name, 'room', 'none' ) eq 'none' );
    Log3 $name, 3,
"TeslaPowerwall2AC ($name) - defined TeslaPowerwall2AC Device with Host $host and Interval $hash->{INTERVAL}";

    return undef;
}

sub Undef($$) {
    my ( $hash, $arg ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 3, "TeslaPowerwall2AC ($name) - Device $name deleted";

    return undef;
}

sub Attr(@) {
    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash = $defs{$name};

    if ( $attrName eq 'disable' ) {
        if ( $cmd eq 'set' and $attrVal eq '1' ) {
            RemoveInternalTimer($hash);
            readingsSingleUpdate( $hash, 'state', 'disabled', 1 );
            Log3 $name, 3, "TeslaPowerwall2AC ($name) - disabled";

        }
        elsif ( $cmd eq 'del' ) {
            Log3 $name, 3, "TeslaPowerwall2AC ($name) - enabled";
        }
    }

    if ( $attrName eq 'disabledForIntervals' ) {
        if ( $cmd eq 'set' ) {
            return
'check disabledForIntervals Syntax HH:MM-HH:MM or \'HH:MM-HH:MM HH:MM-HH:MM ...\''
              unless ( $attrVal =~ /^((\d{2}:\d{2})-(\d{2}:\d{2})\s?)+$/ );
            Log3 $name, 3, "TeslaPowerwall2AC ($name) - disabledForIntervals";
            readingsSingleUpdate( $hash, 'state', 'disabled', 1 );

        }
        elsif ( $cmd eq 'del' ) {
            Log3 $name, 3, "TeslaPowerwall2AC ($name) - enabled";
            readingsSingleUpdate( $hash, 'state', 'active', 1 );
        }
    }

    if ( $attrName eq 'interval' ) {
        if ( $cmd eq 'set' ) {
            if ( $attrVal < 30 ) {
                Log3 $name, 3,
"TeslaPowerwall2AC ($name) - interval too small, please use something >= 30 (sec), default is 300 (sec)";
                return
'interval too small, please use something >= 30 (sec), default is 300 (sec)';

            }
            else {
                RemoveInternalTimer($hash);
                $hash->{INTERVAL} = $attrVal;
                Log3 $name, 3,
                  "TeslaPowerwall2AC ($name) - set interval to $attrVal";
                Timer_GetData($hash);
            }
        }
        elsif ( $cmd eq 'del' ) {
            RemoveInternalTimer($hash);
            $hash->{INTERVAL} = 300;
            Log3 $name, 3,
              "TeslaPowerwall2AC ($name) - set interval to default";
            Timer_GetData($hash);
        }
    }

    return undef;
}

sub Notify($$) {
    my ( $hash, $dev ) = @_;
    my $name = $hash->{NAME};
    return if ( IsDisabled($name) );

    my $devname = $dev->{NAME};
    my $devtype = $dev->{TYPE};
    my $events  = deviceEvents( $dev, 1 );
    return if ( !$events );

    Timer_GetData($hash)
      if (
        grep /^INITIALIZED$/,
        @{$events} or grep /^DELETEATTR.$name.disable$/,
        @{$events} or grep /^DELETEATTR.$name.interval$/,
        @{$events} or ( grep /^DEFINED.$name$/, @{$events} and $init_done )
      );
    return;
}

sub Get($@) {
    my ( $hash, $name, $cmd ) = @_;
    my $arg;

    if ( $cmd eq 'statusSOE' ) {

        $arg = lc($cmd);

    }
    elsif ( $cmd eq 'aggregates' ) {

        $arg = lc($cmd);

    }
    elsif ( $cmd eq 'siteinfo' ) {

        $arg = lc($cmd);

    }
    elsif ( $cmd eq 'powerwalls' ) {

        $arg = lc($cmd);

    }
    elsif ( $cmd eq 'sitemaster' ) {

        $arg = lc($cmd);

    }
    elsif ( $cmd eq 'registration' ) {

        $arg = lc($cmd);

    }
    elsif ( $cmd eq 'status' ) {

        $arg = lc($cmd);

    }
    else {

        my $list =
'statusSOE:noArg aggregates:noArg siteinfo:noArg sitemaster:noArg powerwalls:noArg registration:noArg status:noArg';

        return 'Unknown argument ' . $cmd . ', choose one of ' . $list;
    }

    return 'There are still path commands in the action queue'
      if ( defined( $hash->{actionQueue} )
        and scalar( @{ $hash->{actionQueue} } ) > 0 );

    unshift( @{ $hash->{actionQueue} }, $arg );
    Write($hash);

    return undef;
}

sub Set($@) {
    my ( $hash, $name, $cmd, @args ) = @_;
    my $arg;

    if ( $cmd eq 'powerwalls' ) {

        $arg = lc( $cmd . $args[0] );

    }
    else {

        my $list = '';
        $list .= 'powerwalls:run,stop'
          if ( AttrVal( $name, 'devel', 0 ) == 1 );

        return 'Unknown argument ' . $cmd . ', choose one of ' . $list;
    }

    unshift( @{ $hash->{actionQueue} }, $arg );
    Write($hash);

    return undef;
}

sub Timer_GetData($) {
    my $hash = shift;
    my $name = $hash->{NAME};

    if ( defined( $hash->{actionQueue} )
        and scalar( @{ $hash->{actionQueue} } ) == 0 )
    {
        if ( not IsDisabled($name) ) {
            while ( my $obj = each %paths ) {
                unshift( @{ $hash->{actionQueue} }, $obj );
            }

            Write($hash);

        }
        else {
            readingsSingleUpdate( $hash, 'state', 'disabled', 1 );
        }
    }

    InternalTimer( gettimeofday() + $hash->{INTERVAL},
        'TeslaPowerwall2AC_Timer_GetData', $hash );
    Log3 $name, 4,
      "TeslaPowerwall2AC ($name) - Call InternalTimer Timer_GetData";
}

sub Write($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my ( $uri, $method, $header, $data, $path ) =
      CreateUri( $hash, pop( @{ $hash->{actionQueue} } ) );

    readingsSingleUpdate(
        $hash,
        'state',
        'fetch data - '
          . scalar( @{ $hash->{actionQueue} } )
          . ' entries in the Queue',
        1
    );

    HttpUtils_NonblockingGet(
        {
            url       => 'https://' . $uri,
            timeout   => 5,
            method    => $method,
            data      => $data,
            header    => $header,
            hash      => $hash,
            setCmd    => $path,
            doTrigger => 1,
            callback  => \&ErrorHandling,
        }
    );

#     #### temporär
#     ErrorHandling(
#         {
#             url       => 'http://' . $uri,
#             timeout   => 5,
#             method    => $method,
#             data      => $data,
#             header    => $header,
#             hash      => $hash,
#             setCmd    => $path,
#             doTrigger => 1,
#             callback  => \&ErrorHandling,
#         },
#         undef,
#         '{"none": "none"}'
#     );

    Log3 $name, 4, "TeslaPowerwall2AC ($name) - Send with URI: http://$uri";
}

sub ErrorHandling($$$) {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
#     my $path = $param->{setCmd};   # temporär
    
    print('TESLA DEBUG - ResponseString: ' . Dumper $data);
    print('TESLA DEBUG - Error: ' . $err . "\n")
      unless ($err);
    
    
    
    
    
#     #### temporär
#     if ( $path eq 'statussoe' ) {
#         $data = '{"percentage":69.1675560298826}';
#     }
#     elsif ( $path eq 'aggregates' ) {
#         $data = '{
#             "site":{
#                 "last_communication_time":"2018-04-02T16:11:41.885377469-07:00",
#                 "instant_power":-21.449996948242188,
#                 "instant_reactive_power":-138.8300018310547,
#                 "instant_apparent_power":140.47729986545957,
#                 "frequency":60.060001373291016,
#                 "energy_exported":1136916.6875890202,
#                 "energy_imported":3276432.6625890196,
#                 "instant_average_voltage":239.81999969482422,
#                 "instant_total_current":0,
#                 "i_a_current":0,
#                 "i_b_current":0,
#                 "i_c_current":0
#             },
#             "battery":{
#                 "last_communication_time":"2018-04-02T16:11:41.89022247-07:00",
#                 "instant_power":-2350,
#                 "instant_reactive_power":0,
#                 "instant_apparent_power":2350,
#                 "frequency":60.033,
#                 "energy_exported":1169030,
#                 "energy_imported":1638140,
#                 "instant_average_voltage":239.10000000000002,
#                 "instant_total_current":45.8,
#                 "i_a_current":0,
#                 "i_b_current":0,
#                 "i_c_current":0
#             },
#             "load":{
#                 "last_communication_time":"2018-04-02T16:11:41.885377469-07:00",
#                 "instant_power":1546.2712597712405,
#                 "instant_reactive_power":-71.43153973801415,
#                 "instant_apparent_power":1547.920305979569,
#                 "frequency":60.060001373291016,
#                 "energy_exported":0,
#                 "energy_imported":7191016.994444443,
#                 "instant_average_voltage":239.81999969482422,
#                 "instant_total_current":6.44763264839839,
#                 "i_a_current":0,
#                 "i_b_current":0,
#                 "i_c_current":0
#             },
#             "solar":{
#                 "last_communication_time":"2018-04-02T16:11:41.885541803-07:00",
#                 "instant_power":3906.1700439453125,
#                 "instant_reactive_power":53.26999855041504,
#                 "instant_apparent_power":3906.533259164868,
#                 "frequency":60.060001373291016,
#                 "energy_exported":5534272.949724403,
#                 "energy_imported":13661.930279959455,
#                 "instant_average_voltage":239.8699951171875,
#                 "instant_total_current":0,
#                 "i_a_current":0,
#                 "i_b_current":0,
#                 "i_c_current":0
#             },
#             "busway":{
#                 "last_communication_time":"0001-01-01T00:00:00Z",
#                 "instant_power":0,
#                 "instant_reactive_power":0,
#                 "instant_apparent_power":0,
#                 "frequency":0,
#                 "energy_exported":0,
#                 "energy_imported":0,
#                 "instant_average_voltage":0,
#                 "instant_total_current":0,
#                 "i_a_current":0,
#                 "i_b_current":0,
#                 "i_c_current":0
#             },
#             "frequency":{
#                 "last_communication_time":"0001-01-01T00:00:00Z",
#                 "instant_power":0,
#                 "instant_reactive_power":0,
#                 "instant_apparent_power":0,
#                 "frequency":0,
#                 "energy_exported":0,
#                 "energy_imported":0,
#                 "instant_average_voltage":0,
#                 "instant_total_current":0,
#                 "i_a_current":0,
#                 "i_b_current":0,
#                 "i_c_current":0
#             },
#             "generator":{
#                 "last_communication_time":"0001-01-01T00:00:00Z",
#                 "instant_power":0,
#                 "instant_reactive_power":0,
#                 "instant_apparent_power":0,
#                 "frequency":0,
#                 "energy_exported":0,
#                 "energy_imported":0,
#                 "instant_average_voltage":0,
#                 "instant_total_current":0,
#                 "i_a_current":0,
#                 "i_b_current":0,
#                 "i_c_current":0
#             }
#         }';
#     }
#     elsif ( $path eq 'siteinfo' ) {
#         $data = '{"site":{"last_communication_time":"2019-09-22T00:21:15.389963162-07:00","instant_power":24.451171875,"instant_reactive_power":53.17060422897339,"instant_apparent_power":58.52326853598416,"frequency":49.99971389770508,"energy_exported":8317850.641600119,"energy_imported":3906677.3213223405,"instant_average_voltage":228.2313995361328,"instant_total_current":0,"i_a_current":0,"i_b_current":0,"i_c_current":0,"timeout":1500000000},"battery":{"last_communication_time":"2019-09-22T00:21:15.501660598-07:00","instant_power":1350,"instant_reactive_power":-30,"instant_apparent_power":1350.3332921912279,"frequency":49.994,"energy_exported":3816030,"energy_imported":4422670,"instant_average_voltage":235,"instant_total_current":-31.8,"i_a_current":0,"i_b_current":0,"i_c_current":0,"timeout":1500000000},"load":{"last_communication_time":"2019-09-22T00:21:15.389963162-07:00","instant_power":5728.583274805815,"instant_reactive_power":-175.17854151916174,"instant_apparent_power":5731.261105358374,"frequency":49.99971389770508,"energy_exported":0,"energy_imported":13885698.406388888,"instant_average_voltage":228.2313995361328,"instant_total_current":25.0998911037168,"i_a_current":0,"i_b_current":0,"i_c_current":0,"timeout":1500000000},"solar":{"last_communication_time":"2019-09-22T00:21:15.506420255-07:00","instant_power":4363.2269287109375,"instant_reactive_power":-196.4273910522461,"instant_apparent_power":4367.646156842822,"frequency":49.99971389770508,"energy_exported":18947820.8881397,"energy_imported":44309.16147303224,"instant_average_voltage":227.83099365234375,"instant_total_current":0,"i_a_current":0,"i_b_current":0,"i_c_current":0,"timeout":1500000000}}';
#     }
#     elsif ( $path eq 'sitemaster' ) {
#         $data = '{"running":true,"uptime":"166594s,","connected_to_tesla":true}';
#     }
#     elsif ( $path eq 'powerwalls' ) {
#         $data = '{"powerwalls":[{"PackagePartNumber":"1092170-03-E","PackageSerialNumber":"T1234567890"},{"PackagePartNumber":"1092170-03-E","PackageSerialNumber":"T1234567891"}],"has_sync":true}';
#     }
#     elsif ( $path eq 'status' ) {
#         $data = '{"start_time":"2018-03-16 19:08:46 +0800","up_time_seconds":"402h8m19.937911668s","is_new":false,"version":"1.15.0\n","git_hash":"dc337851c6cad15a7e9c7223d60fff719eb8da4d\n"}';
#     }
#     elsif ( $path eq 'meterssite' ) {
#         $data = '[
#             {
#                 "id":0,
#                 "location":"site",
#                 "type":"neurio_tcp",
#                 "cts":[
#                     true,
#                     true,
#                     false,
#                     false
#                 ],
#                 "inverted":[
#                     false,
#                     false,
#                     false,
#                     false
#                 ],
#                 "connection":{
#                     "ip_address":"Neurio-39546",
#                     "port":443,
#                     "short_id":"39546",
#                     "device_serial":"OBB3364102752",
#                     "neurio_connected":true,
#                     "https_conf":{
#                         "client_cert":"/etc/site/certs/neurio/neurio.crt",
#                         "client_key":"/etc/site/certs/neurio/neurio.key",
#                         "server_ca_cert":"/etc/site/certs/neurio/neurio-ca-chain.cert.pem",
#                         "max_idle_conns_per_host":1
#                     }
#                 },
#                 "Cached_readings":{
#                     "last_communication_time":"2018-06-10T16:51:46.187715089+01:00",
#                     "instant_power":13.94000026769936,
#                     "instant_reactive_power":14.070000305771828,
#                     "instant_apparent_power":19.80627466405224,
#                     "frequency":49.95000076293945,
#                     "energy_exported":3724.253888912031,
#                     "energy_imported":26003.843888912033,
#                     "instant_average_voltage":247.52999755740166,
#                     "instant_total_current":0,
#                     "i_a_current":0,
#                     "i_b_current":0,
#                     "i_c_current":0,
#                     "v_l1n":247.3300018310547,
#                     "v_l2n":0.2199999988079071,
#                     "serial_number":"0x000004714B008720",
#                     "version":"Tesla-0.0.7"
#                 }
#             }
#         ]';
#     }
#     elsif ( $path eq 'meterssolar' ) {
#         $data = '[
#             {
#                 "id":0,
#                 "location":"solar",
#                 "type":"neurio_tcp",
#                 "cts":[
#                     false,
#                     false,
#                     false,
#                     true
#                 ],
#                 "inverted":[
#                     false,
#                     false,
#                     false,
#                     false
#                 ],
#                 "connection":{
#                     "ip_address":"Neurio-39546",
#                     "port":443,
#                     "short_id":"39546",
#                     "device_serial":"OBB3364102752",
#                     "neurio_connected":true,
#                     "https_conf":{
#                         "client_cert":"/etc/site/certs/neurio/neurio.crt",
#                         "client_key":"/etc/site/certs/neurio/neurio.key",
#                         "server_ca_cert":"/etc/site/certs/neurio/neurio-ca-chain.cert.pem",
#                         "max_idle_conns_per_host":1
#                     }
#                 },
#                 "Cached_readings":{
#                     "last_communication_time":"2018-06-10T16:52:57.788560639+01:00",
#                     "instant_power":318.8599853515625,
#                     "instant_reactive_power":129.94000244140625,
#                     "instant_apparent_power":344.3197561756678,
#                     "frequency":49.95000076293945,
#                     "energy_exported":3.8174999999938235,
#                     "energy_imported":125317.00444444444,
#                     "instant_average_voltage":246.82000732421875,
#                     "instant_total_current":0,
#                     "i_a_current":0,
#                     "i_b_current":0,
#                     "i_c_current":0,
#                     "v_l1n":246.8800048828125,
#                     "serial_number":"0x000004714B008720",
#                     "version":"Tesla-0.0.7"
#                 }
#             }
#         ]';
#     }
#     
#     elsif ( $path eq 'gridstatus' ) {
#         $data = '{"grid_status":"SystemGridConnected"}';
#     }
#     elsif ( $path eq 'sitename' ) {
#         $data = '{"site_name":"Home Energy Gateway","timezone":"America/Los_Angeles"}';
#     }
    
    


    ### Begin Error Handling

    if ( defined($err) ) {
        if ( $err ne '' ) {

            readingsBeginUpdate($hash);
            readingsBulkUpdate( $hash, 'state',            $err, 1 );
            readingsBulkUpdate( $hash, 'lastRequestError', $err, 1 );
            readingsEndUpdate( $hash, 1 );

            Log3 $name, 3, "TeslaPowerwall2AC ($name) - RequestERROR: $err";

            $hash->{actionQueue} = [];
#             return;
        }
    }

    if ( $data eq '' and exists( $param->{code} ) && $param->{code} ne 200 ) {

        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, 'state', $param->{code}, 1 );

        readingsBulkUpdate( $hash, 'lastRequestError', $param->{code}, 1 );

        Log3 $name, 3,
          "TeslaPowerwall2AC ($name) - RequestERROR: " . $param->{code};

        readingsEndUpdate( $hash, 1 );

        Log3 $name, 5,
            "TeslaPowerwall2AC ($name) - RequestERROR: received http code "
          . $param->{code}
          . " without any data after requesting";

        $hash->{actionQueue} = [];
#         return;
    }

    if ( ( $data =~ /Error/i ) and exists( $param->{code} ) ) {

        readingsBeginUpdate($hash);

        readingsBulkUpdate( $hash, 'state',            $param->{code}, 1 );
        readingsBulkUpdate( $hash, 'lastRequestError', $param->{code}, 1 );

        readingsEndUpdate( $hash, 1 );

        Log3 $name, 3,
          "TeslaPowerwall2AC ($name) - statusRequestERROR: http error "
          . $param->{code};

        $hash->{actionQueue} = [];
#         return;
        ### End Error Handling
    }

    Write($hash)
      if ( defined( $hash->{actionQueue} )
        and scalar( @{ $hash->{actionQueue} } ) > 0 );

    Log3 $name, 4, "TeslaPowerwall2AC ($name) - Recieve JSON data: $data";

#     ResponseProcessing( $hash, $param->{setCmd}, $data );
}

sub ResponseProcessing($$$) {
    my ( $hash, $path, $json ) = @_;
    my $name = $hash->{NAME};
    my $decode_json;
    my $readings;

    $decode_json = eval { decode_json($json) };
    if ($@) {
        Log3 $name, 4, "TeslaPowerwall2AC ($name) - error while request: $@";
        readingsBeginUpdate($hash);
        readingsBulkUpdate( $hash, 'JSON Error', $@ );
        readingsBulkUpdate( $hash, 'state',      'JSON error' );
        readingsEndUpdate( $hash, 1 );
        return;
    }

    #### Verarbeitung der Readings zum passenden Path

    if ( $path eq 'aggregates' ) {
        $readings = ReadingsProcessing_Aggregates( $hash, $decode_json );
    }
    elsif ( $path eq 'powerwalls' ) {
        $readings = ReadingsProcessing_Powerwalls( $hash, $decode_json );
    }
    elsif ( $path eq 'siteinfo' ) {
        $readings = ReadingsProcessing_Site_Info( $hash, $decode_json );
    }
    elsif ( $path eq 'login' ) {
        return $hash->{TOKEN} = $decode_json->{token};
    }
    elsif ( $path eq 'meterssite' ) {
        $readings = ReadingsProcessing_Meters_Site( $hash, $decode_json );
    }
    elsif ( $path eq 'meterssolar' ) {
        $readings = ReadingsProcessing_Meters_Solar( $hash, $decode_json );
    }
    else {
        $readings = $decode_json;
    }

    WriteReadings( $hash, $path, $readings );
}

sub WriteReadings($$$) {
    my ( $hash, $path, $readings ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 4, "TeslaPowerwall2AC ($name) - Write Readings";

    readingsBeginUpdate($hash);
    while ( my ( $r, $v ) = each %{$readings} ) {
        readingsBulkUpdate( $hash, $path . '-' . $r, $v );
    }

    readingsBulkUpdate( $hash, 'batteryLevel',
        sprintf( "%.1f", $readings->{percentage} ) )
      if ( defined( $readings->{percentage} ) );
    readingsBulkUpdate(
        $hash,
        'batteryPower',
        sprintf(
            "%.1f",
            (
                ReadingsVal( $name, 'siteinfo-nominal_system_energy_kWh', 0 ) /
                  100
            ) * ReadingsVal( $name, 'statussoe-percentage', 0 )
        )
    );
    readingsBulkUpdateIfChanged( $hash, 'actionQueue',
        scalar( @{ $hash->{actionQueue} } ) . ' entries in the Queue' );
    readingsBulkUpdateIfChanged(
        $hash, 'state',
        (
            defined( $hash->{actionQueue} )
              and scalar( @{ $hash->{actionQueue} } ) == 0
            ? 'ready'
            : 'fetch data - '
              . scalar( @{ $hash->{actionQueue} } )
              . ' paths in actionQueue'
        )
    );
    readingsEndUpdate( $hash, 1 );
}

sub ReadingsProcessing_Aggregates($$) {
    my ( $hash, $decode_json ) = @_;
    my $name = $hash->{NAME};
    my %readings;

    if ( ref($decode_json) eq 'HASH' ) {
        while ( my $obj = each %{$decode_json} ) {
            while ( my ( $r, $v ) = each %{ $decode_json->{$obj} } ) {
                $readings{ $obj . '-' . $r } = $v;
            }
        }
    }
    else {
        $readings{'error'} = 'aggregates response is not a Hash';
    }

    return \%readings;
}

sub ReadingsProcessing_Powerwalls($$) {
    my ( $hash, $decode_json ) = @_;
    my $name = $hash->{NAME};
    my %readings;

    if ( ref( $decode_json->{powerwalls} ) eq 'ARRAY'
        and scalar( @{ $decode_json->{powerwalls} } ) > 0 )
    {
        my $i = 0;
        foreach my $powerwall ( @{ $decode_json->{powerwalls} } ) {
            if ( ref($powerwall) eq 'HASH' ) {

                while ( my ( $r, $v ) = each %{$powerwall} ) {
                    $readings{ 'wall_' . $i . '_' . $r } = $v;
                }

                $i++;
            }
        }

        $readings{'numberOfWalls'} = $i;
    }
    else {
        $readings{'error'} = 'aggregates response is not a Array';
    }

    return \%readings;
}

sub ReadingsProcessing_Site_Info($$) {
    my ( $hash, $decode_json ) = @_;
    my $name = $hash->{NAME};
    my %readings;

    if ( ref($decode_json) eq 'HASH' ) {
        while ( my $obj = each %{$decode_json} ) {
            while ( my ( $r, $v ) = each %{ $decode_json->{$obj} } ) {
                $readings{ $obj . '-' . $r } = $v;
            }
        }
    }
    else {
        $readings{'error'} = 'siteinfo response is not a Hash';
    }

    return \%readings;
}

sub ReadingsProcessing_Meters_Site($$) {
    my ( $hash, $decode_json ) = @_;
    my $name = $hash->{NAME};
    my %readings;

#     print('Ausgabe1: ' . Dumper $decode_json . "\n");
    
    if ( ref( $decode_json ) eq 'ARRAY'
        and scalar( @{ $decode_json } ) > 0 )
    {
        if ( ref($decode_json->[0]) eq 'HASH' ) {
            while ( my $obj = each %{$decode_json->[0]} ) {
#                 print('Ausgabe2: ' . Dumper $obj . "\n");
                if ( ref($decode_json->[0]->{$obj}) eq 'ARRAY'
                  or ref($decode_json->[0]->{$obj}) eq 'HASH' )
                {
                    if ( ref($decode_json->[0]->{$obj}) eq 'HASH' ) {
#                         print('Ausgabe3: ' . Dumper $obj . "\n");
                        while ( my ( $r, $v ) = each %{ $decode_json->[0]->{$obj} } ) {
                            if ( ref($v) ne 'HASH' ) {
#                                 print('Ausgabe4: ' . $obj . '-' . $r . ' = ' . $v . "\n");
                                $readings{ $obj . '-' . $r } = $v;
                            }
                            else {
#                                 print('Ausgabe5: ' . Dumper $decode_json->[0]->{$obj}->{$r} . "\n");
                                while ( my ( $r2, $v2 ) = each %{ $decode_json->[0]->{$obj}->{$r} } ) {
#                                     print('Ausgabe6: ' . $obj . '-' . $r2 . ' = ' . $v2 . "\n");
                                    $readings{ $obj . '-' . $r . '-' . $r2 } = $v2;
                                }
                            }
                        }
                    }
                    elsif ( ref($decode_json->[0]->{$obj}) eq 'ARRAY' ) {

                    }
                }
                else {
#                     print('Ausgabe7: ' . Dumper $decode_json->[0]->{$obj} . "\n");
                    $readings{ $obj } = $decode_json->[0]->{$obj};
                }
            }
        }
    }
    else {
#         print('Ausgabe8: ' . "\n");
        $readings{'error'} = 'metes site response is not a Array';
    }

    return \%readings;
}

sub ReadingsProcessing_Meters_Solar($$) {
    my ( $hash, $decode_json ) = @_;
    my $name = $hash->{NAME};
    my %readings;

    if ( ref( $decode_json ) eq 'ARRAY'
        and scalar( @{ $decode_json } ) > 0 )
    {
        if ( ref($decode_json->[0]) eq 'HASH' ) {
            while ( my $obj = each %{$decode_json->[0]} ) {
#                 print('Ausgabe2: ' . Dumper $obj . "\n");
                if ( ref($decode_json->[0]->{$obj}) eq 'ARRAY'
                  or ref($decode_json->[0]->{$obj}) eq 'HASH' )
                {
                    if ( ref($decode_json->[0]->{$obj}) eq 'HASH' ) {
#                         print('Ausgabe3: ' . Dumper $obj . "\n");
                        while ( my ( $r, $v ) = each %{ $decode_json->[0]->{$obj} } ) {
                            if ( ref($v) ne 'HASH' ) {
#                                 print('Ausgabe4: ' . $obj . '-' . $r . ' = ' . $v . "\n");
                                $readings{ $obj . '-' . $r } = $v;
                            }
                            else {
#                                 print('Ausgabe5: ' . Dumper $decode_json->[0]->{$obj}->{$r} . "\n");
                                while ( my ( $r2, $v2 ) = each %{ $decode_json->[0]->{$obj}->{$r} } ) {
#                                     print('Ausgabe6: ' . $obj . '-' . $r2 . ' = ' . $v2 . "\n");
                                    $readings{ $obj . '-' . $r . '-' . $r2 } = $v2;
                                }
                            }
                        }
                    }
                    elsif ( ref($decode_json->[0]->{$obj}) eq 'ARRAY' ) {

                    }
                }
                else {
#                     print('Ausgabe7: ' . Dumper $decode_json->[0]->{$obj} . "\n");
                    $readings{ $obj } = $decode_json->[0]->{$obj};
                }
            }
        }
    }
    else {
#         print('Ausgabe8: ' . "\n");
        $readings{'error'} = 'metes solar response is not a Array';
    }

    return \%readings;
}

sub CreateUri($$) {
    my ( $hash, $path ) = @_;
    my $host   = $hash->{HOST};
    my $method = 'GET';
    my $uri;
    my $header;
    my $data;

    $uri = $host . '/api/' . $paths{$path};

    if ( $path eq 'sitemasterrun' ) {
        $header = 'Authorization: Bearer' . $hash->{TOKEN};

    }
    elsif ( $path eq 'login' ) {
        $method = 'POST';
        $header = 'Content-Type: application/json';
        $data   = '{"username":"","password":"S'
          . ReadingsVal( $hash->{NAME},
            'powerwalls-wall_0_PackageSerialNumber', 0 )
          . '","force_sm_off":false}';
    }

    return ( $uri, $method, $header, $data, $path );
}

1;

=pod

=item device
=item summary       Modul to retrieves data from a Tesla Powerwall 2AC
=item summary_DE 

=begin html

<a name="TeslaPowerwall2AC"></a>
<h3>Tesla Powerwall 2 AC</h3>
<ul>
    <u><b>TeslaPowerwall2AC - Retrieves data from a Tesla Powerwall 2AC System</b></u>
    <br>
    With this module it is possible to read the data from a Tesla Powerwall 2AC and to set it as reading.
    <br><br>
    <a name="TeslaPowerwall2ACdefine"></a>
    <b>Define</b>
    <ul><br>
        <code>define &lt;name&gt; TeslaPowerwall2AC &lt;HOST&gt;</code>
    <br><br>
    Example:
    <ul><br>
        <code>define myPowerWall TeslaPowerwall2AC 192.168.1.34</code><br>
    </ul>
    <br>
    This statement creates a Device with the name myPowerWall and the Host IP 192.168.1.34.<br>
    After the device has been created, the current data of Powerwall is automatically read from the device.
    </ul>
    <br><br>
    <a name="TeslaPowerwall2ACreadings"></a>
    <b>Readings</b>
    <ul>
        <li>actionQueue     - information about the entries in the action queue</li>
        <li>aggregates-*    - readings of the /api/meters/aggregates response</li>
        <li>batteryLevel    - battery level in percent</li>
        <li>batteryPower    - battery capacity in kWh</li>
        <li>powerwalls-*    - readings of the /api/powerwalls response</li>
        <li>registration-*  - readings of the /api/customer/registration response</li>
        <li>siteinfo-*      - readings of the /api/site_info response</li>
        <li>sitemaster-*    - readings of the /api/sitemaster response</li>
        <li>state           - information about internel modul processes</li>
        <li>status-*        - readings of the /api/status response</li>
        <li>statussoe-*     - readings of the /api/system_status/soe response</li>
    </ul>
    <a name="TeslaPowerwall2ACget"></a>
    <b>get</b>
    <ul>
        <li>aggregates      - fetch data from url path /api/meters/aggregates</li>
        <li>powerwalls      - fetch data from url path /api/powerwalls</li>
        <li>registration    - fetch data from url path /api/customer/registration</li>
        <li>siteinfo        - fetch data from url path /api/site_info</li>
        <li>sitemaster      - fetch data from url path /api/sitemaster</li>
        <li>status          - fetch data from url path /api/status</li>
        <li>statussoe       - fetch data from url path /api/system_status/soe</li>
    </ul>
    <a name="TeslaPowerwall2ACattribute"></a>
    <b>Attribute</b>
    <ul>
        <li>interval - interval in seconds for automatically fetch data (default 300)</li>
    </ul>
</ul>

=end html
=begin html_DE

<a name="TeslaPowerwall2AC"></a>
<h3>Tesla Powerwall 2 AC</h3>

=end html_DE

=for :application/json;q=META.json 46_TeslaPowerwall2AC.pm
{
  "abstract": "Modul to retrieves data from a Tesla Powerwall 2AC",
  "x_lang": {
    "de": {
      "abstract": ""
    }
  },
  "keywords": [
    "fhem-mod-device",
    "fhem-core",
    "Power",
    "Tesla",
    "AC",
    "Powerwall",
    "Control"
  ],
  "release_status": "under develop",
  "license": "GPL_2",
  "version": "v0.6.102",
  "author": [
    "Marko Oldenburg <leongaultier@gmail.com>"
  ],
  "x_fhem_maintainer": [
    "CoolTux"
  ],
  "x_fhem_maintainer_github": [
    "LeonGaultier"
  ],
  "prereqs": {
    "runtime": {
      "requires": {
        "FHEM": 5.00918799,
        "perl": 5.016, 
        "Meta": 0,
        "JSON": 0,
        "Date::Parse": 0
      },
      "recommends": {
      },
      "suggests": {
      }
    }
  }
}
=end :application/json;q=META.json

=cut
