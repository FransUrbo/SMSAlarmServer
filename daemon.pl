#!/usr/bin/perl -w 

######################################################################
# 
# This is the Viking Alarm Server software, using a PostgreSQL database
# via a unixODBC connection.
#
# The CVS log messages can be found at the bottom of the file...
#
# $Author: turbo $
# $Id: daemon.pl,v 1.1 2004-07-17 08:10:01 turbo Exp $

# TODO: Use db function getserverid() to get a new serverid if no config...
# TODO: Check if sending SMS and/or EMail

use DBI;
use DBI qw(:sql_types);
use Device::SerialPort 0.05;
use strict;
use English;

my($dbh, $fd, $quiet, $do_reset);
$quiet = 0; $do_reset = 1;

END {
    &exit_cleanly(0, 'Cancel process') if(!$quiet);
}

# Global variables. REALLY (!!) hate to have them, but...
my(%recipients, %CONFIG);

# Default values that really should be in the database..
my $delay_between_sms = 15;		# In minutes
my $delay_between_checks = 60;		# In seconds

$SIG{'USR1'} = 'usr1_handler';		# handle a SIGUSR1 by turning ON debugging
$SIG{'USR2'} = 'usr2_handler';		# handle a SIGUSR2 by turning OFF debugging
$SIG{'TERM'} = 'term_handler';		# handle a SIGTERM by exit cleanly
$SIG{'INT'}  = 'int_handler';		# handle a SIGINT  by exiting cleanly

# ====================================================================

my($arg, $dbg, $dbg_query, $dbg_sms, $dbg_nosms);
if($#ARGV >= 0) {
    foreach $arg (@ARGV) {
	if($arg eq 'dbg') {
	    # Do normal debugging
	    $dbg = 1;
	} elsif($arg eq 'db') {
	    # Debug the SQL queries
	    $dbg_query = 1;
	} elsif($arg eq 'sms') {
	    # Debug the SMS sending
	    $dbg_sms = 1;
	} elsif($arg eq 'nosms') {
	    # Don't do the acctuall sending of SMS'
	    $dbg_nosms = 1;
	} elsif($arg eq 'dbi') {
	    # Gives _A LOT_ of output! Be warned!!
	    DBI->trace(3);
	} elsif(($arg eq '?') || ($arg eq '-h') || ($arg eq '--help')) {
	    &print_usage();
	} elsif($arg eq 'opt') {
	    &print_options();
	    exit(0);
	}
    }
}


if(!$dbg) {
    # Close the basic file handlers...
    close(STDIN); close(STDOUT); close(STDERR);

    # This is a daemon, right?
    if(fork()) {
	exit 0;
    }
}

# The HUP hander takes care of reloading the startup initialization,
# so we just call that here instead of doing the same code twice...
print "================== doing main initialization.\n" if($dbg);
&hup_handler();

if($#ARGV >= 0) {
    foreach $arg (@ARGV) {
	if($arg eq 'rst') {
	    &do_write("Z", 1);
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
	}
    }
}

#        __________________
# ===== / M A I N  L O O P \ =====

my $date = `date` if($dbg);
print "\n================== doing main loop ===== $date" if($dbg);
for(;;) {
    my(@ERRORS, @ids, @messages);

    # Leave a heartbeat
    &sql_procedure('insertHeartbeat', $CONFIG{SERVERID});

    # Get server ID's
    @ids = &get_server_ids();

    # Let's read the messages in the modem, if any...
    @messages = &read_sms();

    # Process the read sms'es...
    &do_process_replies(@messages);

    # Make sure all alarm's that haven't been sent, is transfered!
    &do_send_old_alarms();

    # Check each server id and there status...
    @ERRORS = &do_check_server_status(@ids);

    # Check action table
    &do_check_actions($CONFIG{SERVERID});

    # TODO: Check connection to the webserver

    # Process the alarms, and send the SMS'
    &do_process_alarms(@ERRORS);

    # Wait here for the specified time period...
    my($i);
    print "================== Sleeping" if($dbg);
    for($i = 0; $i < $delay_between_checks; $i++ ) {
	print "." if($dbg);
	sleep(1);
    }
    print "\n";

    # Delete/Clear the variables used in the loop
    undef(@ids); undef(@messages); undef(@ERRORS);
}

# ===== \ M A I N  L O O P / =====
#        ------------------

# Open a connection to the SQL database...
sub init_sql_server {
    my($error, $recipid);

    # Open up the database connection...
    my $dbh = DBI->connect("dbi:ODBC:$CONFIG{'SQLSERVER'}",
			   $CONFIG{SQLSERVER_USER},
			   $CONFIG{SQLSERVER_PASSWD}
			   ) or die "$DBI::errstr\n";

    if(! $dbh ) {
	$error = "Can not connect to database server (on ODBC $CONFIG{'SQLSERVER'})";

	# Send a SMS to the user AND to the rest of the alarm recipients
	foreach $recipid (keys(%recipients)) {
	    my $phone = (split(/;/, $recipients{$recipid}))[2];
	    next if(! $phone);
	    
	    # TODO: Send SMS to 'Phone Number' as well, if not 'phonenumber != cellphone'.
	    printf("      $phone -> %s\n", $error);
	    
	    # Do the actual SMS sending via the modem
	    my $ret = &do_send_sms($phone, $error);
	    die "Could not send the SMS to the phone, $ret!\n" if($ret);
	}
	
        die("Can't connect to database at $CONFIG{'SQLSERVER'}, $DBI::errstr." );
    }

    print "* Initialized connection to SQL server.\n" if($dbg);
    return($dbh);
}

sub init_serial_port {
    my($dev) = @_;
    my($ob);

    $ob = Device::SerialPort->new($dev)
	|| die "Can't open $dev, $!\n";
    $ob->baudrate(19200)   || die "fail setting baudrate";
    $ob->databits(8);
    $ob->parity("none");
    $ob->stopbits(1);
    
    # Crappy, slow modem!
    $ob->read_char_time(3);             # Avg time between read char
    $ob->read_const_time(100);          # Milliseconds
    #$ob->write_char_time(5);           # Not supported
    #$ob->write_const_time(100);        # Not supported

    print "* Opened serialport $dev\n" if($dbg);
    
    return($ob);
}

