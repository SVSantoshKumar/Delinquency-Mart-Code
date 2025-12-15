CREATE OR REPLACE PROCEDURE DISHA_MART_ANALYTICS.COLLECTION_MART.LOAD_COLLECTION_BOUNCE_WITH_DUPLICATES("RUN_DATE" DATE DEFAULT CURRENT_DATE())
RETURNS VARCHAR(255)
LANGUAGE SQL
EXECUTE AS OWNER
AS 'DECLARE
        -- Logging Variables
    	PROC_NAME VARCHAR(500):=''DISHA_MART_ANALYTICS.COLLECTION_MART.LOAD_COLLECTION_BOUNCE_WITH_DUPLICATES'';
    	TBL_NAME VARCHAR(500):=''DISHA_MART_ANALYTICS.COLLECTION_MART.COLLECTION_BOUNCE_WITH_DUPLICATES'';
        TOTAL_ROWS_IN_PREFINAL INTEGER;
        ROWS_INSERTED INTEGER DEFAULT 0;
        ROWS_UPDATED INTEGER DEFAULT 0;
        ROWS_UNCHANGED INTEGER DEFAULT 0;
        DUPLICATE_COUNT INTEGER;
        DUPLICATE_DETAILS VARCHAR(2000);
        CURR_TIME TIMESTAMP := TO_VARCHAR(CURRENT_TIMESTAMP());
        ERROR_MESSAGE VARCHAR(1000);
        FINAL_OUTPUT VARCHAR(4000);
        INSERT_COLUMN_LIST VARCHAR;
        INSERT_VALUE_LIST VARCHAR;
        INSERT_STATEMENT VARCHAR(16000);
		
    
	BEGIN
  
CREATE TABLE IF NOT EXISTS DISHA_MART_ANALYTICS.COLLECTION_MART.COLLECTION_BOUNCE_WITH_DUPLICATES
(
loan_no VARCHAR(255),
old_loan_no VARCHAR(255),
instrument_no VARCHAR(255),
deposit_bank_account VARCHAR(255),
instrument_mode VARCHAR(255),
instrument_amount VARCHAR(255) ,
allocated_amt VARCHAR(255),
received_date VARCHAR(255),
CYCLE VARCHAR(255),
instrument_date VARCHAR(255),
gross_status VARCHAR(255),
reason_for_bouncing VARCHAR(255),
STATUS_MAX VARCHAR(255),
STATUS_13 VARCHAR(255),
STATUS_18 VARCHAR(255),
STATUS_24 VARCHAR(255),
net_status VARCHAR(255),
MONTH VARCHAR(255),
gross_bounce VARCHAR(255),
net_bounce VARCHAR(255),
active_flag_new VARCHAR(255));

	

-- Step 1: Load from dtsl.MODE_FILTER1_DEC

CREATE OR REPLACE TEMP TABLE DISHA_MART_ANALYTICS.COLLECTION_MART.mode_filter1 AS
SELECT *
FROM DISHA_L1_HARMONIZED.FLEX_LMS.RCPTDUMP_EXTRACT
WHERE TRIM(UPPER(allocated_to)) IN (''EMI AMOUNT'', ''ADVANCE AMOUNT'')
  AND TO_DATE(MAKER_DAT) = :RUN_DATE
  AND ACTIVATION_FLAG = 1
QUALIFY RANK() OVER (ORDER BY DATE(INGESTION_DATE) DESC) = 1;


-- Step 2: Enrich with cycle and booking date

CREATE OR REPLACE TEMP TABLE DISHA_MART_ANALYTICS.COLLECTION_MART.kk AS
SELECT 
    a.*,
	c.loan_no,
	b.cod_acct_no,
    DAY(b.CYCLE_DATE) AS CYCLE,
	TO_DATE(c.start_timestamp) as start_date,
	(c.end_timestamp) as end_date
