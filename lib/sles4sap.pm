## no critic (RequireFilenameMatchesPackage);
package sles4sap;
use base "opensusebasetest";

use strict;
use warnings;
use testapi;
use utils;
use hacluster 'pre_run_hook';
use isotovideo;
use x11utils 'ensure_unlocked_desktop';

our @EXPORT = qw(
  ensure_serialdev_permissions_for_sap
  fix_path
  set_ps_cmd
  set_sap_info
  become_sapadm
  get_total_mem
  prepare_profile
  copy_media
  test_pids_max
  test_forkbomb
  test_version_info
  test_instance_properties
  test_stop
  test_start_service
  test_start_instance
);

our $prev_console;
our $sapadmin;
our $sid;
our $instance;
our $ps_cmd;

=head2 ensure_serialdev_permissions_for_sap

Derived from 'ensure_serialdev_permissions' function available in 'utils'.

Grant user permission to access serial port immediately as well as persisting
over reboots. Used to ensure that testapi calls like script_run work for the
test user as well as root.
=cut
sub ensure_serialdev_permissions_for_sap {
    my ($self) = @_;
    # ownership has effect immediately, group change is for effect after
    # reboot an alternative https://superuser.com/a/609141/327890 would need
    # handling of optional sudo password prompt within the exec
    my $serial_group = script_output "stat -c %G /dev/$testapi::serialdev";
    assert_script_run "grep '^${serial_group}:.*:${sapadmin}\$' /etc/group || (chown $sapadmin /dev/$testapi::serialdev && gpasswd -a $sapadmin $serial_group)";
}

sub fix_path {
    my ($self, $var) = @_;
    my ($proto, $path) = split m|://|, $var;
    my @aux = split '/', $path;

    $proto = 'cifs' if ($proto eq 'smb' or $proto eq 'smbfs');
    die 'Currently only supported protocols are nfs and smb/smbfs/cifs'
      unless ($proto eq 'nfs' or $proto eq 'cifs');

    $aux[0] .= ':' if ($proto eq 'nfs');
    $aux[0] = '//' . $aux[0] if ($proto eq 'cifs');
    $path = join '/', @aux;
    return ($proto, $path);
}

sub set_ps_cmd {
    my ($self, $procname) = @_;
    $ps_cmd = 'ps auxw | grep ' . $procname . ' | grep -vw grep';
    return $ps_cmd;
}

sub set_sap_info {
    my ($self, $sid_env, $instance_env) = @_;
    $sid      = uc($sid_env);
    $instance = $instance_env;
    $sapadmin = lc($sid_env) . 'adm';
    return ($sapadmin);
}

sub become_sapadm {
    # Allow SAP Admin user to inform status via $testapi::serialdev
    # Note: need to be keep here and during product installation to
    #       ensure compatibility with older generated images
    ensure_serialdev_permissions_for_sap;

    type_string "su - $sapadmin\n";

    # Change the working shell to bash as SAP's installer sets the admin
    # user's shell to /bin/csh and csh has problems with strings that start
    # with ~ which can be generated by testapi::hashed_string() leading to
    # unexpected failures of script_output() or assert_script_run()
    type_string "exec bash\n";
}

sub get_total_mem {
    return get_required_var('QEMURAM') if (check_var('BACKEND', 'qemu'));
    my $mem = script_output q@grep ^MemTotal /proc/meminfo | awk '{print $2}'@;
    $mem /= 1024;
    return $mem;
}

sub is_saptune_installed {
    my $ret = script_run "rpm -q saptune";
    return (defined $ret and $ret == 0);
}

sub is_nw_profile {
    my $list = script_output "tuned-adm list";
    return ($list =~ /sap-netweaver/);
}

