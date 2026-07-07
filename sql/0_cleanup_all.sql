-- =============================================================================
-- Complete System Cleanup Script
-- =============================================================================
-- This script removes ALL database objects created by the Resource Planning System.
-- 
-- USE WITH CAUTION - This will permanently delete:
--   ✗ All packages (ResourceManagement, ResourceManagement_Data)
--   ✗ All tables and their data
--   ✗ All sequences
--   ✗ All views
--   ✗ All Oracle AQ queues and queue tables
--
-- USAGE:
--   @sql/0_cleanup_all.sql
--
-- After running this script, you can reinstall the system with:
--   @sql/0_complete_system_setup.sql
--
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED;
SET VERIFY OFF;
SET FEEDBACK ON;

WHENEVER SQLERROR CONTINUE;

BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('===============================================================================');
    DBMS_OUTPUT.PUT_LINE('               RESOURCE PLANNING SYSTEM - COMPLETE CLEANUP');
    DBMS_OUTPUT.PUT_LINE('===============================================================================');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('⚠⚠⚠ WARNING: This will PERMANENTLY DELETE all system objects! ⚠⚠⚠');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('  ✗ All packages');
    DBMS_OUTPUT.PUT_LINE('  ✗ All tables and data');
    DBMS_OUTPUT.PUT_LINE('  ✗ All sequences');
    DBMS_OUTPUT.PUT_LINE('  ✗ All views');
    DBMS_OUTPUT.PUT_LINE('  ✗ All AQ queues');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Starting cleanup now...');
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- STEP 1: Drop Oracle Advanced Queues
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 1/5: Dropping Oracle Advanced Queues
PROMPT ===============================================================================

DECLARE
    v_queue_exists NUMBER;
    v_queue_table_exists NUMBER;
BEGIN
    -- Check if queue exists
    SELECT COUNT(*) INTO v_queue_exists
    FROM user_queues
    WHERE name = 'WF_USER_EVENTS_Q';
    
    IF v_queue_exists > 0 THEN
        BEGIN
            -- Stop the queue first
            DBMS_AQADM.STOP_QUEUE(
                queue_name => 'WF_USER_EVENTS_Q'
            );
            DBMS_OUTPUT.PUT_LINE('✓ Stopped queue: WF_USER_EVENTS_Q');
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  (Queue already stopped or error: ' || SQLERRM || ')');
        END;
        
        BEGIN
            -- Drop the queue
            DBMS_AQADM.DROP_QUEUE(
                queue_name => 'WF_USER_EVENTS_Q'
            );
            DBMS_OUTPUT.PUT_LINE('✓ Dropped queue: WF_USER_EVENTS_Q');
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('✗ Error dropping queue: ' || SQLERRM);
        END;
    ELSE
        DBMS_OUTPUT.PUT_LINE('  (No queue to drop)');
    END IF;
    
    -- Check if queue table exists
    SELECT COUNT(*) INTO v_queue_table_exists
    FROM user_queue_tables
    WHERE queue_table = 'WF_USER_EVENTS_QT';
    
    IF v_queue_table_exists > 0 THEN
        BEGIN
            -- Drop the queue table
            DBMS_AQADM.DROP_QUEUE_TABLE(
                queue_table => 'WF_USER_EVENTS_QT',
                force => TRUE
            );
            DBMS_OUTPUT.PUT_LINE('✓ Dropped queue table: WF_USER_EVENTS_QT');
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('✗ Error dropping queue table: ' || SQLERRM);
        END;
    ELSE
        DBMS_OUTPUT.PUT_LINE('  (No queue table to drop)');
    END IF;
    
    -- Drop the queue payload type if it exists
    BEGIN
        EXECUTE IMMEDIATE 'DROP TYPE WF_USER_EVENT_T FORCE';
        DBMS_OUTPUT.PUT_LINE('✓ Dropped type: WF_USER_EVENT_T');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != -4043 THEN -- ORA-04043: object does not exist
                DBMS_OUTPUT.PUT_LINE('✗ Error dropping type: ' || SQLERRM);
            END IF;
    END;
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Error during AQ cleanup: ' || SQLERRM);
END;
/

