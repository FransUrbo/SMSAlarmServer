-- The CVS log messages can be found at the bottom!
-- $Author: turbo $
-- $Id: SAS-Schema.pgsql,v 1.1 2004-07-17 09:02:59 turbo Exp $
--
\connect - postgres

CREATE USER "%SQLSERVER_USER%";			-- Alarm/Admin user

\connect - %SQLSERVER_USER%

------------------------------------------------------------------------------------
-- OLD CRAP!!!
---
CREATE SEQUENCE seq_alarm_messages_status_codes		INCREMENT 1 START 1;

---
CREATE TABLE "vas_alarm_messages_status_codes" (
	"vasstatus" integer default nextval('seq_alarm_messages_status_codes') PRIMARY KEY UNIQUE,
	"vasremark" character varying(50),
	"vasshort"  character varying(5)
);
REVOKE ALL on "vas_alarm_messages_status_codes" from PUBLIC;
GRANT ALL on "vas_alarm_messages_status_codes" to "%SQLSERVER_USER%";
SELECT setval ('"seq_alarm_messages_status_codes"', 1, 'f');

---
CREATE TABLE "vas_alarm_receivers" (
	"alarmreceiverid" integer PRIMARY KEY UNIQUE,
	"name" character varying(50),
	"phone" character varying(25),
	"cellphone" character varying(25),
	"accesslevel" integer
);
REVOKE ALL on "vas_alarm_receivers" from PUBLIC;
GRANT ALL on "vas_alarm_receivers" to "%SQLSERVER_USER%";

---
CREATE TABLE "cliconversions" (
	"cfrom" character varying(10) PRIMARY KEY UNIQUE,
	"cto" character varying(10)
);
REVOKE ALL on "cliconversions" from PUBLIC;
GRANT ALL on "cliconversions" to "%SQLSERVER_USER%";
CREATE INDEX cliconversions_to_idx on cliconversions(cto);

-- END: OLD CRAP!!!
------------------------------------------------------------------------------------

CREATE FUNCTION "plpgsql_call_handler" () RETURNS opaque AS '/usr/lib/pgsql/plpgsql.so', 'plpgsql_call_handler' LANGUAGE 'C';
CREATE TRUSTED PROCEDURAL LANGUAGE 'plpgsql' HANDLER "plpgsql_call_handler" LANCOMPILER 'PL/pgSQL';

-- Sequences...
CREATE SEQUENCE seq_actions				INCREMENT 1 START 1;

CREATE SEQUENCE seq_alarm_messages			INCREMENT 1 START 1;

CREATE SEQUENCE seq_alarm_failures                      INCREMENT 1 START 1;

CREATE SEQUENCE seq_alarm_messages_log			INCREMENT 1 START 1;

CREATE SEQUENCE seq_conversions				INCREMENT 1 START 1;

CREATE SEQUENCE seq_smsc_conversions			INCREMENT 1 START 1;

CREATE SEQUENCE seq_firmwares_data			INCREMENT 1 START 1;

CREATE SEQUENCE seq_groups_data				INCREMENT 1 START 1;

CREATE SEQUENCE seq_groups_ranges			INCREMENT 1 START 1;

CREATE SEQUENCE seq_reporttable				INCREMENT 1 START 1;

CREATE SEQUENCE seq_services				INCREMENT 1 START 1;


CREATE SEQUENCE seq_smsc_exclusiontable			INCREMENT 1 START 1;

CREATE SEQUENCE seq_smslocal				INCREMENT 1 START 1;

CREATE SEQUENCE seq_smsremote				INCREMENT 1 START 1;

CREATE SEQUENCE seq_wwwlogin				INCREMENT 1 START 1;

CREATE SEQUENCE seq_clitobounce             INCREMENT 1 START 1;

CREATE SEQUENCE seq_vcs_protected_sms		INCREMENT 1 START 1;

-- Tables...
CREATE TABLE "actions" (
	"actactionid" integer PRIMARY KEY NOT NULL UNIQUE,
	"srvserverid" integer NOT NULL,
	"acttimestamp" datetime NOT NULL,
	"atytypeid" integer NOT NULL,
	"actprocessed" boolean default false
);
REVOKE ALL on "actions" from PUBLIC;
GRANT ALL on "actions" to "%SQLSERVER_USER%";
CREATE INDEX actions_srvserverid_idx on actions(srvserverid);

--
CREATE TABLE "gsmmodems" (
	"modemid" integer,
	"comport" integer,
	"pin" integer,
	"puk" integer,
	"smscnumber" character varying(20),
	"modemnumber" character varying(20),
	"imei" character varying(20),
	"cardid" character varying(20)
);
REVOKE ALL on "gsmmodems" from PUBLIC;
GRANT ALL on "gsmmodems" to "%SQLSERVER_USER%";