sub prepare_profile {
    my ($self, $profile) = @_;
    return unless ($profile eq 'HANA' or $profile eq 'NETWEAVER');

    # Will prepare system with saptune only if it's available.
    # Otherwise will try to use the tuned 'sap-netweaver' profile
    # for netweaver and the recommended one for hana
    my $has_saptune = $self->is_saptune_installed();

    if ($has_saptune) {
        assert_script_run "tuned-adm profile saptune";
        assert_script_run "saptune solution apply $profile";
    }
    elsif ($profile eq 'NETWEAVER') {
        $profile = $self->is_nw_profile() ? 'sap-netweaver' : '$(tuned-adm recommend)';
        assert_script_run "tuned-adm profile $profile";
    }
    elsif ($profile eq 'HANA') {
        assert_script_run 'tuned-adm profile $(tuned-adm recommend)';
    }

    if (!$has_saptune) {
        # Restart systemd-logind to ensure that all new connections will have the
        # SAP tuning activated. Since saptune v2, the call to 'saptune solution apply'
        # above can make the SUT change focus to the x11 console, which may not be ready
        # for the systemctl command. If the systemctl command times out, change to
        # root-console and try again. Run the first call to systemctl with
        # ignore_failure => 1 to avoid stopping the test. Second call runs as usual
        my $ret = systemctl('restart systemd-logind.service', ignore_failure => 1);
        die "systemctl restart systemd-logind.service failed with retcode: [$ret]" if $ret;
        if (!defined $ret) {
            select_console 'root-console';
            systemctl 'restart systemd-logind.service';
        }
    }

    # X11 workaround only on ppc64le
    if (get_var('OFW')) {
        # 'systemctl restart systemd-logind' is causing the X11 console to move
        # out of tty2 on SLES4SAP-15, which in turn is causing the change back to
        # the previous console in post_run_hook() to fail when running on systems
        # with DESKTOP=gnome, which is a false positive as the test has already
        # finished by that step. The following prevents post_run_hook from attempting
        # to return to the console that was set before this test started. For more
        # info on why X is running in tty2 on SLES4SAP-15, see bsc#1054782
        $prev_console = undef;

        # If running in DESKTOP=gnome, systemd-logind restart may cause the graphical console to
        # reset and appear in SUD, so need to select 'root-console' again
        assert_screen(
            [
                qw(root-console displaymanager displaymanager-password-prompt generic-desktop
                  text-login linux-login started-x-displaymanager-info)
            ], 120);
        select_console 'root-console' unless (match_has_tag 'root-console');
    }
    else {
        # If running in DESKTOP=gnome, systemd-logind restart may cause the graphical
        # console to reset and appear in SUD, so need to select 'root-console' again
        # 'root-console' can be re-selected safely even if DESKTOP=textmode
        select_console 'root-console';
    }

    if ($has_saptune) {
        assert_script_run "saptune daemon start";
        my $ret = script_run "saptune solution verify $profile";
        if (!defined $ret) {
            # Command timed out. 'saptune daemon start' could have caused the SUT to
            # move out of root-console, so select root-console and try again
            select_console 'root-console';
            $ret = script_run "saptune solution verify $profile";
        }
        record_soft_failure("poo#54695: 'saptune solution verify' returned warnings or errors! Please check!")
          if $ret;

        my $output = script_output "saptune daemon status", proceed_on_failure => 1;
        if (!defined $output) {
            # Command timed out or failed. 'saptune solution verify' could have caused
            # the SUT to move out of root-console, so select root-console and try again
            select_console 'root-console';
            $output = script_output "saptune daemon status";
        }
        record_info("tuned status", $output);
    }
    else {
        assert_script_run "systemctl restart tuned";
    }

    my $output = script_output "tuned-adm active";
    record_info("tuned profile", $output);
}

sub copy_media {
    my ($self, $proto, $path, $nettout, $target) = @_;

    # First copy media
    assert_script_run "mkdir $target";
    assert_script_run "mount -t $proto $path /mnt";
    type_string "cd /mnt\n";
    type_string "cd " . get_var('ARCH') . "\n";    # Change to ARCH specific subdir if exists
    assert_script_run "cp -ax . $target/", $nettout;

    # Then verify everything was copied correctly
    my $cmd = q|find . -type f -exec md5sum {} \; > /tmp/check-nw-media|;
    assert_script_run $cmd, $nettout;
    type_string "cd $target\n";
    assert_script_run "umount /mnt";
    assert_script_run "md5sum -c /tmp/check-nw-media", $nettout;
}

