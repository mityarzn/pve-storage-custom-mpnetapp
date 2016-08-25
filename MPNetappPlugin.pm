package PVE::Storage::Custom::MPNetappPlugin;

use strict;
use warnings;
use Data::Dumper;
use IO::File;
use PVE::Tools qw(run_command trim file_read_firstline dir_glob_foreach);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use LWP::UserAgent;
use HTTP::Request;
use XML::Simple;

use base qw(PVE::Storage::Plugin);

sub netapp_request {
    my ($scfg, $vserver, $params) = @_;

	my $vfiler = $vserver ? "vfiler='$vserver'" : "";

	my $content = "<?xml version='1.0' encoding='UTF-8' ?>\n";
	$content .= "<!DOCTYPE netapp SYSTEM 'file:/etc/netapp_filer.dtd'>\n";
	$content .= "<netapp $vfiler version='1.19' xmlns='http://www.netapp.com/filer/admin'>\n";
	$content .= $params;
	$content .= "</netapp>\n";
	my $url = "http://".$scfg->{adminserver}."/servlets/netapp.servlets.admin.XMLrequest_filer";
	my $request = HTTP::Request->new('POST',"$url");
	$request->authorization_basic($scfg->{login},$scfg->{password});

	$request->content($content);
	$request->content_length(length($content));
	my $ua = LWP::UserAgent->new;
	my $response = $ua->request($request);
	my $xmlparser = XML::Simple->new( KeepRoot => 1 );
	my $xmlresponse = $xmlparser->XMLin($response->{_content});

	if(ref $xmlresponse->{netapp}->{results} eq 'ARRAY'){
	    foreach my $result (@{$xmlresponse->{netapp}->{results}}) {
		if($result->{status} ne 'passed'){
		    die "netapp api error : ".$result->{reason};
		}
	    }
	}
	elsif ($xmlresponse->{netapp}->{results}->{status} ne 'passed') {
	    die "netapp api error : ".$content.$xmlresponse->{netapp}->{results}->{reason};
	}

	return $xmlresponse;
}

sub netapp_build_params {
    my ($execute, %params) = @_;

    my $xml = "<$execute>\n";
    while (my ($property, $value) = each(%params)){
	$xml.="<$property>$value</$property>\n";
    }
    $xml.="</$execute>\n";

    return $xml;

}

sub _name2vol {
	my ($vol) = @_;
	$vol =~ s/-/_/g;
	$vol .= '_vol';
	return $vol;
}


sub netapp_create_volume {
    my ($scfg, $name, $size) = @_;

    my $volume = _name2vol($name);

    my $aggregate = $scfg->{aggregate};
    my $xmlparams = ($scfg->{api} == 8 && $scfg->{vserver})?netapp_build_params("volume-create", "containing-aggr-name" => $aggregate, "volume" => $volume, "size" => "$size", "junction-path" => "/images/$volume", "space-reserve" => "none"):
		    netapp_build_params("volume-create", "containing-aggr-name" => $aggregate, "volume" => $volume, "size" => "$size", "space-reserve" => "none");
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);

}

sub netapp_sisenable_volume {
    my ($scfg, $name) = @_;

    my $volume = _name2vol($name);
    my $xmlparams = netapp_build_params("sis-enable", "path" => "/vol/$volume");
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);
}

sub netapp_sissetconfig_volume {
    my ($scfg, $name) = @_;

    my $volume = _name2vol($name);
    my $xmlparams = netapp_build_params("sis-set-config", "enable-compression" => "true", "enable-inline-compression" => "false", "schedule" => "-", "path" => "/vol/$volume");
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);
}

sub netapp_autosize_volume {
    my ($scfg, $name) = @_;

    my $volume = _name2vol($name);
    my $xmlparams = ($scfg->{api} == 8)?
		netapp_build_params('volume-autosize-set', 'mode' => 'grow_shrink', 'volume' => _name2vol($name)):
		netapp_build_params('volume-autosize-set', 'is-enabled' => 'true', 'volume' => _name2vol($name));
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);
}