sub init_gsm_card {
    my($sth, $ret, $query);

    print "* Getting SIM configuration:\n" if($dbg);

    # Get the card ID from the GSM card
    $ret = &send_msg("^SCID", "", "");
    print "  init_gsm_card(): '$ret'\n" if($dbg);

    # Get PIN/PUK/SMSC from db for this card
    $query = "SELECT pin,smscnumber FROM GSMModems WHERE cardid LIKE \'$ret\'";
    print "  -> $query\n" if($dbg_query);
    ($CONFIG{PINCODE}, $CONFIG{SMSC}) = &sql($query);
    die "PIN code and number to SMSC is needed!\n" if(!$CONFIG{PINCODE} || !$CONFIG{SMSC});

    print "  PIN: $CONFIG{PINCODE}, SMSC: $CONFIG{SMSC}\n" if($dbg);
}

sub init_modem {
    print "* Sending msg to modem:\n" if($dbg);

    # Don't show SMS text mode parameters
    &send_msg("+CSDH?", "0", "+CSDH=0");

    # Select char mode
    &send_msg("+CSCS?", "\"8859-1\"","+CSCS=\"8859-1\"") || die "Can't send AT+CSCS?\n";

    &send_pincode();

    # Set the SMS center number
    &send_msg("+CSCA?", "\"$CONFIG{SMSC}\"", "+CSCA=\"$CONFIG{SMSC}\"") || die "Can't send AT+CSCA?\n";
}

sub sql_procedure {
    my($procedure, @args) = @_;
    my($arg_string, $arg, $sth, $query);

    while($#args+1) {
	$arg_string .= "'$args[0]'";
	$arg_string .= ", " if($args[1]);
	shift(@args);
    }

    $query = "SELECT $procedure($arg_string)";
    print "  -> $query\n" if($dbg_query);
    
    $sth = $dbh->prepare($query);
    $sth->execute;

    return($sth->fetchrow);
}

sub get_alarm_recipients {
    my($sth, $i, @alarm, %RECEIVER);

    $sth = $dbh->prepare("SELECT * FROM vas_alarm_receivers");
    $sth->execute || die "Could not execute query: $sth->errstr";

    print "* Alarm receivers:\n" if($dbg);

    while(@alarm = $sth->fetchrow_array) {
	$RECEIVER{$alarm[0]} = "";

	for($i = 1; $i <= $#alarm; $i++) {
	    if(defined($alarm[$i])) {
		$RECEIVER{$alarm[0]} .= "$alarm[$i];";
	    } else {
		$RECEIVER{$alarm[0]} .= "0;";
	    }
	}
	$RECEIVER{$alarm[0]} =~ s/;$//;

	print "  $RECEIVER{$alarm[0]}\n" if($dbg);
    }

    die "=> At least one recipient is needed!" if(!%RECEIVER);
    return(%RECEIVER);
}

sub get_server_ids {
    my($sth, $numrows, @ID, $id);

    $sth = $dbh->prepare("SELECT srvServerId FROM Services ORDER BY srvServerId");
    $sth->execute || die "Could not execute query: $sth->errstr";

    print "* Server ID's: " if($dbg);
    while(($id) = $sth->fetchrow_array) {
	push(@ID, $id);
	printf("%4d ", $id) if($dbg);
    }
    print "\n" if($dbg);

    die "At least one server is needed!" if(!$ID[0]);
    return(@ID);
}

sub send_pincode {
    my($result);

    print "* Initializing SIM card:\n" if($dbg);

    $result = &send_msg("+CPIN?", "READY", "+CPIN=\"$CONFIG{PINCODE}\"");
    if($result eq "SIM PUK") {
	# TODO: Send PUK
	#$result = &send_msg("+CPIN?", "READY", "+CPIN=\"$CONFIG{PUKCODE}\"");
	print "PUK CODE IS NEEDED!!\n";
	exit(10);
    }
    print "  send_pincode(): $result\n" if($dbg);

    # It is recomended to wait 10 seconds before using 'SMS related commands' ???
    print "  Will sleep for 10 seconds per recomendations... " if($dbg);
    sleep(10) if(!$dbg); 
    print "done.\n" if($dbg);
}

# Send a message to the serial port, and if not ok, send the init string
# Options:
#	Check string
#	Expected value (after ': ' string)
#	Init string if not expected value exists
sub send_msg {
    my($msg, $chk, $init) = @_;
    my($count_out, $result, $code, $stat, $i);

    if(! &check_status()) {
	$do_reset = 0; # We _DONT_ want to reset the modem in the END{} func...
	die "send_msg(): No carrier!\n";
    }

    $count_out = &do_write($msg, 0);
    ($result, $code) = &do_read();
    if(!defined($result) || !defined($code)) {
	# Just to make sure...
	print "  No reply at command 'AT$msg', let's try again in 3 seconds... " if($dbg);

	sleep(3);

	$count_out = &do_write($msg, 0);
	($result, $code) = &do_read();

	print "done.\n" if($dbg);
    }
    print "  Reply from modem: exp($chk), got($result - $code)\r\n" if($dbg);

    # We'we tried twice, but no go... Darn!
    die "send_msg(): No reply from modem!\n" if(!defined($result));

    if($chk && $init) {
	sleep($CONFIG{ATDELAY});
		
	# Let's make sure we try at least three times to init the modem
	for($i = 0; $i <= 2; $i++) {
	    if($chk ne $result) {
		$count_out = &do_write($init, 0);
		($result, $code) = &do_read();

		if(!defined($result)) {
		    # Just to make sure...
		    print "  No reply at command 'AT$init', let's try again in 3 seconds... " if($dbg);

		    sleep(3);
		    
		    $count_out = &do_write($init, 0);
		    ($result, $code) = &do_read();

		    print "done.\n" if($dbg);
		}
		print "  Modify (AT$init): exp($chk), got($result - $code)\r\n" if($dbg);
	    } else {
		$i = 2; last;
	    }

	    if(!defined($result)) {
		# We'we tried twice, but no go... Darn!
		$do_reset = 0; # We _DONT_ want to reset the modem in the END{} func...
		die "send_msg(): No reply from modem!\n";
	    }
	}
    } else {
	$result =~ s/\"//g;
    }

    return($result);
}

