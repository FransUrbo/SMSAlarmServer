-- $Id: SAS-Functions.sql,v 1.1 2004-07-17 09:02:59 turbo Exp $

\connect - postgres

--
CREATE FUNCTION "insertheartbeat" (integer) RETURNS integer AS '
DECLARE
	p_ServerId	ALIAS FOR $1;

	v_ServerID	integer;
	v_rowcount	integer;
BEGIN
	-- Make sure that the server id exists!!!
	SELECT INTO v_ServerID DISTINCT srvServerID FROM Services WHERE srvServerID = p_ServerId ORDER BY srvServerID;
	IF v_ServerID NOTNULL THEN
		-- Insert a heartbeat in the database...
		INSERT INTO ReportTable (rptTimeStamp, srvServerId, atyTypeId, rptSuccess) VALUES(now(), p_ServerId, 1, 1);
		GET DIAGNOSTICS v_rowcount = ROW_COUNT;
		IF (v_rowcount < 1) THEN
			RAISE EXCEPTION ''ERROR: insertHeartBeat(): Could not insert into ReportTable'';
			RETURN -200;
		END IF;
	ELSE
		-- Oupsi, we''re trying to insert a heartbeat for a non existing server!
		RETURN -100;
	END IF;
	RETURN 0;
END;
' LANGUAGE 'plpgsql';

--
CREATE FUNCTION "makereport" (integer,integer,character varying) RETURNS integer AS '
DECLARE
	p_ServerID	ALIAS FOR $1;
	p_ActionType	ALIAS FOR $2;
	p_Message	ALIAS FOR $3;

	v_rowcount	integer;
BEGIN
	INSERT INTO ReportTable(rptTimeStamp, srvServerId, atyTypeId, rptSuccess, rptMessage) VALUES(now(), p_ServerID, p_ActionType, 1, p_Message);

	-- Check INSERT query status
	GET DIAGNOSTICS v_rowcount = ROW_COUNT;
	IF (v_rowcount < 1) THEN
		RETURN -200;
	END IF;
	RETURN 0;
END;
' LANGUAGE 'plpgsql';

--
CREATE FUNCTION "wwwpollserverstatus" (integer) RETURNS integer AS '
DECLARE
	p_ServerID	ALIAS FOR $1;
	v_DelayTime	integer;
	v_LastReport	timestamp;
BEGIN
	-- Get Server notification time from services for the choosen server. Returns number of seconds like ''120''
	SELECT INTO v_DelayTime sum(srvheartbeatinterval + srvnotificationdelay) FROM services WHERE srvServerId = p_ServerID;
	SELECT INTO v_DelayTime srvNotificationDelay+srvHeartBeatInterval FROM services WHERE srvServerId = p_ServerID;
	IF v_DelayTime NOTNULL THEN
		-- When did the server last report in? Returns something like ''2001-07-23 15:16:35+02''.
		SELECT INTO v_LastReport Max(rptTimeStamp) FROM ReportTable WHERE srvServerId = p_ServerID AND atyTypeId = 1;
		IF v_LastReport NOTNULL THEN
			-- Check to see if the server have reported in in the last v_DelayTime seconds...
			-- extract() converts the timestamp into seconds from UNIX system time zero
			IF (extract(EPOCH FROM TIMESTAMP ''current'') < (extract(EPOCH FROM v_LastReport) + v_DelayTime)) THEN
				-- Everything A ok, Return 0
				RETURN 0;
			END IF;
		END IF;
	END IF;

	-- Nothing found, return 1
	RETURN 1;
END;
' LANGUAGE 'plpgsql';