sub netapp_snapshotsetreserve_volume {
    my ($scfg, $name) = @_;

    my $volume = _name2vol($name);
    my $xmlparams = netapp_build_params("snapshot-set-reserve", "volume" => _name2vol($name), "percentage" => "0");
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);
}

sub netapp_resize_volume {
    my ($scfg, $name, $size) = @_;

    netapp_request($scfg, $scfg->{vserver}, netapp_build_params("volume-size", "volume" => _name2vol($name), "new-size" => "$size" ));
}

sub netapp_snapshot_create {
    my ($scfg, $name, $snapname) = @_;

    netapp_request($scfg, $scfg->{vserver}, netapp_build_params("snapshot-create", "volume" => _name2vol($name), "snapshot" => "$snapname" ));
}

sub netapp_snapshot_exist {
    my ($scfg, $name, $snap) = @_;

    my $volume = _name2vol($name);
    my $snapshotslist = netapp_request($scfg, $scfg->{vserver}, netapp_build_params("snapshot-list-info", "volume" => _name2vol($name)));
    my $snapshotexist = undef;
    $snapshotexist = 1 if (defined($snapshotslist->{"netapp"}->{"results"}->{"snapshots"}->{"snapshot-info"}->{"$snap"}));
    $snapshotexist = 1 if (defined($snapshotslist->{netapp}->{results}->{"snapshots"}->{"snapshot-info"}->{name}) && $snapshotslist->{netapp}->{results}->{"snapshots"}->{"snapshot-info"}->{name} eq $snap);
    return $snapshotexist;
}

sub netapp_snapshot_rollback {
    my ($scfg, $name, $snapname) = @_;

    netapp_request($scfg, $scfg->{vserver}, netapp_build_params("snapshot-restore-volume", "volume" => _name2vol($name), "snapshot" => "$snapname" ));
}

sub netapp_snapshot_delete {
    my ($scfg, $name, $snapname) = @_;

    netapp_request($scfg, $scfg->{vserver}, netapp_build_params("snapshot-delete", "volume" => _name2vol($name), "snapshot" => "$snapname" ));
}

sub netapp_unmount_volume {
    my ($scfg, $name) = @_;

    my $xmlparams = netapp_build_params("volume-unmount", "volume-name" => _name2vol($name), "force" => "true");
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);
}

sub netapp_offline_volume {
    my ($scfg, $name) = @_;

    my $xmlparams = netapp_build_params("volume-offline", "name" => _name2vol($name));
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);
}

sub netapp_destroy_volume {
    my ($scfg, $name) = @_;

    my $xmlparams = netapp_build_params("volume-destroy", "name" => _name2vol($name));
    netapp_request($scfg, $scfg->{vserver}, $xmlparams);
}

sub netapp_get_lun_id {
    my ($scfg, $name) = @_;
    my $path = '/vol/' . _name2vol($name) . "/$name";

    my $xmlresponse = netapp_request($scfg, $scfg->{vserver}, netapp_build_params('lun-map-list-info', 'path' => $path));

#    return $xmlresponse;
    my $iginfo = (ref($xmlresponse->{'netapp'}->{'results'}->{'initiator-groups'}->{'initiator-group-info'}) eq 'ARRAY')?
		    $xmlresponse->{'netapp'}->{'results'}->{'initiator-groups'}->{'initiator-group-info'}:
		    [$xmlresponse->{'netapp'}->{'results'}->{'initiator-groups'}->{'initiator-group-info'}];

    foreach my $ig (@$iginfo) {
	return $ig->{'lun-id'} if $ig->{'initiator-group-name'} eq $scfg->{igroup};
    }
    return undef;
}