FROM DISHA_MART_ANALYTICS.COLLECTION_MART.mode_filter1 a
LEFT JOIN (
    SELECT
        cod_acct_no,
        MAX(TO_DATE(dat_stage_end)) AS CYCLE_DATE
    FROM DISHA_L1_HARMONIZED.FLEX_LMS.LN_ACCT_SCHEDULE
    WHERE nam_stage = ''EMI'' and ACTIVATION_FLAG = 1 GROUP BY cod_acct_no
) b ON TRIM(a.NEW_LN_ACCT_NO) = TRIM(b.cod_acct_no)
LEFT JOIN DISHA_MART_ANALYTICS.COLLECTION_MART.DELINQUENCY_MART c
    ON TRIM(a.NEW_LN_ACCT_NO) = TRIM(c.loan_no) 
    where  TO_DATE(c.start_timestamp) <= :RUN_DATE and ( TO_DATE(c.end_timestamp) > :RUN_DATE OR  TO_DATE(c.end_timestamp) IS NULL);


-- Step 3: First receipt (min authordate, not Cancelled)
CREATE OR REPLACE TEMP TABLE DISHA_MART_ANALYTICS.COLLECTION_MART.ns_min AS
SELECT *
FROM (
    SELECT 
        new_ln_acct_no,
		OLD_LN_ACCT_NO,
		INSTR_NO,
		prtnr_bank_nam,
		INSTR_MODE,
		INSTR_AMT,
		ALLOCATED_AMT,
		Rcpt_stat AS status_min,
        author_dat AS min_authordate,
		MAKER_DAT,
		INSTR_DAT,
		BOUNCE_REASON,
		START_DATE,
        ROW_NUMBER() OVER (PARTITION BY new_ln_acct_no ORDER BY author_dat ASC) AS rn
    FROM DISHA_MART_ANALYTICS.COLLECTION_MART.kk
    WHERE Rcpt_stat <> ''Cancelled''
)
QUALIFY rn = 1 ORDER BY status_min ;

-- Step 4: Last receipt (max authordate, not Cancelled)
CREATE OR REPLACE TEMP TABLE DISHA_MART_ANALYTICS.COLLECTION_MART.ns_max AS
SELECT *
FROM (
    SELECT 
        new_ln_acct_no,
		OLD_LN_ACCT_NO,
		INSTR_NO,
		prtnr_bank_nam,
		INSTR_MODE,
		INSTR_AMT,
		ALLOCATED_AMT,
        Rcpt_stat AS status_max,
        author_dat AS max_authordate,
        MAKER_DAT,
		INSTR_DAT,
		BOUNCE_REASON,
		START_DATE,
        ROW_NUMBER() OVER (PARTITION BY new_ln_acct_no ORDER BY author_dat DESC) AS rn
    FROM DISHA_MART_ANALYTICS.COLLECTION_MART.kk
    WHERE Rcpt_stat <> ''Cancelled''
)
QUALIFY rn = 1 order by status_max;

CREATE OR REPLACE TEMP TABLE DISHA_MART_ANALYTICS.COLLECTION_MART.ns_final AS
SELECT DISTINCT 
 a.new_ln_acct_no,
	a.old_ln_acct_no,
	b.INSTR_NO,
	b.prtnr_bank_nam,
	b.INSTR_MODE,
    b.INSTR_AMT,
	a.INSTR_DAT,
	a.MAKER_DAT AS RECIEVED_DATE,
    a.cycle,
    b.status_min AS GROSS_STATUS,
    b.BOUNCE_REASON,
    b.min_authordate,
    b.allocated_amt,
    c.status_max,
    c.max_authordate
FROM DISHA_MART_ANALYTICS.COLLECTION_MART.kk a
LEFT JOIN DISHA_MART_ANALYTICS.COLLECTION_MART.ns_min b ON TRIM(a.new_ln_acct_no) = TRIM(b.new_ln_acct_no)
LEFT JOIN DISHA_MART_ANALYTICS.COLLECTION_MART.ns_max c ON TRIM(a.new_ln_acct_no) = TRIM(c.new_ln_acct_no);



CREATE OR REPLACE TEMP TABLE DISHA_MART_ANALYTICS.COLLECTION_MART.net_status_1 AS
SELECT 
    a.*,
    c.STATUS AS status_13,
    d.STATUS AS status_18,
    e.STATUS AS status_24
FROM DISHA_MART_ANALYTICS.COLLECTION_MART.ns_final a
LEFT JOIN (
    SELECT *
    FROM DISHA_MART_ANALYTICS.COLLECTION_MART.DELINQUENCY_MART where TO_DATE(start_timestamp) <= DATE_TRUNC(''MONTH'',TO_DATE(:RUN_DATE)) + INTERVAL ''12 DAY''
AND (TO_DATE(end_timestamp) > DATE_TRUNC(''MONTH'',TO_DATE(:RUN_DATE)) + INTERVAL ''12 DAY'' 
     OR end_timestamp IS NULL)) c 