sub test_pids_max {
    # UserTasksMax should be set to "infinity" in /etc/systemd/logind.conf.d/sap.conf
    my $uid = script_output "id -u $sapadmin";
    # The systemd-run command generates syslog output that may end up in the console, so save the output to a file
    assert_script_run "systemd-run --slice user -qt su - $sapadmin -c 'cat /sys/fs/cgroup/pids/user.slice/user-${uid}.slice/pids.max' | tr -d '\\r' | tee /tmp/pids-max";
    my $rc1 = script_run "grep -qx max /tmp/pids-max";
    # nproc should be set to "unlimited" in /etc/security/limits.d/99-sapsys.conf
    # Check that nproc * 2 + 1 >= threads-max
    assert_script_run "systemd-run --slice user -qt su - $sapadmin -c 'ulimit -u' -s /bin/bash | tr -d '\\r' > /tmp/nproc";
    assert_script_run "cat /tmp/nproc ; sysctl -n kernel.threads-max";
    my $rc2 = script_run "[[ \$(( \$(< /tmp/nproc) * 2 + 1)) -ge \$(sysctl -n kernel.threads-max) ]]";
    record_soft_failure "bsc#1031355" if ($rc1 or $rc2);
}

sub test_forkbomb {
    # NOTE: Do not call this function on the qemu backend.
    #   The first forkbomb can create 3 times as many processes as the second due to unknown bug
    assert_script_run "curl -f -v " . autoinst_url . "/data/sles4sap/forkbomb.pl > /tmp/forkbomb.pl; chmod +x /tmp/forkbomb.pl";
    # The systemd-run command generates syslog output that may end up in the console, so save the output to a file
    assert_script_run "systemd-run --slice user -qt su - $sapadmin -c /tmp/forkbomb.pl | tr -d '\\r' > /tmp/user-procs", 600;
    my $user_procs = script_output "cat /tmp/user-procs";
    my $root_procs = script_output "/tmp/forkbomb.pl", 600;
    # Check that the SIDadm user can create at least 99% of the processes root could create
    record_soft_failure "bsc#1031355" if ($user_procs < $root_procs * 0.99);
}

sub test_version_info {
    my $output = script_output "sapcontrol -nr $instance -function GetVersionInfo";
    die "sapcontrol: GetVersionInfo API failed\n\n$output" unless ($output =~ /GetVersionInfo[\r\n]+OK/);
}

sub test_instance_properties {
    my $output = script_output "sapcontrol -nr $instance -function GetInstanceProperties | grep ^SAP";
    die "sapcontrol: GetInstanceProperties API failed\n\n$output" unless ($output =~ /SAPSYSTEM.+SAPSYSTEMNAME.+SAPLOCALHOST/s);

    $output =~ /SAPSYSTEMNAME, Attribute, ([A-Z][A-Z0-9]{2})/m;
    die "sapcontrol: SAP administrator [$sapadmin] does not match with System SID [$1]" if ($1 ne $sid);
}

sub test_stop {
    my $output = script_output "sapcontrol -nr $instance -function Stop";
    die "sapcontrol: Stop API failed\n\n$output" unless ($output =~ /Stop[\r\n]+OK/);

    $output = script_output "sapcontrol -nr $instance -function StopService";
    die "sapcontrol: StopService API failed\n\n$output" unless ($output =~ /StopService[\r\n]+OK/);
}

sub test_start_service {
    my $output = script_output "sapcontrol -nr $instance -function StartService $sid";
    die "sapcontrol: StartService API failed\n\n$output" unless ($output =~ /StartService[\r\n]+OK/);

    # We can't use the $ps_cmd alias, as number of process can be >1 on some HANA version
    $output = script_output "pgrep -a sapstartsrv | grep -w $sid";
    my @olines = split(/\n/, $output);
    die "sapcontrol: wrong number of processes running after a StartService\n\n" . @olines unless (@olines == 1);
    die "sapcontrol failed to start the service" unless ($output =~ /sapstartsrv/);
}

sub test_start_instance {
    my $output = script_output "sapcontrol -nr $instance -function Start";
    die "sapcontrol: Start API failed\n\n$output" unless ($output =~ /Start[\r\n]+OK/);

    $output = script_output $ps_cmd;
    my @olines = split(/\n/, $output);
    die "sapcontrol: failed to start the instance" unless (@olines > 1);
}

sub post_run_hook {
    my ($self) = @_;

    return unless ($prev_console);
    select_console($prev_console, await_console => 0);
    ensure_unlocked_desktop if ($prev_console eq 'x11');
}

1;