--
CREATE TABLE "log" (
	"serialnumber" character varying(15),
	"cli" character varying(26),
	"dialinreason" integer,
	"statuscode" integer,
	"reasoncode" integer,
	"starttime" timestamp with time zone,
	"stoptime" timestamp with time zone,
	"rowid" integer,
	"confid" integer,
	"checksum" integer,
	"messagesreceived" integer,
	"messagessent" integer,
	"serverid" integer,
	"channel" integer,
	FOREIGN KEY(statuscode) REFERENCES statuscodes(statuscode),
	FOREIGN KEY(reasoncode) REFERENCES reasoncodes(reasoncode)

);
REVOKE ALL on "log" from PUBLIC;
GRANT ALL on "log" to "%SQLSERVER_USER%";

--
CREATE TABLE "reporttable" (
	"rptreportid" integer PRIMARY KEY NOT NULL UNIQUE,
	"rpttimestamp" datetime NOT NULL,
	"srvserverid" integer NOT NULL,
	"actactionid" integer,
	"atytypeid" integer,
	"rptsuccess" integer,
	"rptmessage" character varying(255)
);
REVOKE ALL on "reporttable" from PUBLIC;
GRANT ALL on "reporttable" to "%SQLSERVER_USER%";
CREATE INDEX reporttable_rpttimestamp_indx on reporttable(rpttimestamp);
CREATE INDEX reporttable_srvid_indx on reporttable(rptreportid);

--
CREATE TABLE "servertype" (
	"styservertype" integer PRIMARY KEY NOT NULL UNIQUE,
	"styremark" character varying(100) null
);
REVOKE ALL on "servertype" from PUBLIC;
GRANT ALL on "servertype" to "%SQLSERVER_USER%";
CREATE INDEX servertype_srvservertype_idx on servertype(styservertype);

--
-- FIXME: s/NOT NULL//  on: srvinstalltime, srvflatfileloglevel, srvflatfile
CREATE TABLE "services" (
	"srvserverid" integer PRIMARY KEY NOT NULL UNIQUE default nextval('seq_services'),
	"srvinstalltime" datetime,
	"srvname" character varying(20) NOT NULL,
	"srvservertype" integer NOT NULL,
	"srvflatfileloglevel" integer,
	"srvflatfile" character varying(25),
	"srvmaxflatfilesize" integer default 100,
	"srvdescription" character varying(255) null,
	"srvheartbeatinterval" integer default 20 NOT NULL,
	"srvnotificationdelay" integer default 40 NOT NULL,
	"srvmaxnotifications" integer default 100 NOT NULL,
	"srvactionsinterval" integer default 10 NOT NULL,
	"version" character varying(10) NOT NULL default 0
);
REVOKE ALL on "services" from PUBLIC;
GRANT ALL on "services" to "%SQLSERVER_USER%";
CREATE INDEX services_srvid_indx on services(srvserverid);

--
CREATE TABLE "vas" (
	"vas_server_id" integer PRIMARY KEY NOT NULL UNIQUE,
	"vas_db_ip" varchar(20) not null,
	"vas_db_name" varchar(50) not null,
	"vas_db_user" varchar(20) not null,
	"vas_db_password" varchar(30) not null,
	"vas_modemid" integer not null,
	"vas_modem_device" varchar(30) not null,
	"vas_primary" boolean not null,
	"vas_attempts_delay" integer not null default 15,
	"vas_max_attempts" integer not null default 4
);
REVOKE ALL on "vas" from PUBLIC;
GRANT ALL on "vas" to "%SQLSERVER_USER%";

--
CREATE TABLE "vas_alarm_messages" (
	"vas_action_id" integer PRIMARY KEY NOT NULL UNIQUE,
	"vas_failure_id" integer NOT NULL,
	"vas_identifier" integer NOT NULL,
	"vas_success" boolean NOT NULL DEFAULT 'f'::bool,
	"vas_sent_time" datetime NOT NULL DEFAULT current_timestamp,
	"vas_attempts" integer NOT NULL DEFAULT 0,
	"vas_acknowledged" boolean NOT NULL DEFAULT 'f'::bool,
	"vas_receiver_id" integer NOT NULL,
	"vas_message" character varying(160) NOT NULL
);
REVOKE ALL on "vas_alarm_messages" from PUBLIC;
GRANT ALL on "vas_alarm_messages" to "%SQLSERVER_USER%";
SELECT setval ('"seq_alarm_messages"', 1, 'f');

--
CREATE TABLE "vas_configuration" (
    "vas_server_id"    integer     PRIMARY KEY,
    "vas_db_ip"        varchar(20) not null,
    "vas_db_name"      varchar(50) not null,
    "vas_db_user"      varchar(20) not null,
    "vas_db_password"  varchar(30) not null,
    "vas_modemid"      integer     not null,
    "vas_modem_device" varchar(30) not null
);
REVOKE ALL on "vas_configuration" from PUBLIC;
GRANT ALL on "vas_configuration" to "%SQLSERVER_USER%";