sub netapp_list_luns {
    my ($scfg, $vmid) = @_;
    my $list = {};

    if ($scfg->{api} == 8) {
	my $xmlresponse = netapp_request($scfg, $scfg->{'vserver'},
		'<lun-get-iter><desired-attributes><lun-attributes><path></path><serial-number></serial-number>'.
		'<size></size><state></state><mapped></mapped></lun-attributes></desired-attributes>'.
		'<max-records>5000</max-records></lun-get-iter>');

	# For first LUN there may be not-array reference. So, turn it into single-element array.
	my $luns = (ref($xmlresponse->{'netapp'}->{'results'}->{'attributes-list'}->{'lun-attributes'}) eq 'ARRAY')?
		    $xmlresponse->{'netapp'}->{'results'}->{'attributes-list'}->{'lun-attributes'}:
		    [$xmlresponse->{'netapp'}->{'results'}->{'attributes-list'}->{'lun-attributes'}];

	foreach my $lun (@$luns) {
	    next unless $lun->{'path'} =~  m!/vol/(\S+)/(vm-(\d+)-disk-\d+)$!;
	    next if defined($vmid) and $3 != $vmid;

	    my $name = $2;
	    $list->{$name}->{'vol'} = $1;
	    # Get wwn from LUN's serial number
	    $list->{$name}->{'wwn'} = $lun->{'serial-number'};
	    $list->{$name}->{'wwn'} =~ s/(.)/sprintf("%x",ord($1))/eg; #convert to hex
	    $list->{$name}->{'wwn'} = '60a98000' . $list->{$name}->{'wwn'}; # Add netapp-specific prefix
	    $list->{$name}->{'path'} = $lun->{'path'};
	    $list->{$name}->{'size'} = $lun->{'size'};
	    $list->{$name}->{'online'} = ($lun->{'state'} eq 'online')?'true':'false';
	    $list->{$name}->{'mapped'} = $lun->{'mapped'};
	}
    } elsif ($scfg->{api} == 7) {

	my $xmlresponse = netapp_request($scfg, $scfg->{'vserver'}, netapp_build_params('lun-list-info'));

	# For first LUN there may be not-array reference. So, turn it into single-element array.
	my $luns = (ref($xmlresponse->{'netapp'}->{'results'}->{'luns'}->{'lun-info'}) eq 'ARRAY')?
		    $xmlresponse->{'netapp'}->{'results'}->{'luns'}->{'lun-info'}:
		    [$xmlresponse->{'netapp'}->{'results'}->{'luns'}->{'lun-info'}];

	foreach my $lun (@$luns) {
	    next unless $lun->{'path'} =~  m!/vol/(\S+)/(vm-(\d+)-disk-\d+)$!;
	    next if defined($vmid) and $3 != $vmid;

	    my $name = $2;
	    $list->{$name}->{'vol'} = $1;
	    # Get wwn from LUN's serial number
	    $list->{$name}->{'wwn'} = $lun->{'serial-number'};
	    $list->{$name}->{'wwn'} =~ s/(.)/sprintf("%x",ord($1))/eg; #convert to hex
	    $list->{$name}->{'wwn'} = '60a98000' . $list->{$name}->{'wwn'}; # Add netapp-specific prefix
	    $list->{$name}->{'path'} = $lun->{'path'};
	    $list->{$name}->{'size'} = $lun->{'size'};
	    $list->{$name}->{'online'} = $lun->{'online'};
	    $list->{$name}->{'mapped'} = $lun->{'mapped'};
	}
    }

    return $list;
}

sub netapp_create_lun {
    my ($scfg, $name, $size) = @_;

    my $vol = _name2vol($name);
    my $xmlparams = ($scfg->{api} == 8)?
		netapp_build_params('lun-create-by-size', 'ostype' => 'linux', 'path' => "/vol/$vol/$name" , 'size' => $size,
			'space-allocation-enabled' => 'true', 'space-reservation-enabled' => 'false'):
		netapp_build_params('lun-create-by-size', 'ostype' => 'linux', 'path' => "/vol/$vol/$name" , 'size' => $size,
			'space-reservation-enabled' => 'false');

    netapp_request($scfg, $scfg->{'vserver'}, $xmlparams);
}