# Send a SMS message
# Options:
#	Phone number to send to
#	Message string to send
sub send_sms {
    my($phone, $msg) = @_;
    my($date, $query, $sid, $ret, $pid, $header, @id);

    # Get the current timestamp
    $date = &get_date();

    # Extract the server id from the error message
    ($sid, $msg) = split(/;/, $msg);

    # Get a unique message identifier
    $pid = &get_pid();

    # Set up the 'header' to the message (add unique ident and date/time)
    $header = "$pid - $date\n";

    # Replace ':' with '.' in the date string
    $header =~ s/\:/\./g;

    # Add the message to the header
    $msg = "$header$msg";

    print LOG "SMS: $phone -> '$msg'\n" if(!$dbg);

    # Check if this message have been sent to this phone within the last X minutes
    @id = &check_timestamp_on_msg($date, $sid, 0, $phone, $msg);
    if($id[0]) {
	print "      This message (ids: @id) have been sent within the last X minutes!\n\n" if($dbg);
	return(0);
    }

    # Insert the error in the database
    &logg_alarm('insert', $sid, $pid, $date, $phone, $msg) || die "Could not insert logg message!\n"
	|| die "Could not insert alarm message into database!\n";
   
    # Do the actuall SMS sending via the modem
    $ret = &do_send_sms($phone, $msg);
    die "Could not send the SMS to the phone, $ret!\n" if($ret);

    # Insert the error in the database
    &logg_alarm('update', $sid, $pid, $date, $phone, $msg) || die "Could not insert logg message!\n"
	|| die "Could not update the alarm message!\n";
}

# Check the modem if we have any unread SMS messages...
sub read_sms {
    my($i, $count_out, $msg, $messages, @messages, @msg, @MSGS);

    print "* Checking SMS'es in the cellphone:\n" if($dbg);

    # Select SMS Format
    &send_msg("+CMGF?", "1","+CMGF=1") || die "Can't send AT+CMGF?\n";

    # List all (!?) SMS'es...
    $count_out = $fd->write("AT+CMGL=\"ALL\"\r\n");
    warn "write failed\n" unless($count_out);
    warn "write incomplete\n" if( $count_out != 15);
    sleep($CONFIG{ATDELAY});

    # Read SMS one by one into the buffer...
    $messages = "";
    while($msg = $fd->read(60+160)) {
	$messages .= $msg;
	sleep($CONFIG{ATDELAY});
    }

    @messages =  split('\n', $messages);
    for($i=0; $messages[$i]; $i++) {
	$messages[$i] =~ s/\r//;
	chomp($messages[$i]);			# Remove the ending newline
	
	$messages[$i] =~ s/.*: //;		# Remove the leading '+CMGL: '
	$messages[$i] =~ s/\"//g;		# Remove all " characters

	next if(!$messages[$i]);		# Remove empty lines
	next if($messages[$i] eq "OK");		# Remove the last 'OK' message

	# Save the header
	@msg = split('\,', $messages[$i]);

	# Get the next line, the actual message
	next if(! $messages[$i+1]);
	$i++; chomp($messages[$i]); $messages[$i] =~ s/\r//;
	push(@msg, $messages[$i]);

	push(@MSGS, @msg);
    }

    if($dbg) {
	print "  * Messages stored in modem:\n   No Status     Sender       Date     Time        Message\n";
	my($msg, $j);

	for($i = 0; $MSGS[$i]; $i++) {
	    print "  ";
	    printf("%3d ",   $MSGS[$i]); $i++;		# Msg number
	    printf("%-10s ", $MSGS[$i]); $i++;		# Msg status
	    printf("%-12s ", $MSGS[$i]); $i++;		# Msg sender
	    $i++; 					# Empty (?)
	    print "$MSGS[$i] "; $i++;			# Date
	    print "$MSGS[$i] "; $i++;			# Time
	    print "$MSGS[$i]\n";			# Message
	}

	print "  <none>\n" if(!$MSGS[0] && $dbg);
    }

    return(@MSGS);
}

sub delete_sms {
    my($smsid) = @_;
    my($j, $result, $code);

    for($j = 0; $j <= 2; $j++) {
	&do_write("+CMGD=$smsid", 0);
	sleep(1);
	
	($result, $code) = &do_read();
	next if($result != 1);
	$j = 2;
    }
}

# Insert the alarm information in the database
# RETURNS: 0 on success
#          1 on failiure
sub logg_alarm {
    my($action, $sid, $pid, $date, $phone, $msg) = @_;
    my($query);

    my $logmsg = (split('\n', $msg))[1];

    if($action =~ /insert/i) {
	# Insert this error in the database
	$query  = "INSERT INTO vas_alarm_messages(vasserverid, vasidentifier, ";
	$query .= "vastimestamp, vasattempts, vasphonenumber, vasmessage) ";
	$query .= "VALUES($sid, $pid, '$date', 0, '$phone', '$msg')";
	print "  -> $query\n" if($dbg_query);
	$dbh->do($query) || return(0);

	&make_report($logmsg) && return(0);
    } elsif($action =~ /update/i) {
	# Update success of the error
	$query  = "UPDATE vas_alarm_messages SET vassuccess = 't', vasfinalsendtime = '$date', vasattempts = vasattempts + 1, ";
	$query .= "vasstatus = 0 WHERE vastimestamp = '$date' AND vasphonenumber = '$phone' AND vasserverid = $sid";
	print "  -> $query\n\n" if($dbg_query);
	$dbh->do($query) || return(0);
    } elsif($action =~ /reply/i) {
	&make_report($logmsg) && return(0);
    } else {
	die "logg_alarm(): No such action!\n";
    }

    return(1);
}

