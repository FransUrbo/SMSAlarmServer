-- $Id: SAS-DefaultData.sql,v 1.1 2004-07-17 09:02:59 turbo Exp $

INSERT INTO vas_alarm_messages_status_codes VALUES(0, 'Alarm sent', '');
INSERT INTO vas_alarm_messages_status_codes VALUES(1, 'Alarm acknowledged', 'ack');
INSERT INTO vas_alarm_messages_status_codes VALUES(2, 'Alarm is being fixed', 'pend');
INSERT INTO vas_alarm_messages_status_codes VALUES(3, 'Alarm problem is fixed',	'fin');
INSERT INTO vas_alarm_messages_status_codes VALUES(4, 'Previous alarm have been', 'sent');

INSERT INTO cliconversions VALUES('+46', 0);

-- Initial data
SET TIME ZONE 'Europe/Stockholm';
SET DATESTYLE TO US;

INSERT INTO servertype VALUES( 1, 'VXIS - External Interface');
INSERT INTO servertype VALUES(20, 'VSUS - SMS UnitServer');
INSERT INTO servertype VALUES(30, 'VAS - Alarm Server');
INSERT INTO servertype VALUES(40, 'VDBS - Database Server');
INSERT INTO servertype VALUES(50, 'VCS - Content Server');