sub netapp_map_lun {
    my ($scfg, $name) = @_;

    my $vol = _name2vol($name);
    my $xmlparams = netapp_build_params('lun-map', 'initiator-group' => $scfg->{igroup}, 'path' => "/vol/$vol/$name");

    netapp_request($scfg, $scfg->{'vserver'}, $xmlparams);
}

sub netapp_resize_lun {
    my ($scfg, $name, $newsize) = @_;

    my $vol = _name2vol($name);
    my $xmlparams = netapp_build_params('lun-resize', 'path' => "/vol/$vol/$name", 'size' => $newsize);
    netapp_request($scfg, $scfg->{'vserver'}, $xmlparams);
}

sub netapp_unmap_lun {
    my ($scfg, $name) = @_;

    my $vol = _name2vol($name);
    my $xmlparams = netapp_build_params('lun-unmap', 'initiator-group' => $scfg->{'igroup'}, 'path' => "/vol/$vol/$name");

    netapp_request($scfg, $scfg->{'vserver'}, $xmlparams);
}

sub netapp_delete_lun {
    my ($scfg, $name) = @_;
    my $vol = _name2vol($name);

    # First, get lun offline
    netapp_request($scfg, $scfg->{'vserver'}, netapp_build_params('lun-offline', 'path' => "/vol/$vol/$name"));

    # Then delete it
    netapp_request($scfg, $scfg->{'vserver'}, netapp_build_params('lun-destroy', 'path' => "/vol/$vol/$name"));
}

sub netapp_aggregate_size {
    my ($scfg) = @_;

    if ($scfg->{api} == 8) {
	my $list = netapp_request($scfg, undef, netapp_build_params("aggr-get-iter", "desired-attributes" => "" ));

        foreach my $aggregate (@{$list->{netapp}->{results}->{"attributes-list"}->{"aggr-attributes"}}) {
	    if($aggregate->{"aggregate-name"} eq $scfg->{aggregate}){
	        my $used = $aggregate->{"aggr-space-attributes"}->{"size-used"};
	        my $total = $aggregate->{"aggr-space-attributes"}->{"size-total"};
	        my $free = $aggregate->{"aggr-space-attributes"}->{"size-available"};
	        return ($total, $free, $used, 1);
	    }
	}
    } elsif ($scfg->{api} == 7) {
	my $xmlresponse = netapp_request($scfg, undef, netapp_build_params("aggr-space-list-info"));
	my $aggrs = (ref($xmlresponse->{netapp}->{results}->{"aggregates"}->{"aggr-space-info"}) eq 'ARRAY')?
		     $xmlresponse->{netapp}->{results}->{"aggregates"}->{"aggr-space-info"}:
		     [$xmlresponse->{netapp}->{results}->{"aggregates"}->{"aggr-space-info"}];

        foreach my $aggregate (@$aggrs) {
	    if($aggregate->{"aggregate-name"} eq $scfg->{aggregate}){
		my $used = $aggregate->{"size-used"};
		my $total = $aggregate->{"size-nominal"};
		my $free = $aggregate->{"size-free"};
		return [$total, $free, $used, 1];
	    }
	}
    }
}

# Utility functions
sub mp_get_name {
    my ($class, $scfg, $wwn) = @_;

    my $luns = netapp_list_luns($scfg, undef);

    foreach my $name (keys %$luns) {
	return $name if $luns->{$name}->{'wwn'} eq $wwn;
    }
    die "cannot get name for wwn $wwn\n";
}

sub mp_get_wwn {
    my ($class, $scfg, $name) = @_;

    my $luns = netapp_list_luns($scfg, undef);

    return $luns->{$name}->{'wwn'};
}