# Send a message to the serial port
sub do_write {
    my($msg, $flush) = @_;
    my($count);

    print "  Writing msg to phone: 'AT$msg'\n" if($dbg_sms);
    $count = $fd->write("AT$msg\r\n");
    warn "write failed\n" unless($count);
    warn "write incomplete\n" if($count != length($msg)+4);

    sleep($CONFIG{ATDELAY});

    &do_read() if($flush);

    return($count);
}

sub do_read {
    my(@value, @val, $ret, $i);

    $ret = $fd->read(100);
#print "\nRet 1: $ret\n";
    $ret =~ s/\r\n//;
    $ret =~ s/.*: //;
#print "Ret 2: $ret\n";

    @value = split('\n', $ret);
    for($i=0;$value[$i];$i++) {
#print "Val 1: $value[$i]\n";
	next if($value[$i] =~ /^\r$/);
	$value[$i] =~ s/\r$//;
#print "Val 2: $value[$i]\n";

	push(@val, $value[$i]);
    }

    return(-1) if(!defined($val[0]));
    return((1,'OK')) if($val[0] eq 'OK');
    return(@val);
}

sub do_check_server_status {
    my(@ids) = @_;
    my($query, $msg, $result, $type, $name, $id, $ip, $i, @ERR, @aids);

    print "\n* Server results:\n" if($dbg);

    foreach $id (@ids) {
	($result) = &sql_procedure('wwwPollServerStatus', $id);
	printf("  %4d:\t", $id) if($dbg);
	if($result != 0) {                                    
	    # Unsuccessful ping!
	    print "NO CONTACT!\n";

	    # Get the server name...
	    $query  = "SELECT t1.styremark,t2.srvname FROM ServerType t1, Services t2 ";
	    $query .= "WHERE (srvserverid = $id) AND (t2.srvservertype = t1.styservertype)";
	    ($type, $name) = &sql($query);

	    # Set up the alarm message
	    $msg = "NO CONTACT WITH $type, SERVER ID: $id ($name).";

	    # TODO: Just to make sure that the MACHINE is/isn't dead, do a simple ping
#	    if(system("/bin/ping -c 2 $ip >/dev/null")) {
#		# Don't answer on ping
#	    } else {
#		# Got ping reply
#	    }

	    push(@ERR, "$id;$msg");
	} else {
	    print "Is alive...\n" if($dbg);

	    # Just make sure that there aren't any alarms pending in the database for this
	    # server. Someone might have forgot to clear it...
	    $query = "SELECT vasActionID FROM vas_alarm_messages WHERE vasServerID = $id";
	    @aids = &sql($query, 1);
	    if($#aids >= 0) {
		# We have to delete the old ones
		print "        Actions to remove: @aids\n";

		$query = "DELETE FROM vas_alarm_messages WHERE ";
		for($i = 0; $aids[$i]; $i++) {
		    $query .= "vasActionID = $aids[$i]";
		    $query .= " OR " if($aids[$i+1]);
		}
		print "  -> $query\n" if($dbg_query);
		$dbh->do($query) || die "Could not delete old, unvalid alarm(s)!\n";
	    }
	}
    }

    return(@ERR);
}

sub do_check_actions {
    my($sid) = @_;
    my($sth, $tid, $aid, $query);

    # Setup the query string...
    $query  = "SELECT atyTypeID,actActionID FROM Actions ";
    $query .= "WHERE actProcessed='f' AND srvServerID = $sid ";
    $query .= "ORDER BY actActionID";
    print "  -> $query\n" if($dbg_query);

    # Get all the non processed actions for this server id
    $sth = $dbh->prepare($query);
    $sth->execute || die "Could not execute query: $sth->errstr";

    while(($tid,$aid) = $sth->fetchrow_array) {
	# TODO: Do something with the action!
	# TODO: Can't do  a recursive execute!

	# Set the processed flagg for this action to 'done'...
	$query  = "UPDATE Actions SET actProcessed = 't' ";
	$query .= "WHERE atyTypeID = $tid AND actActionID = $aid";
	print "  -> $query\n" if($dbg_query);
	
	#$sth = $dbh->prepare($query);
	#$sth->execute || die "Could not execute query: $sth->errstr";
    }
}

# Send alarms that have not successfully been sent (vassuccess = 'f')
sub do_send_old_alarms {
    my($sth, $aid, $sid, $stat, $phone, $msg, $query, $ret, $date, $attempts, @id);

    # Get the current timestamp
    $date = &get_date();

    print "\n* Sending old SMS alarms:\n" if($dbg);
    print "  Date: $date\n    ActID SrvID Attempts Stat Phone number              Error message\n" if($dbg);

    # Get all old and unsent alarms
    $query  = "SELECT vasactionid, vasserverid, vasstatus, vasattempts, vasphonenumber, vasmessage ";
    $query .= "FROM vas_alarm_messages WHERE vassuccess = 'f'";
    print "  -> $query\n" if($dbg_query);
    $sth = $dbh->prepare($query);
    $sth->execute || die "Could not execute query: $sth->errstr";

    while(($aid, $sid, $stat, $attempts, $phone, $msg) = $sth->fetchrow_array) {
	printf("  => %4d %5d %8d %4d %-25s $msg\n", $aid, $sid, $attempts, $stat, $phone);

	# Check if this message have been sent to this phone within the last X minutes
	@id = &check_timestamp_on_msg($date, $sid, $stat, $phone, $msg);
	if($id[0]) {
	    print "      This message (ids: @id) have been sent in the last X minutes!\n\n" if($dbg);
	    return(0);
	}

	# Do the actual SMS sending via the modem
	$ret = &do_send_sms($phone, "(OLD MSG): $msg");
	die "Could not send the SMS to the phone, $ret!\n" if($ret);

	# If we end up here, everything should be ok
	$query  = "UPDATE vas_alarm_messages SET vassuccess = 't', vasfinalsendtime = '$date', vasattempts = vasattempts + 1, ";
	$query .= "vasstatus = 4 WHERE vasactionid = $aid";
	print "  -> $query\n" if($dbg_query);
	$ret = $dbh->do($query) || die "Could not insert into vas_alarm_messages!\n";
    }

    print "  <none>\n" if(!$ret && $dbg);
}

