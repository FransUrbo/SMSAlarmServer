#!/usr/bin/perl -w

######################################################################
# 
# This is a script that tests how to read SMS messages (replies) from
# the Siemens M20 GSM modem.
#
# The CVS log messages can be found at the bottom of the file...
#
# $Author: turbo $
# $Id: sms_read.pl,v 1.1 2004-07-17 08:10:03 turbo Exp $

my($fd);
END {undef $fd;}

use Device::SerialPort 0.05;
use DBI;
use strict;

my $msg   = "";
my $phone = "";
my $dbg   = 0;
my $arg   = "";
my $pin   = "3245";
my $smsc  = "+46707990001";
my $sleep = "0.2";
my $cfg   = "/tmp/config";
 
# --------------------------------------------

$fd = &setup_connection("/dev/ttyS0");

if($#ARGV >= 0) {
    foreach $arg (@ARGV) {
	if($arg eq 'rst') {
	    &put_msg("Z");
	    exit(0);
	} elsif($arg eq 'chk') {
	    print "Not implemented.\n";
	    exit(0);
	} elsif($arg eq 'png') {
	    # Check status of modem
	    if(! &check_status()) {
		print "No carrier detected!\n";
		exit(1);
	    } else {
		print "*ping*\n";
		exit(0);
	    }
	} elsif($arg eq 'dbg') {
	    $dbg = 1;
	    shift(@ARGV);
	} elsif($arg eq 'opt') {
	    &print_options();
	    exit(0);
	} elsif(($arg eq '?') || ($arg eq '-h') || ($arg eq '--help')) {
	    &print_usage();
	} else {
	    if(! $phone) {
		$phone = $ARGV[0];
		shift(@ARGV);
	    }
	    if(!$msg) {
		$msg = "@ARGV";
	    } else {
		last;
	    }
	}
    }
}

&initialize();
&send_sms($phone, $msg);
exit(0);

# --------------------------------------------

sub setup_connection {
    my($dev) = @_;
    my($ob);

    $ob = Device::SerialPort->new($dev)
	|| die "Can't open $dev, $!\n";
    $ob->baudrate(19200)   || die "fail setting baudrate";
    $ob->databits(8);
    $ob->parity("none");
    $ob->stopbits(1);

    # Crappy, slow modem!
    $ob->read_char_time(3);		# Avg time between read char
    $ob->read_const_time(100);		# Milliseconds
    #$ob->write_char_time(5);		# Not supported
    #$ob->write_const_time(100);	# Not supported
    
    if(! -f "$cfg") {
	$ob->alias("MODEM1");
	$ob->save("$cfg")
	    || warn "Can't save $cfg: $!\n";
	print "Saved config file...\n";
    }

    # currently optional after new, POSIX version expected to succeed
    $ob->write_settings || die "no settings";
    
    return($ob);
}

sub initialize {
    my($res);

    &put_msg("E0");						# Local echo off

    &send_msg("+CSDH?", "0", "+CSDH=0");			# Show SMS text mode parameters
    &send_msg("+CSCS?", "\"8859-1\"","+CSCS=\"8859-1\"");	# Select char mode
    &send_msg("+CPIN?", "READY","+CPIN=\"$pin\"");		# Get PIN status ('+CPIN: SIM PUK' ?)
    &send_msg("+CSCA?", "\"$smsc\"", "\"$smsc\"");
}

# Send a message to the serial port
sub put_msg {
    my($msg) = @_;
    my($null, $string, $count_out);

    $count_out = $fd->write("AT$msg\r\n");
    warn "write failed\n" unless($count_out);
    warn "write incomplete\n" if( $count_out != length($msg)+4 );
    sleep($sleep);

    $null = &do_read();
    sleep($sleep);
}

# Send a message to the serial port, and if not ok, send the init string
# Options:
#	Check string
#	Expected value (after ': ' string)
#	Init string if not expected value exists
sub send_msg {
    my($msg, $chk, $init) = @_;
    my($count_out, $result, $code, $stat);

    if(! &check_status()) {
	print "No carrier!\n";
	exit(1);
    }

    $count_out = $fd->write("AT$msg\r\n");
    warn "write failed\n" unless($count_out);
    warn "write incomplete\n" if( $count_out != length($msg)+4 );
    sleep($sleep);

    ($result, $code) = &do_read();
    $result =~ s/.*: //;
    print "String (AT$msg):  '$result'/'$chk'/'$code'\n" if($dbg);

    if($result ne $chk) {
	print "Modify (AT$init): $chk / $result\n" if($dbg);

	$count_out = $fd->write("AT$init\r\n");
	warn "write failed\n" unless($count_out);
	warn "write incomplete\n" if( $count_out != length($init)+4 );
	sleep($sleep);
    }
}