sub multipath_enable {
    my ($class, $scfg, $wwn) = @_;

    # Skip if device exists
    return if -e "/dev/disk/by-id/dm-uuid-mpath-0x$wwn";

    open my $mpd, '<', '/etc/multipath.conf';
    open my $mpdt, '>', '/etc/multipath.conf.new';

    #Copy contents and insert line just afer exceptions block beginning
    while (my $line = <$mpd>) {
	print $mpdt $line;
	print $mpdt "\twwid \"0x$wwn\"\n" if $line =~ m/^blacklist_exceptions \{/;
    }

    close $mpdt;
    close $mpd;
    unlink '/etc/multipath.conf';
    rename '/etc/multipath.conf.new','/etc/multipath.conf';

    # Scan storage bus for new paths. Linux SCSI subsystem is not automatic,
    # so it doesn't know when new LUNS appear|disappear, and we need to kick it.
    run_command(['/usr/sbin/scsi-scan.sh', '--rescan-all']);

    #force devmap reload to connect new device
    system('/sbin/multipath', '-r');
}

sub multipath_disable {
    my ($class, $scfg, $wwn) = @_;

    open my $mpd, '<', '/etc/multipath.conf';
    open my $mpdt, '>', '/etc/multipath.conf.new';

    #Just copy contents except requested wwn
    while (my $line = <$mpd>) {
	print $mpdt $line unless $line =~ m/wwid "0x$wwn"/;
    }

    close $mpdt;
    close $mpd;
    unlink '/etc/multipath.conf';
    rename '/etc/multipath.conf.new','/etc/multipath.conf';

    # flush buffers and give some time for runned process to free device
    system('/bin/sync');
    sleep 1;

    #disable selected wwn multipathing
    system('/sbin/multipath', '-f', "0x$wwn");
}

# Configuration

# API version
sub api {
    return 1;
}

sub type {
    return 'mpnetapp';
}

sub plugindata {
    return {
	content => [ {images => 1, rootdir => 1, none => 1}, { images => 1 }],
    };
}

sub properties {
    return {
        vserver => {
            description => "Vserver name.",
            type => 'string',
        },
        aggregate => {
            description => "Array/Pool/Aggregate name.",
            type => 'string',
        },
	adminserver => {
	    description => "Management IP or DNS name of storage.",
	    type => 'string', format => 'pve-storage-server',
	},
	login => {
	    description => "login",
	    type => 'string',
	},
	password => {
	    description => "password",
	    type => 'string',
	},
	igroup => {
	    description => "Initiator group name",
	    type => 'string',
	},
	api => {
	    description => "API version (7 or 8)",
	    type => 'string',
	},
	media => {
	    description => "iscsi/multipath",
	    type => 'string',
	    default => 'multipath',
	    enum => ['iscsi', 'multipath'],
	},
    };
}

sub options {
    return {
	adminserver => { fixed => 1 },
	login => { fixed => 1 },
	password => { optional => 1 },
	vserver => { optional => 1 },
	aggregate => { fixed => 1 },
        nodes => { optional => 1 },
	disable => { optional => 1 },
	content => { optional => 1 },
	igroup => { optional => 1 },
	api => { optional => 1 },
	media => { optional => 1 },
	target => { optional => 1 },
    }
}

# Storage implementation

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/vm-(\d+)-disk-\S+/) {
	return ('images', $volname, $1, undef, undef, undef, 'raw');
    } else {
	die "Invalid volume $volname";
    }
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;
    my $path;

    die "Direct attached device snapshot is not implemented" if defined($snapname);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    if ($scfg->{'media'} eq 'iscsi') {
	die "With iscsi media, target name must be defined" if !defined($scfg->{'target'});

	$path = sprintf("iscsi://%s/%s/%s",
		    ($scfg->{'vserver'})?$scfg->{'vserver'}:$scfg->{'adminserver'},
		    $scfg->{'target'},
		    netapp_get_lun_id($scfg,$name));
    } elsif ($scfg->{'media'} eq 'multipath') {
	die "Cannot find WWN for volume $volname" unless my $wwn = $class->mp_get_wwn($scfg, $name);
	$path = "/dev/disk/by-id/dm-uuid-mpath-0x$wwn";
    } else {
	die "Unknown media $scfg->{'media'}";
    }

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "Creating base image is currently unimplemented";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    die "Cloning image is currently unimplemented";
}