-- =============================================================================
-- STEP 2: Drop All Packages
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 2/5: Dropping Packages
PROMPT ===============================================================================

DECLARE
    v_count NUMBER := 0;
BEGIN
    FOR pkg IN (
        SELECT object_name 
        FROM user_objects 
        WHERE object_type = 'PACKAGE'
        ORDER BY object_name
    ) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'DROP PACKAGE ' || pkg.object_name;
            DBMS_OUTPUT.PUT_LINE('✓ Dropped package: ' || pkg.object_name);
            v_count := v_count + 1;
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('✗ Error dropping ' || pkg.object_name || ': ' || SQLERRM);
        END;
    END LOOP;
    
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  (No packages to drop)');
    ELSE
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('Total packages dropped: ' || v_count);
    END IF;
END;
/

-- =============================================================================
-- STEP 3: Drop All Views
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 3/5: Dropping Views
PROMPT ===============================================================================

DECLARE
    v_count NUMBER := 0;
BEGIN
    FOR vw IN (
        SELECT view_name 
        FROM user_views 
        ORDER BY view_name
    ) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'DROP VIEW ' || vw.view_name || ' CASCADE CONSTRAINTS';
            DBMS_OUTPUT.PUT_LINE('✓ Dropped view: ' || vw.view_name);
            v_count := v_count + 1;
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('✗ Error dropping ' || vw.view_name || ': ' || SQLERRM);
        END;
    END LOOP;
    
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  (No views to drop)');
    ELSE
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('Total views dropped: ' || v_count);
    END IF;
END;
/

-- =============================================================================
-- STEP 4: Drop All Tables
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 4/5: Dropping Tables
PROMPT ===============================================================================

DECLARE
    v_count NUMBER := 0;
BEGIN
    FOR tbl IN (
        SELECT table_name 
        FROM user_tables 
        ORDER BY table_name
    ) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'DROP TABLE ' || tbl.table_name || ' CASCADE CONSTRAINTS PURGE';
            DBMS_OUTPUT.PUT_LINE('✓ Dropped table: ' || tbl.table_name);
            v_count := v_count + 1;
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('✗ Error dropping ' || tbl.table_name || ': ' || SQLERRM);
        END;
    END LOOP;
    
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  (No tables to drop)');
    ELSE
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('Total tables dropped: ' || v_count);
    END IF;
END;
/

-- =============================================================================
-- STEP 5: Drop All Sequences
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 5/5: Dropping Sequences
PROMPT ===============================================================================

DECLARE
    v_count NUMBER := 0;
    v_skipped NUMBER := 0;
BEGIN
    FOR seq IN (
        SELECT sequence_name 
        FROM user_sequences 
        WHERE sequence_name NOT LIKE 'ISEQ$$%'  -- Exclude system-generated sequences
        ORDER BY sequence_name
    ) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'DROP SEQUENCE ' || seq.sequence_name;
            DBMS_OUTPUT.PUT_LINE('✓ Dropped sequence: ' || seq.sequence_name);
            v_count := v_count + 1;
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('✗ Error dropping ' || seq.sequence_name || ': ' || SQLERRM);
        END;
    END LOOP;
    
    -- Count system-generated sequences
    SELECT COUNT(*) INTO v_skipped
    FROM user_sequences
    WHERE sequence_name LIKE 'ISEQ$$%';
    
    IF v_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  (No sequences to drop)');
    ELSE
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('Total sequences dropped: ' || v_count);
    END IF;
    
    IF v_skipped > 0 THEN
        DBMS_OUTPUT.PUT_LINE('(Skipped ' || v_skipped || ' system-generated sequence(s))');
    END IF;
END;
/

-- =============================================================================
-- Verification
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT VERIFICATION
PROMPT ===============================================================================