# Send a SMS message
# Options:
#	Phone number to send to
#	Message string to send
sub send_sms {
    my($phone, $msg) = @_;
    my($count, $string, $gotit, $i, @msg);

    # Add PID to beginning of SMS string
    $msg = "$$: $msg" if($dbg);

    # Select SMS Format
    &send_msg("+CMGF?", "1","+CMGF=1");

    # Send phone number
    &do_send("AT+CMGS=\"$phone\"\r\n");	# Send the phonenumber

    # Get SMS input prompt ('> ')
    ($count, $string) = $fd->read(10);
    $string =~ s/^\r//; $string =~ s/^\n//;

    if($string =~ /^>/) {
	print "Sending: '$msg\\r\\n'\n";

	# Send SMS message
	@msg = split(//, $msg);
	for($i = 0; $msg[$i]; $i++) {
	    print "$msg[$i] (" if($dbg);
	    $count = $fd->write($msg[$i]);
	    print "$count)\n" if($dbg);
	}
	$fd->write("\r\n");
	sleep($sleep);

	# Send CTRL-z to end input
	$fd->write(sprintf("%s\n", chr(0x1A)));

	# Flush buffers
	# POSIX alternative to Win32 write_done(1)
	# set when software is finished transmitting
	$fd->write_drain;
    } else {
	print "Error, did not receive expected '> ' prompt!\n";
    }
}

sub do_read {
    my(@value, @val, $ret, $i);

    $ret = $fd->read(100);

    @value = split('\n', $ret);
    for($i=0;$value[$i];$i++) {
	next if($value[$i] =~ /^\r$/);
	$value[$i] =~ s/\r$//;
	push(@val, $value[$i]);
    }

    return(0) if($val[0] eq 'OK');
    return(@val);
}

sub do_send {
    my($string) = @_;
    my($count_out);

    $count_out = $fd->write($string);
    warn "write failed\n" unless($count_out);
    warn "write incomplete\n" if( $count_out != length($string) );
    sleep($sleep);
}

# Check status of modem
sub check_status {
    my($stat);

    $fd->write("AT\r\n");
    $stat = $fd->read(10);

    return(0) if(!$stat);
    return(1);
}

sub print_options {
    my @baud_opt = $fd->baudrate;
    my @parity_opt = $fd->parity;
    my @data_opt = $fd->databits;
    my @stop_opt = $fd->stopbits;
    my @hshake_opt = $fd->handshake;
    
    print "Available Options for port ttyS0\n";
    print "Data Bit Options:   ";
    foreach $a (@data_opt) { print "  $a"; }
    print "\nStop Bit Options:   ";
    foreach $a (@stop_opt) { print "  $a"; }
    print "\nHandshake Options:  ";
    foreach $a (@hshake_opt) { print "  $a"; }
    print "\nParity Options:     ";
    foreach $a (@parity_opt) { print "  $a"; }
    
    print "\nBinary Capabilities:\n";
    print "    can_baud\n"                  if (scalar $fd->can_baud);
    print "    can_databits\n"              if (scalar $fd->can_databits);
    print "    can_stopbits\n"              if (scalar $fd->can_stopbits);
    print "    can_dtrdsr\n"                if (scalar $fd->can_dtrdsr);
    print "    can_handshake\n"             if (scalar $fd->can_handshake);
    print "    can_parity_check\n"          if (scalar $fd->can_parity_check);
    print "    can_parity_config\n"         if (scalar $fd->can_parity_config);
    print "    can_parity_enable\n"         if (scalar $fd->can_parity_enable);
    print "    can_rlsd\n"                  if (scalar $fd->can_rlsd);
    print "    can_rtscts\n"                if (scalar $fd->can_rtscts);
    print "    can_xonxoff\n"               if (scalar $fd->can_xonxoff);
    print "    can_interval_timeout\n"      if (scalar $fd->can_interval_timeout);
    print "    can_total_timeout\n"         if (scalar $fd->can_total_timeout);
    print "    can_xon_char\n"              if (scalar $fd->can_xon_char);
    print "    can_spec_char\n"             if (scalar $fd->can_spec_char);
    print "    can_16bitmode\n"             if (scalar $fd->can_16bitmode);
    print "    is_rs232\n"                  if (scalar $fd->is_rs232);
    print "    is_modem\n"                  if (scalar $fd->is_modem);
    print "    binary\n"                    if (scalar $fd->binary);
    print "    parity_enable\n"             if (scalar $fd->parity_enable);

    print "\nCurrent Settings:\n";
    printf "    baud = %d\n", scalar $fd->baudrate;
    printf "    parity = %s\n", scalar $fd->parity;
    printf "    data = %d\n", scalar $fd->databits;
    printf "    stop = %d\n", scalar $fd->stopbits;
    printf "    hshake = %s\n", scalar $fd->handshake;
    
    print "\nOther Capabilities:\n";
    my ($in, $out) = $fd->buffer_max;
    printf "    input buffer max = 0x%x\n", $in;
    printf "    output buffer max = 0x%x\n", $out;
    ($in, $out)= $fd->buffers;
    print "    input buffer = $in\n";
    print "    output buffer = $out\n";
    printf "    alias = %s\n", $fd->alias;
}

# Open a connection to the SQL database...
sub init_sql_server {
    # Open up the database connection...
    my $dbh = DBI->connect("dbi:ODBC:VikingDB", "sa", '') or die "$DBI::errstr\n";

    if(! $dbh ) {
        printf(STDERR "Can't connect to database at DSN VikingDB." );
        return;
    }

    return($dbh);
}

sub print_usage {
    print "Usage: $0 [OPTION]\n";
    print "  Where OPTION could be:\n";
    print "    rst      Reset modem (send ATZ)\n";
    print "    chk      [not implemented]\n";
    print "    png      Check status of modem (send AT)\n";
    print "    dbg      Run in debug mode\n";
    print "    opt      Show serial and modem options\n";
    exit(0);
}

######################################################################
#
# $Log: sms_read.pl,v $
# Revision 1.1  2004-07-17 08:10:03  turbo
# Initial revision
#
# Revision 1.2  2001/08/20 11:50:16  turbo
# Updated the files with proper CVS entries such as Author, Log etc
#