# Seems like this method gets size in kilobytes somehow,
# while listing methost return bytes. That's strange.
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    my $luns = netapp_list_luns($scfg, $vmid);

    unless ($name) {
	for (my $i = 1; $i < 100; $i++) {
	    if (!$luns->{"vm-$vmid-disk-$i"}) {
		$name = "vm-$vmid-disk-$i";
		last;
	    }
	}
    }

    # Netapp's GUI reserves 5% for snapshots by default, reproduce it.
    netapp_create_volume($scfg, $name, int($size*1.05)*1024);
    netapp_sisenable_volume($scfg, $name);
    netapp_sissetconfig_volume($scfg, $name);
    netapp_autosize_volume($scfg, $name);
    netapp_snapshotsetreserve_volume($scfg, $name);
    netapp_create_lun($scfg, $name, $size*1024);

    netapp_map_lun($scfg, $name);

    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my $wwn = $class->mp_get_wwn($scfg, $volname);

    netapp_unmap_lun($scfg, $volname);

    netapp_delete_lun($scfg, $volname);
    netapp_unmount_volume($scfg,$volname) if ($scfg->{api} == 8 && $scfg->{vserver});
    netapp_offline_volume($scfg,$volname);
    netapp_destroy_volume($scfg,$volname);

    dir_glob_foreach('/etc/pve/nodes', '\w+', sub {
	my ($node) = @_;
	run_command(['/usr/bin/ssh', $node, '/usr/sbin/scsi-scan.sh --remove-offline']);
    });
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $res = [];

    my $luns = netapp_list_luns($scfg, $vmid);

    foreach my $name (keys %$luns) {

	my $volid = "$storeid:$name";

	if ($vollist) {
	    my $found = grep { $_ eq $volid } @$vollist;
	    next if !$found;
	} else {
	    next if defined($vmid);
	}

	push @$res, {
	    'volid' => $volid, 'format' => 'raw', 'size' => $luns->{$name}->{'size'},
	};

    }

    return $res;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    return @{netapp_aggregate_size($scfg)};
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Server's SCSI subsystem is always up, so there's nothing to do
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "volume snapshot [de]activation not possible on multipath device" if $snapname;

    warn "Activating '$volname'\n";

    $class->multipath_enable($scfg, $class->mp_get_wwn($scfg,$volname));


    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "volume snapshot [de]activation not possible on multipath device" if $snapname;

    warn "Deactivating '$volname'\n";
    $class->multipath_disable($scfg, $class->mp_get_wwn($scfg,$volname)) if ($scfg->{'media'} eq 'multipath');

    return 1;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    netapp_resize_volume($scfg, $volname, $size);
    netapp_resize_lun($scfg, $volname, $volname, $size);

    if ($scfg->{'media'} eq 'multipath') {
	my $wwn = $class->mp_get_wwn($scfg,$volname);
	run_command(['/usr/sbin/scsi-scan.sh', '--rescan-wwid', "0x$wwn"]);
    }
    return 1;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    netapp_snapshot_create($scfg, $volname, $snap);
    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    netapp_snapshot_rollback($scfg, $volname, $snap);

    #size could be changed here? Check for device changes.
    if ($scfg->{'media'} eq 'multipath') {
	my $wwn = $class->mp_get_wwn($scfg,$volname);
	run_command(['/usr/sbin/scsi-scan.sh', '--rescan-wwid', "0x$wwn"]);
    }
    return 1;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    netapp_snapshot_delete($scfg, $volname, $snap);
    return 1;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
	snapshot => { current => 1, snap => 1 },
	sparseinit => { current => 1 },
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
	$class->parse_volname($volname);

    my $key = undef;
    if($snapname) {
	$key = 'snap';
    } else {
	$key =  $isBase ? 'base' : 'current';
    }
    return 1 if $features->{$feature}->{$key};

    return undef;
}

1;
