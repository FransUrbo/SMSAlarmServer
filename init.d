#!/bin/sh
#
# sas           This shell script takes care of starting and stopping
#               the SMS Alarm Server.
#
# $Id: init.d,v 1.1 2004-07-17 08:10:03 turbo Exp $

if [ -f "/etc/sas.config" ]; then
    . /etc/sas.config
else
    PIDFILE=/var/run/sas.pid
fi

# See how we were called.
case "$1" in
  start)
	# Start daemons.
	echo -n "Starting the SMS Alarm Server: "
	/usr/local/sbin/sas.pl
	echo
	;;
  stop)
	# Stop daemons.
	echo -n "Shutting down the SMS Alarm Server: "
	kill `cat $PIDFILE`
	echo
	;;
  restart)
	echo -n "Restarting SMS Alarm Server: "
	kill `cat $PIDFILE`
	/usr/local/sbin/sas.pl
	echo
	;;
  *)
	echo "Usage: $0 {start|stop|restart}"
	exit 1
esac

exit 0