ON TRIM(a.new_ln_acct_no) = TRIM(c.loan_no) 
LEFT JOIN (
    SELECT *
    FROM DISHA_MART_ANALYTICS.COLLECTION_MART.DELINQUENCY_MART where TO_DATE(start_timestamp) <= DATE_TRUNC(''MONTH'',TO_DATE(:RUN_DATE)) + INTERVAL ''17 DAY''
AND (TO_DATE(end_timestamp) > DATE_TRUNC(''MONTH'',TO_DATE(:RUN_DATE)) + INTERVAL ''17 DAY'' 
     OR end_timestamp IS NULL)) d 
ON TRIM(a.new_ln_acct_no) = TRIM(d.loan_no) 

LEFT JOIN (
    SELECT *
    FROM DISHA_MART_ANALYTICS.COLLECTION_MART.DELINQUENCY_MART where TO_DATE(start_timestamp) <= DATE_TRUNC(''MONTH'',TO_DATE(:RUN_DATE)) + INTERVAL ''23 DAY''
AND (TO_DATE(end_timestamp) > DATE_TRUNC(''MONTH'',TO_DATE(:RUN_DATE)) + INTERVAL ''23 DAY'' 
     OR end_timestamp IS NULL)) e 
ON TRIM(a.new_ln_acct_no) = TRIM(e.loan_no) ;


CREATE OR REPLACE TEMP TABLE DISHA_MART_ANALYTICS.COLLECTION_MART.rrd AS
SELECT *,
TRIM(NEW_LN_ACCT_NO) as NEW_LN_ACCT_NO_upd,
    CASE 
        WHEN cycle = ''05'' AND status_13 IN (''ROLLFORWARD'', ''Cheque in transit'',''Roll-forward'', ''Chq In Transit'') AND status_max = ''Bounced'' THEN ''Bounced''
        WHEN cycle = ''10'' AND status_18 IN (''ROLLFORWARD'', ''Cheque in transit'',''Roll-forward'', ''Chq In Transit'') AND status_max = ''Bounced'' THEN ''Bounced''
        WHEN cycle = ''15'' AND status_24 IN (''ROLLFORWARD'', ''Cheque in transit'',''Roll-forward'', ''Chq In Transit'') AND status_max = ''Bounced'' THEN ''Bounced''
        ELSE ''Pass''
    END AS final_net
FROM DISHA_MART_ANALYTICS.COLLECTION_MART.net_status_1;







