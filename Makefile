# The CVS log messages can be found at the bottom of the file...
#
# $Id: Makefile,v 1.1 2004-07-17 08:10:03 turbo Exp $

install: 
	@echo "Installing scripts";
	@cp daemon.pl /usr/local/sbin/sms_alarm_server.pl

	@if [ ! -f /etc/init.d/sas ]; then echo "Copying init script"; cp init.d /etc/init.d/sas; fi
	@if [ ! -f /etc/sas.config ]; then echo "Installing global config file"; cp sas.config /etc/; fi

######################################################################
#
# $Log: Makefile,v $
# Revision 1.1  2004-07-17 08:10:03  turbo
# Initial revision
#