DECLARE
    v_packages NUMBER;
    v_tables NUMBER;
    v_sequences NUMBER;
    v_views NUMBER;
    v_queues NUMBER;
    v_system_sequences NUMBER;
    v_clean BOOLEAN := TRUE;
BEGIN
    SELECT COUNT(*) INTO v_packages FROM user_objects WHERE object_type = 'PACKAGE';
    SELECT COUNT(*) INTO v_tables FROM user_tables;
    SELECT COUNT(*) INTO v_sequences FROM user_sequences WHERE sequence_name NOT LIKE 'ISEQ$$%';
    SELECT COUNT(*) INTO v_system_sequences FROM user_sequences WHERE sequence_name LIKE 'ISEQ$$%';
    SELECT COUNT(*) INTO v_views FROM user_views;
    SELECT COUNT(*) INTO v_queues FROM user_queues;
    
    DBMS_OUTPUT.PUT_LINE('Current database status:');
    DBMS_OUTPUT.PUT_LINE('');
    
    IF v_packages = 0 THEN
        DBMS_OUTPUT.PUT_LINE('✓ Packages: ' || v_packages || ' (clean)');
    ELSE
        DBMS_OUTPUT.PUT_LINE('⚠ Packages: ' || v_packages || ' (some remain)');
        v_clean := FALSE;
    END IF;
    
    IF v_tables = 0 THEN
        DBMS_OUTPUT.PUT_LINE('✓ Tables: ' || v_tables || ' (clean)');
    ELSE
        DBMS_OUTPUT.PUT_LINE('⚠ Tables: ' || v_tables || ' (some remain)');
        v_clean := FALSE;
    END IF;
    
    IF v_sequences = 0 THEN
        DBMS_OUTPUT.PUT_LINE('✓ Sequences: ' || v_sequences || ' (clean)');
        IF v_system_sequences > 0 THEN
            DBMS_OUTPUT.PUT_LINE('  (System-generated sequences: ' || v_system_sequences || ' - OK to ignore)');
        END IF;
    ELSE
        DBMS_OUTPUT.PUT_LINE('⚠ Sequences: ' || v_sequences || ' (some remain)');
        v_clean := FALSE;
    END IF;
    
    IF v_views = 0 THEN
        DBMS_OUTPUT.PUT_LINE('✓ Views: ' || v_views || ' (clean)');
    ELSE
        DBMS_OUTPUT.PUT_LINE('⚠ Views: ' || v_views || ' (some remain)');
        v_clean := FALSE;
    END IF;
    
    IF v_queues = 0 THEN
        DBMS_OUTPUT.PUT_LINE('✓ Queues: ' || v_queues || ' (clean)');
    ELSE
        DBMS_OUTPUT.PUT_LINE('⚠ Queues: ' || v_queues || ' (some remain)');
        v_clean := FALSE;
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('');
    
    IF v_clean THEN
        DBMS_OUTPUT.PUT_LINE('===============================================================================');
        DBMS_OUTPUT.PUT_LINE('                    ✓ CLEANUP COMPLETE - DATABASE IS CLEAN');
        DBMS_OUTPUT.PUT_LINE('===============================================================================');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('You can now reinstall the system:');
        DBMS_OUTPUT.PUT_LINE('  @sql/0_complete_system_setup.sql');
    ELSE
        DBMS_OUTPUT.PUT_LINE('===============================================================================');
        DBMS_OUTPUT.PUT_LINE('                    ⚠ CLEANUP COMPLETE - WITH WARNINGS');
        DBMS_OUTPUT.PUT_LINE('===============================================================================');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('Some objects remain in the database.');
        DBMS_OUTPUT.PUT_LINE('Review the output above for details.');
        DBMS_OUTPUT.PUT_LINE('You may need to manually drop remaining objects.');
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Error during verification: ' || SQLERRM);
END;
/

PROMPT ===============================================================================
PROMPT CLEANUP SCRIPT COMPLETE
PROMPT ===============================================================================
PROMPT

SET FEEDBACK ON;
SET VERIFY ON;