DROP TABLE IF EXISTS DISHA_MART_ANALYTICS.COLLECTION_MART.COLLECTION_BOUNCE_WITH_DUPLICATES_PREFINAL;
	
	
CREATE OR REPLACE TEMPORARY TABLE  DISHA_MART_ANALYTICS.COLLECTION_MART.COLLECTION_BOUNCE_WITH_DUPLICATES_PREFINAL
(
loan_no VARCHAR(255),
old_loan_no VARCHAR(255),
instrument_no VARCHAR(255),
deposit_bank_account VARCHAR(255),
instrument_mode VARCHAR(255),
instrument_amount VARCHAR(255) ,
allocated_amt VARCHAR(255),
received_date VARCHAR(255),
CYCLE VARCHAR(255),
instrument_date VARCHAR(255),
gross_status VARCHAR(255),
reason_for_bouncing VARCHAR(255),
STATUS_MAX VARCHAR(255),
STATUS_13 VARCHAR(255),
STATUS_18 VARCHAR(255),
STATUS_24 VARCHAR(255),
net_status VARCHAR(255),
MONTH VARCHAR(255),
gross_bounce VARCHAR(255),
net_bounce VARCHAR(255),
active_flag_new VARCHAR(255))
AS	
SELECT 
NEW_LN_ACCT_NO_upd AS LOAN_NO,
OLD_LN_ACCT_NO AS OLD_LOAN_NO,
INSTR_NO AS instrument_no,
PRTNR_BANK_NAM AS deposit_bank_account,
INSTR_MODE	AS instrument_mode,
INSTR_AMT AS instrument_amount,
ALLOCATED_AMT AS allocated_amt,
RECIEVED_DATE AS received_date,
CYCLE AS cycle,
INSTR_DAT AS instrument_date,
GROSS_STATUS AS gross_status,
BOUNCE_REASON AS reason_for_bouncing,
STATUS_MAX AS STATUS_MAX,
STATUS_13 AS STATUS_13,
STATUS_18 AS STATUS_18,
STATUS_24 AS STATUS_24,
final_net AS net_status,
DATE_TRUNC(''MONTH'', TO_DATE(instrument_date, ''DD-MM-YYYY'')) AS MONTH,
CASE WHEN gross_status = ''Bounced'' then ''1'' ELSE ''0'' end as gross_bounce,
CASE WHEN net_status = ''Bounced'' then ''1'' ELSE ''0'' end as net_bounce,
''1'' as active_flag_new
from DISHA_MART_ANALYTICS.COLLECTION_MART.rrd ;

 -- Count total rows in prefinal table
        SELECT COUNT(*) INTO :TOTAL_ROWS_IN_PREFINAL
        FROM DISHA_MART_ANALYTICS.COLLECTION_MART.COLLECTION_BOUNCE_WITH_DUPLICATES_PREFINAL;	
	
	
	-- Check for duplicates with details
        WITH DUPLICATE_CHECK AS (
            SELECT 
                loan_no ,instrument_no, instrument_mode,instrument_amount ,allocated_amt, received_date,instrument_date,gross_status,
				reason_for_bouncing,net_status,
                COUNT(*) AS RECORD_COUNTCOLLECTION_BOUNCE_WITH_DUPLICATES_PREFINAL
            FROM DISHA_MART_ANALYTICS.COLLECTION_MART.COLLECTION_BOUNCE_WITH_DUPLICATES_PREFINAL
            GROUP BY loan_no ,instrument_no, instrument_mode,instrument_amount ,allocated_amt, received_date,instrument_date,gross_status,reason_for_bouncing,net_status
            HAVING COUNT(*) > 1
        )
        SELECT COUNT(*) INTO :DUPLICATE_COUNT
        FROM DUPLICATE_CHECK;

 -- Insert column list (all columns including metadata columns)
        SELECT LISTAGG(COLUMN_NAME, '','')  WITHIN GROUP (ORDER BY ORDINAL_POSITION)
        INTO :INSERT_COLUMN_LIST
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = ''COLLECTION_MART''
        AND TABLE_NAME = ''COLLECTION_BOUNCE_WITH_DUPLICATES_PREFINAL''
        AND TABLE_CATALOG = ''DISHA_MART_ANALYTICS'';
		
 -- Insert value list (dynamically mapping source columns)
        SELECT LISTAGG(''S.'' || COLUMN_NAME, '','')  WITHIN GROUP (ORDER BY ORDINAL_POSITION)
        INTO :INSERT_VALUE_LIST
        FROM DISHA_MART_ANALYTICS.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = ''COLLECTION_MART''
        AND TABLE_NAME = ''COLLECTION_BOUNCE_WITH_DUPLICATES_PREFINAL''
        AND TABLE_CATALOG = ''DISHA_MART_ANALYTICS'';  
		
 -- If duplicates exist, return detailed error
        IF (DUPLICATE_COUNT > 0) THEN
              SELECT CONCAT(
                ''===== DATA LOADING FAILED =====
    '',
                ''Total Rows in Prefinal: '', :TOTAL_ROWS_IN_PREFINAL, ''
    '',
                ''Duplicate Rows Found: '', :DUPLICATE_COUNT, ''
    '',
                ''ERROR: Unable to load data due to duplicate entries for LOAN_NO.'',''
    ''
            ) INTO :FINAL_OUTPUT;				
	
	--INSERT AUDIT INFO INTO TABLE
		DELETE FROM DISHA_MART_ANALYTICS.AUDIT_INFO.DAILY_COUNT_RECON 
		WHERE  PROCEDURE_NAME=:PROC_NAME
		AND	   EXECUTION_DATE=DATE(:CURR_TIME);
		
		INSERT INTO DISHA_MART_ANALYTICS.AUDIT_INFO.DAILY_COUNT_RECON
		(PROCEDURE_NAME, TABLE_NAME, EXECUTION_DATE, PREFINAL_CNT, INSERTED_CNT, UPDATED_CNT, UNCHANGED_CNT,STATUS,START_TIME,END_TIME)
		SELECT :PROC_NAME,:TBL_NAME,DATE(:CURR_TIME),:TOTAL_ROWS_IN_PREFINAL,:ROWS_INSERTED,:ROWS_UPDATED,:ROWS_UNCHANGED,''FAIL'',:CURR_TIME,CURRENT_TIMESTAMP;
			
        RETURN FINAL_OUTPUT;

        ELSE
		
		
		INSERT_STATEMENT:= 
    	CONCAT(''INSERT INTO DISHA_MART_ANALYTICS.COLLECTION_MART.COLLECTION_BOUNCE_WITH_DUPLICATES('',
    			INSERT_COLUMN_LIST,'')
    			SELECT '',
    			INSERT_VALUE_LIST,''
    			FROM DISHA_MART_ANALYTICS.COLLECTION_MART.COLLECTION_BOUNCE_WITH_DUPLICATES_PREFINAL S;'');
    				
    	EXECUTE IMMEDIATE :INSERT_STATEMENT;	
		
             ROWS_INSERTED := (SELECT COUNT(*) FROM DISHA_MART_ANALYTICS.COLLECTION_MART.COLLECTION_BOUNCE_WITH_DUPLICATES WHERE TO_DATE(instrument_date, ''DD-MM-YYYY'')=DATEADD(DAY,-1,TO_DATE(:RUN_DATE)));
             ROWS_UPDATED := 0;
             ROWS_UNCHANGED := 0;
    	
		      -- Prepare detailed output
              SELECT CONCAT(
                ''===== DATA LOADING REPORT =====
    '',
                ''Process Timestamp: '', :CURR_TIME, ''
    '',
                ''Total Rows in Prefinal: '', :TOTAL_ROWS_IN_PREFINAL, ''
    '',
                ''Rows Inserted: '', :ROWS_INSERTED, ''
    '',
                ''Rows Updated: '', :ROWS_UPDATED, ''
    '',
                ''Rows Unchanged: '', :ROWS_UNCHANGED, ''
    
    '',
                ''
    
    '',
                ''Status: SUCCESSFULLY LOADED DATA INTO COLLECTION_BOUNCE_WITH_DUPLICATES''
            ) INTO :FINAL_OUTPUT;
		
    		--INSERT AUDIT INFO INTO TABLE
    		DELETE FROM DISHA_MART_ANALYTICS.AUDIT_INFO.DAILY_COUNT_RECON 
    		WHERE  PROCEDURE_NAME=:PROC_NAME
    		AND	   EXECUTION_DATE=DATE(:CURR_TIME);
    		
    		INSERT INTO DISHA_MART_ANALYTICS.AUDIT_INFO.DAILY_COUNT_RECON
    		(PROCEDURE_NAME, TABLE_NAME, EXECUTION_DATE, PREFINAL_CNT, INSERTED_CNT, UPDATED_CNT, UNCHANGED_CNT,STATUS,START_TIME,END_TIME)
    		SELECT :PROC_NAME,:TBL_NAME,DATE(:CURR_TIME),:TOTAL_ROWS_IN_PREFINAL,:ROWS_INSERTED,:ROWS_UPDATED,:ROWS_UNCHANGED,''PASS'',:CURR_TIME,CURRENT_TIMESTAMP;
    		
    
            RETURN FINAL_OUTPUT;
        END IF;
    --EXCEPTION
    --    WHEN OTHER THEN
    --        -- Capture any unexpected errors
    --         ERROR_MESSAGE := SQLERRM;
    --        
    --        -- Prepare error output
    --          SELECT CONCAT(
    --            ''===== DATA LOADING FAILED =====
    --'',
    --            ''Error Timestamp: '', :CURR_TIME, ''
    --'',
    --            ''Total Rows in Prefinal: '', :TOTAL_ROWS_IN_PREFINAL, ''
    --'',
    --            ''ERROR MESSAGE: '', :ERROR_MESSAGE, ''
    --'',
    --            ''Status: UNEXPECTED ERROR DURING LOADING''
    --        ) INTO :FINAL_OUTPUT;
    
    --        RETURN FINAL_OUTPUT;
    END';