sub do_send_sms {
    my($phone, $msg) = @_;
    my($count, $string, $len, @msg, $i, $ret);

    return(0) if($dbg_nosms);

    # Select SMS Format
    &send_msg("+CMGF?", "1","+CMGF=1") || die "Can't send AT+CMGF?\n";

    # Send phone number
    &do_write("+CMGS=\"$phone\"", 0);	# Send the phonenumber

    # Get SMS input prompt ('> ')
    ($count, $string) = $fd->read(100);
    $string =~ s/^.*\n//;
    print "  String: '$string'\n" if($dbg_sms); print "\n" if($dbg);
    die "Error, did not receive expected '> ' prompt!\n" if($string !~ /^>/);

    # Send SMS message
    print " Sending: '$msg\\r\\n'\n" if($dbg_sms);
    $len = length($msg);
    @msg = split(//, $msg);
    for($i = 0; $i < $len; $i++) {
	print " $msg[$i] (" if($dbg_sms);
	$count = $fd->write($msg[$i]);
	print "$count)\n" if($dbg_sms);
    }
    $fd->write("\r\n");
    sleep($CONFIG{ATDELAY});
    
    # Send CTRL-z to end input
    $fd->write(sprintf("%s\n", chr(0x1A)));

    # Flush buffers
    # POSIX alternative to Win32 write_done(1)
    # set when software is finished transmitting
    $fd->write_drain;
    &do_write("Z", 1);

    # Wait 1 second before returning, to make sure the modem don't 'bugg out'...
    sleep(1);

    return(0);
}

# Process the read sms'es...
sub do_process_replies {
    my(@msgs) = @_;
    my($i, $j, $ident, $sender, $msg, $sth, $query, $aid, $sid, $result, $code);
    my($smsid, $recipid, $alevel, $status, $do_next, $do_sendsms, $message, @tmp, @CONV);
    my($do_delete);

    $do_delete = 1; # The message in the phone should be deleted. We change it below if not
    print "  * Processing SMS replies:\n   No Ident Sender       Status\n" if($dbg);

    # Get the CLI conversion table
    $sth = $dbh->prepare("SELECT * FROM CLIConversions");
    $sth->execute || die "Could not execute query: $sth->errstr";
    while(@tmp = $sth->fetchrow_array) {
	$tmp[0] =~ s/^\+/\\\+/;	# Ugly hack so that replace works below!
	push(@CONV, @tmp);
    }

    for($i = 0; $msgs[$i]; $i++) {
	# Extract the intressting information
	$smsid  = $msgs[$i]; $i += 2;
	$sender = $msgs[$i]; $i += 4;
	($ident, $msg) = split(/ /, lc($msgs[$i]));

	if(($sender !~ /^\+/) || ($sender !~ /^[1-9]/)) {
	    # Let's skip all messages from non GSM phones (not starting with '+' or '0')
	    $message = "Unknown message in phone: $msgs[$i]";

	    my $date = &get_date();

	    # Insert into database
	    &make_report($message) && return(0);

	    $do_delete = 1;
	} elsif($ident =~ /help/i) {
	    # Get the avilible action commands 
	    $query = "SELECT vasShort FROM vas_alarm_messages_status_codes WHERE vasShort <> ''";
	    print "  -> $query\n" if($dbg_query);
	    @tmp = &sql($query, 1);

	    # Send out a help message to the sender
	    $message  = "Reply with the identity number, a space and one action command. ";
	    $message .= "The following commands are availible: @tmp";
	    my $ret = &do_send_sms($sender, $message);
	    die "Could not send the SMS to the phone, $ret!\n" if($ret);

	    $do_delete = 1;
	} else {
	    # ---------------------------------------
	    
	    # Do the CLI conversion (for example, replace '+46' with '0')
	    for($j = 0; $CONV[$j]; $j++) {
		if($sender !~ /^$CONV[$j]/) {
		    $j++; next;
		}
		$sender =~ s/^$CONV[$j]/$CONV[$j+1]/;
	    }
	    
	    # ---------------------------------------
	    
	    # Find out if this user have access to update the database with the specified message
	    $query  = "SELECT AccessLevel,vasStatus FROM vas_alarm_receivers, vas_alarm_messages_status_codes ";
	    $query .= "WHERE (Phone = '$sender' OR CellPhone = '$sender') AND vasShort = '$msg'";
	    print "  -> $query\n" if($dbg_query);
	    ($alevel, $status) = &sql($query);
	    
	    # ---------------------------------------
	    
	    # Take the next SMS if:
	    #	The sender don't exist in AlarmReceivers
	    #	The user don't have access to this command	
	    #	There is no such command
	    if(!$status) {
		printf("  %3d Not processing (no such status command)!\n", $smsid) if($dbg);
		$message = "There is no such command $msg!";
		$do_next = 1; $do_sendsms = 1; $do_delete = 0; goto CONT;
	    }
	    if(!$alevel) {
		printf("  %3d Not processing (no such user)!\n", $smsid) if($dbg);
		$message = "You do not have access to the command $msg!";
		$do_next = 1; $do_sendsms = 1; $do_delete = 0; goto CONT;
	    }
	    if($status > $alevel) {
		printf("  %3d Not processing (no access)!\n", $smsid) if($dbg);
		$message = "Unauthorized use of command '$msg' by '$sender'!";
		$do_next = 1; $do_sendsms = 1; $do_delete = 0; goto CONT;
	    }
	    
	    # ---------------------------------------
	    
	  CONT:
	    # Should we answer the reply?
	    if($do_sendsms) {
		# Insert into database
		&make_report($message) && return(0);

		printf("      $sender -> %s\n", $message);
		
		# Send an SMS to the person sending this message
		my $ret = &do_send_sms($sender, $message);
		die "Could not send the SMS to the phone, $ret!\n" if($ret);
	    }
	    
	    next if($do_next);

	    # ---------------------------------------
	    
	    # Get the alarm id with this identifier number sent to the one sending the reply
	    # 'There can only one!'... Hmm, wonder...
	    $query  = "SELECT vasActionID,vasServerID FROM vas_alarm_messages ";
	    $query .= "WHERE vasidentifier = $ident AND vasphonenumber = '$sender'";
	    print "  -> $query\n" if($dbg_query);
	    ($aid,$sid) = &sql($query);
	    next if(!$aid);	# Just incase the alarm isn't present in the db...
	    
	    printf("  %3d %5d %-12s $status\t", $smsid, $ident, $sender) if($dbg);
	    
	    # ---------------------------------------
	    
	    # Logg this reply into the database
	    &logg_alarm('reply', $sid, $ident, &get_date(), $sender, $msg);
	    
	    # Update the status field in the database for this alarm
	    if($msg =~ /fin/i) {
		# It's finnished. Remove the alarm from the database...
		$query = "DELETE FROM vas_alarm_messages WHERE vasactionid = $aid";
		$dbh->do($query) || die "Could not delete alarm!\n";
		print "=> The alarm ID $aid is finished in db.\n";
	    } else {
		# It's either ack or pend...
		$query  = "UPDATE vas_alarm_messages SET vasStatus = $status, vasfixedby = '$sender' WHERE vasactionid = $aid";
		print "  -> $query\n" if($dbg_query);
		$dbh->do($query) || die "Could not update alarm status!\n";
		print "=> The alarm ID $aid is pending/ack'ed in db.\n";
	    }

	    print "  <none>\n" if(!$msgs[0] && $dbg);
	}
	
	if($do_delete) {
	    # Delete this message from the phone
	    &delete_sms($smsid);
	    print "   Deleted SMS $smsid from the GSM modem.\n" if($dbg);
	}
    }
}

sub do_process_alarms {
    my(@errors) = @_;
    my($error, $id);

    # Go through the errors, and send SMS
    if($dbg) {
	print "\n* Alarm recipients:\n  Stat Full name             Phone number    Cell phone\n";
	foreach $id (keys(%recipients)) {
	    my @users = split(/;/, $recipients{$id});
	    $users[2] = '000' if(!$users[2]);
	    $users[3] = '000' if(!$users[3]);
	    printf("  %d    %-20s\t$users[1]\t$users[2]\n", $users[3], $users[0]);
	}
	
	print "\n* SMS to send:\n    Srv    Phone number   Error message\n";
    }
    
    foreach $error (@errors) {
	foreach $id (keys(%recipients)) {
	    my $phone = (split(/;/, $recipients{$id}))[2];
	    
	    # TODO: Send SMS to 'Phone Number' as well, if not 'phonenumber != cellphone'.
	    print  "  --------------\n" if($dbg_query);
	    printf("  %5d => $phone     %s\n", (split(/;/, $error))[0], (split(/;/, $error))[1]);
	    &send_sms($phone, $error);
	}
    }
}

######################################################################
# @oldsms = check_timestamp_on_msg
# Returns an array with the old SMS'es (there ActionID from vas_alarm_messages)
# 	OR: 0 if no old alarms
#
# A hit on an alarm will assume that:
#	The alarm have successfully been sent
#	AND
#	The alarm is for the requested phone number
#	AND
#	The alarm is for the requested server id
#	AND
#		The alarm have been sent within the last 15 minutes
#		OR
#		The alarm have not been replied to (w/ ack/pend/fin)
sub check_timestamp_on_msg {
    my($date, $sid, $status, $phone, $msg) = @_;
    my($sth, $query, $time, $aid, $timestamp, $attempts, $stat, $epoch, %IDS, @IDS);

    print "      * Checking timestamps:\n" if($dbg);

    # Get the current timestamp in EPOCH and calculate -X minutes
    ($time) = &sql("SELECT EXTRACT(EPOCH FROM now()) - ($delay_between_sms * 60)");

    # Get all the action id and number of attempts for this server to this phone.
    $query  = "SELECT vasactionid,vastimestamp FROM vas_alarm_messages ";
    $query .= "WHERE (vassuccess = 't') AND (vasphonenumber = '$phone') AND (vasserverid = $sid) ";
    $query .= "ORDER BY vastimestamp";
    print "      -> $query\n" if($dbg_query);
    $sth = $dbh->prepare($query);
    $sth->execute || die "Could not execute query: $sth->errstr";

    # TODO: Go through all the alarms, split them up in older than X minutes, and newer than X minutes
    print "        ID Attempts Stat DB timestamp\n" if($dbg);
    while(($aid, $timestamp) = $sth->fetchrow_array) {
	if($IDS{$aid}) {
	    print "hmmmm\n";
	}
	$IDS{$aid} = $timestamp;
    }

    foreach $aid (keys(%IDS)) {
	# Convert the timestamp to EPOCH
	$query = "SELECT EXTRACT(EPOCH FROM TIMESTAMP '$IDS{$aid}')";
	print "      -> $query\n" if($dbg_query);
	($timestamp) = &sql($query);

	if($timestamp > $time) {
	    push(@IDS, $aid);
	} else {
	    print "       Deleting alarm id: $aid\n" if($dbg);
	    $query = "DELETE FROM vas_alarm_messages WHERE vasactionid = $aid";
	    print "      -> $query\n" if($dbg_query);
	    $sth = $dbh->do($query) || return(-1);
	}
    }

    if($#IDS >= 0) {
	return(@IDS);
    } else {
	return(0);
    }
}

######################################################################
# $date = get_date()
# Returns a string something like: '2001-08-07 14:32:25'
sub get_date {
    # We need it from the database, so that it don't matter if the times don't match
    return(&sql("SELECT now()"));
}

sub get_pid {
    my($salt);
    srand();

    $salt = rand(100000);
    $salt = (split('\.', $salt))[0];

    return($salt);
}

sub readconfig {
    my($configfile) = @_;
    my($tmp, $name, $var, $i);

    open(CF, $configfile) || return(0);
    print "* Reading configuration file $configfile\n" if($dbg);
    while(! eof(CF)) {
        $tmp = <CF>;
        chop($tmp);

        # Skip comments and empty lines...
        next if( $tmp =~ /^\#/ );
        next if( $tmp =~ /^$/ );

        ($name,$var)=split(/=/, $tmp);

        $var = 'yes' if( $var eq 'true' );
        $var = 'no'  if( $var eq 'false' );

        printf("  %-24s = %s\n", $name, $var) if($dbg);
        $CONFIG{$name} = $var;

	$i++;
    }

    return(0) if(!$i);

    close(CF);
    return(1);
}

sub get_defaults {
    my($query, $fqdn, $sid);

    print "Getting defaults...\n";
    if(!$CONFIG{'SERVERID'}) {
	# Get a new server ID...

	# Find out the FQDN
	$fqdn  = `hostname`; chomp($fqdn); $fqdn .= "."; $fqdn .= `dnsdomainname`; chomp($fqdn);

	# Find the next availible server id
	($sid) = &sql("SELECT max(srvserverid)+1 FROM Services");

	# Insert the new server id
	$query  = "INSERT INTO Services VALUES($sid, now(), 'ALARM - $fqdn', ";
	$query .= "30";
	$query .= ", 4, '/var/log', 100, 'Master alarm server', 60, 120, 5, 10)";
	print "  -> $query\n" if($dbg_query);
	$dbh->do($query) || die "Could not insert into Services!\n";
    }

    # Save the new configuration...
    if( open(CF, "> /etc/vas-local.config") ) {
	print CF <<EOF;
SERVERID=$sid
EOF
    ;
	close(CF);
    } else {
	# Oups! Remove from the database!
	$dbh->do("DELETE FROM Services where srvServerID = $sid") ||
	    die "Could not insert into Services!\n";
	
	die "Can't write configuration file, $!\n";
    }
}

# Check status of modem
sub check_status {
    my($stat, $i);

    for($i = 0; $i <= 2; $i++) {
	$fd->write("AT\r\n");
	$stat = $fd->read(10);

	if(!$stat) {
	    # Just to make sure...
	    print "  $i. No contact with modem, let's try again in 3 seconds... " if($dbg);
	    
	    sleep(3);

	    $fd->write("AT\r\n");
	    $stat = $fd->read(10);

	    print "done.\n" if($dbg);
	} else {
	    $i = 2; last;
	}
    }

    return(0) if(!$stat);
    return(1);
}

sub sql {
    my($query, $multiple) = @_;
    my($sth, $col, @COLS);

    $sth = $dbh->prepare($query);
    $sth->execute || die "Could not execute query: $sth->errstr";

    if($query !~ /^insert/i) {
	if($multiple) {
	    while($col = $sth->fetchrow) {
		push(@COLS, $col);
	    }
	    return(@COLS);
	} else {
	    return($sth->fetchrow_array);
	}
    }

    if($sth->err) {
	return($sth->err);
    } else {
	return(0);
    }
}

sub make_report {
    my($msg) = @_;

    # Write to the ReportTable that we're starting up
    print "  Writing to ReportTable: '$msg'\n" if($dbg);
    return(&sql_procedure('makereport', $CONFIG{SERVERID}, 1, $msg));
}

######################################################################
# proc: hup_handler()
# handle a SIGHUP by reloading the configuration file...
sub hup_handler {
    my($flatfile, $query);

    # Load GLOBAL configuration
    &readconfig("/etc/vas-global.config");

    # Load LOCAL configuration
    &get_defaults() if(! &readconfig("/etc/vas-local.config"));

    # Initialize connection to SQL server
    $dbh = &init_sql_server();

    # --------------------------------------------------------------------

    # Write to the ReportTable that we're starting up
    &make_report("Starting up.") && die "Can't write to ReportTable, exit!\n";

    # announce our precence to the world
    open(PID, "> /var/run/vas.pid")
	|| die("Could not open the pid file, $!\n");
    print PID $$ . "\n";
    close PID;
    
    # Get the path to the flatfile
    $query = "SELECT srvFlatFile FROM Services WHERE srvServerID = $CONFIG{SERVERID}";
    print "  -> $query\n" if($dbg_query);
    ($flatfile) = &sql($query);
    $flatfile .= "/" if($flatfile !~ /\/$/);
    $flatfile .= "flatfile.$CONFIG{SERVERID}";

    # Open the flatfile, and log (if not debugging)
    open(LOG, ">> $flatfile") || die "Can't open flatfile '$flatfile', $!\n";
    select(LOG) if(!$dbg);
    $| = 1;  # flush the WRITEHANDLE after each command.

    # Change the name we are running as...
    $PROGRAM_NAME  = "VAS";

    # --------------------------------------------------------------------

    # Get recipients
    %recipients = &get_alarm_recipients();

    # Initialize connection to the seril port
    $fd = &init_serial_port($CONFIG{'SERIALPORT'});

    # Local echo off
    &do_write("E0", 1);

    # Get modem configuration
    &init_gsm_card();

    # Initialize modem conection
    &init_modem();

    $SIG{'HUP'} = 'hup_handler'; # restore handler
}

######################################################################
# proc: usr1_handler()
# handle a SIGUSR1 by turning ON debugging
sub usr1_handler {
    $dbg_query = 1 if($dbg);
    $dbg = 1;
}

######################################################################
# proc: usr2_handler()
# handle a SIGUSR2 by turning OFF debugging
sub usr2_handler {
    $dbg = 0; $dbg_query = 0;
}

######################################################################
# proc: term_handler()
# handle a SIGTERM by exit cleanly
sub term_handler {
    &exit_cleanly(0, 'Caught SIGTERM');
}

######################################################################
# proc: int_handler()
# handle a SIGINT (Ctrl-C) by exiting cleanly
sub int_handler {
    &exit_cleanly(0, 'Caught SIGINT (or Ctrl-C)');
}

sub exit_cleanly {
    my($code, $msg) = @_;
    my($query);
    $quiet = 1;

    my $date = `date`; chomp($date);

    if($do_reset) {
	print "Resetting modem... \n";

	# Set Local echo on, so that we don't need to do that
	# manualy every time we startup a term to it...
	&do_write("E1", 1);

	# TODO: Send ESC instead of Ctrl-z
	# Send CTRL-z to the modem to end input
	#$fd->write(sprintf("%s\n", chr(0x1A)));
	
	# Flush serial port buffers
	$fd->write_drain;
    }

    # Disconnect the serial port
    undef $fd;

    # ---------------

    # Write to the ReportTable that we're quitting
    &make_report("Exiting: $msg.");

    # Disconnect from the SQL server
    $dbh->disconnect();

    # ---------------

    # Print date of exit...
    print "\n$msg on date: $date. Exiting.\n";

    exit($code);
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

sub print_usage {
    print "Usage: $0 [OPTION]\n";
    print "  Where OPTION could be:\n";
    print "    dbg      Run in debug mode\n";
    print "    sms      Debug the SMS sending\n";
    print "    nosms    Don't do the actuall sending of SMS'\n";
    print "    rst      Reset modem (send ATZ)\n";
    print "    png      Check status of modem (send AT)\n";
    print "    opt      Show serial and modem options\n";

    exit(0);
}

######################################################################
#
# $Log: daemon.pl,v $
# Revision 1.1  2004-07-17 08:10:01  turbo
# Initial revision
#
# Revision 1.19  2001/08/28 06:36:44  turbo
# Incase of empty column in vas_alarm_receivers, exchange with value '0'...
#
# Revision 1.18  2001/08/28 06:20:12  turbo
# * Removed all references to the table vas_alarm_messages_log (also deleted that
#   table from the database). We now use the correct and existing table for logging,
#   the 'ReportTable'.
#   The function make_report() calls sql_procedure() which in turn calls the stored
#   procedure makereport().
# * Logg starting and stopping (w/ reasons) to the ReportTable.
#
# Revision 1.17  2001/08/24 06:02:17  turbo
# * Correcting spelling error of logoutput
#
# Revision 1.16  2001/08/24 05:59:47  turbo
# * When a faulty alarm reply is found, we don't broadcast. Instead we send directly
#   (and only) to the user sending the reply
# * Turn on local echo when exit cleanly
#
# Revision 1.15  2001/08/24 05:12:47  turbo
# * Let's skip all messages from non GSM phones (not starting with '+' or '0')
# * If there is a access violation, wrong message command etc, don't broadcast
#   an SMS. Insert the error into the database, labeled with the VAS server id.
#
# Revision 1.14  2001/08/23 11:02:27  turbo
# Make sure we retry initialization of the modem three times before dying
#
# Revision 1.13  2001/08/23 08:53:58  turbo
# If it can't find the modem, or we don't get a carrier, it shouldn't try
# to reset the modem in the END{} func...
#
# Revision 1.12  2001/08/23 08:42:21  turbo
# Implemented a requested feature from Jonas. A 'Help' command.
#
# Revision 1.11  2001/08/23 06:20:35  turbo
# * Set the program name variable to VAS, so we don't have an
#   ugly command line string. Looks cleaner...
# * Flush an reset the modem when exiting
# * Variable delay between checks is no in minutes, not seconds.
# * Add a SIGTERM and SIGINT handler so that we can exit cleanly.
#   Calls the function exit_cleanly(), that prints out date and
#   time of program ending.
# * It's now possible to debug without sending the SMS. Command
#   line parameter: nosms
# * Output date and time for each main loop entrance...
# * If we don't have a cellphone (it's "0"), then don't send
#   alarm. This is so that one can temporary disable an alarm
#   receiver, without deleting the 'account'.
# * If a machine is alive, we double check to see if there are any
#   old, undeleted alarms in the database for this server. This is
#   to make sure an alarm don't go out, just because the admin have
#   forgot to clear the alarm in the database.
# * check_timestamp_on_msg()
#   - When getting the timestamp for the message, we ignore the
#     vasAttempts column. It wasn't used anyway.
#   - We ignore the 'older than 15 minutes' timestamp. We do this
#     check in software instead. This so that we can delete messages
#     older than 15 minutes. We only want the current alarms in
#     the database!
# * Extended the sql() function to either return datasets (only from
#   one column) or single value.
#
# Revision 1.10  2001/08/21 14:07:58  turbo
# Make absolutly sure that the message in the modem is lower case'd
#
# Revision 1.9  2001/08/21 14:01:28  turbo
# Fixing typ from last commit.
#
# Revision 1.8  2001/08/21 14:00:12  turbo
# If we can't connect to the database, send SMS to all alarm receivers, and
# die (HARD!).
#
# Revision 1.7  2001/08/21 13:57:21  turbo
# * Prepare for daemon mode (close fh 0-2). Only if ! debugging
# * Get the flatfile path from DB
# * Open flatfile (and 'select()' if ! debugging)
#
# Revision 1.6  2001/08/21 13:20:10  turbo
# * The hard coded delay between checks is 60...
# * Do the heartbeat first, THEN do checks etc.
# * Do sleep between checks even if debugging.
#
# Revision 1.5  2001/08/21 12:12:24  turbo
# * Some smaller changes in the debug output.
# * Don't send double '\r\n' when sending the AT+CMGS command
#   (it was done both when calling the function do_write() as well
#   IN the function!).
# * Removed some finished TODO's
# * Remove the filtering of phonenumber. Now we send to ALL configured
#   alarm receivers! Heee! :)
# * Catch empty values in the vas_alarm_receivers table (less complaining
#   from perl when running with '-w').
#
# Revision 1.4  2001/08/21 11:20:49  turbo
# * Don't sleep(?) if debug, exit(0) instead
# * Send SMS to all recipients if no such status command, unauthorized reply
#   and/or no access
#
# Revision 1.3  2001/08/21 04:31:42  turbo
# * Don't shift ARGV, it's 'shifted' in the foreach loop!
# * Changed name of the table AlarmReceivers to vas_alarm_receivers
# * Do the CLI conversion _before_ getting the AccessLevel+vasStatus
#   from the database
#
# Revision 1.2  2001/08/20 11:50:16  turbo
# Updated the files with proper CVS entries such as Author, Log etc
#
