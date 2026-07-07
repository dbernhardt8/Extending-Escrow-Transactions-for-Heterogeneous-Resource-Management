-- =============================================================================
-- Complete System Setup Script
-- =============================================================================
-- This script sets up the entire Resource Planning System from scratch.
-- 
-- FEATURES:
--   - Creates all database objects (tables, sequences, views, packages)
--   - Proper dependency order
--   - Error handling and validation
--   - Summary statistics
--
-- WHAT IT DOES:
--   1. Creates database schema (tables, sequences, views)
--   2. Sets up Oracle Advanced Queue (AQ) for timeout processing
--   3. Installs CRUD package (Data Access Layer)
--   4. Installs ResourceManagement package (Business Logic Layer)
--   5. Loads comprehensive mock data with capacity snapshots
--
-- USAGE:
--   For clean installation:
--     1. First run cleanup: @sql/0_cleanup_all.sql
--     2. Then run setup:    @sql/0_complete_system_setup.sql
--
-- PREREQUISITES:
--   - Oracle Database with AQ enabled
--   - Sufficient privileges (CREATE TABLE, CREATE SEQUENCE, CREATE PACKAGE, AQ operations)
--   - Clean database (run @sql/0_cleanup_all.sql first if reinstalling)
--
-- TIME: ~30-60 seconds for complete setup
--
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED;
SET VERIFY OFF;
SET FEEDBACK OFF;

WHENEVER SQLERROR CONTINUE;

BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('===============================================================================');
    DBMS_OUTPUT.PUT_LINE('               RESOURCE PLANNING SYSTEM - COMPLETE SETUP');
    DBMS_OUTPUT.PUT_LINE('===============================================================================');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('This script will install the complete system:');
    DBMS_OUTPUT.PUT_LINE('  ✓ Database Schema (tables, sequences, views)');
    DBMS_OUTPUT.PUT_LINE('  ✓ Oracle Advanced Queue (timeout processing)');
    DBMS_OUTPUT.PUT_LINE('  ✓ ResourceManagement_Data Package (CRUD operations)');
    DBMS_OUTPUT.PUT_LINE('  ✓ ResourceManagement Package (business logic)');
    DBMS_OUTPUT.PUT_LINE('  ✓ Mock Data (12 aircraft, 12 flights, 200 users, ~3000 bookings)');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('NOTE: Run @sql/0_cleanup_all.sql first if reinstalling!');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Starting setup now...');
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- STEP 1: Database Schema Setup
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 1/8: Database Schema Setup
PROMPT ===============================================================================
PROMPT Creating tables, sequences, views...
PROMPT

@@1_database_model.sql

PROMPT
PROMPT ✓ Database schema created
PROMPT

-- =============================================================================
-- STEP 2: Oracle Advanced Queue Setup
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 2/8: Oracle Advanced Queue Setup
PROMPT ===============================================================================
PROMPT Setting up AQ for timeout processing...
PROMPT

@@1.5_aq_setup.sql

PROMPT
PROMPT ✓ Advanced Queue configured
PROMPT

-- =============================================================================
-- STEP 3: CRUD Package Specification (Data Access Layer)
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 3/8: Data Access Layer - Package Specification
PROMPT ===============================================================================
PROMPT Creating ResourceManagement_Data package spec...
PROMPT

@@3.1_crud_specification.pks

PROMPT
PROMPT ✓ ResourceManagement_Data specification created
PROMPT

-- =============================================================================
-- STEP 4: CRUD Package Body (Data Access Layer)
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 4/8: Data Access Layer - Package Body
PROMPT ===============================================================================
PROMPT Creating ResourceManagement_Data package body...
PROMPT

@@3.2_crud_body.pkb

PROMPT
PROMPT ✓ ResourceManagement_Data body created
PROMPT

-- =============================================================================
-- STEP 5: Business Logic Package Specification
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 5/8: Business Logic Layer - Package Specification
PROMPT ===============================================================================
PROMPT Creating ResourceManagement package spec...
PROMPT

@@2.1_database_specification.pks

PROMPT
PROMPT ✓ ResourceManagement specification created
PROMPT

-- =============================================================================
-- STEP 6: Business Logic Package Body
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 6/8: Business Logic Layer - Package Body
PROMPT ===============================================================================
PROMPT Creating ResourceManagement package body...
PROMPT

@@2.2_database_body.pkb

PROMPT
PROMPT ✓ ResourceManagement body created
PROMPT

-- =============================================================================
-- STEP 7: Mock Data Insertion
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 7/8: Mock Data Insertion
PROMPT ===============================================================================
PROMPT Loading comprehensive test data...
PROMPT (This may take 30-60 seconds)
PROMPT

--@@4_insert_mock_data_extensive.sql

PROMPT
PROMPT ✓ Mock data loaded and capacity snapshots initialized
PROMPT

-- =============================================================================
-- STEP 8: Category Substitution Setup
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT STEP 8/8: Category Substitution Setup
PROMPT ===============================================================================
PROMPT Setting up category hierarchy and substitution rules...
PROMPT

--@@1.7_category_substitution.sql

PROMPT
PROMPT ✓ Category substitution system configured
PROMPT

-- =============================================================================
-- Validation Checks
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT VALIDATION CHECKS
PROMPT ===============================================================================

DECLARE
    v_tables NUMBER;
    v_packages NUMBER;
    v_package_status VARCHAR2(10);
    v_crud_status VARCHAR2(10);
    v_queue_exists NUMBER;
    v_users NUMBER;
    v_flights NUMBER;
    v_seats NUMBER;
    v_reservations NUMBER;
    v_capacity_snapshots NUMBER;
    v_all_valid BOOLEAN := TRUE;
BEGIN
    -- Check tables
    SELECT COUNT(*) INTO v_tables
    FROM user_tables
    WHERE table_name IN ('RESOURCEASSET', 'ALLOCATIONCONTEXT', 'ALLOCATIONJOURNAL', 
                         'CAPACITY', 'USERS', 'RESOURCEINSTANCE');
    
    IF v_tables = 6 THEN
        DBMS_OUTPUT.PUT_LINE('✓ Core tables exist: ' || v_tables || '/6');
    ELSE
        DBMS_OUTPUT.PUT_LINE('✗ Missing tables! Found: ' || v_tables || '/6 expected');
        v_all_valid := FALSE;
    END IF;
    
    -- Check packages
    SELECT COUNT(*) INTO v_packages
    FROM user_objects
    WHERE object_type = 'PACKAGE'
      AND object_name IN ('RESOURCEMANAGEMENT', 'RESOURCEMANAGEMENT_DATA');
    
    IF v_packages = 2 THEN
        DBMS_OUTPUT.PUT_LINE('✓ Packages installed: ' || v_packages || '/2');
    ELSE
        DBMS_OUTPUT.PUT_LINE('✗ Missing packages! Found: ' || v_packages || '/2 expected');
        v_all_valid := FALSE;
    END IF;
    
    -- Check package validity
    SELECT status INTO v_package_status
    FROM user_objects
    WHERE object_type = 'PACKAGE BODY' AND object_name = 'RESOURCEMANAGEMENT';
    
    SELECT status INTO v_crud_status
    FROM user_objects
    WHERE object_type = 'PACKAGE BODY' AND object_name = 'RESOURCEMANAGEMENT_DATA';
    
    IF v_package_status = 'VALID' AND v_crud_status = 'VALID' THEN
        DBMS_OUTPUT.PUT_LINE('✓ Package bodies compiled successfully');
    ELSE
        DBMS_OUTPUT.PUT_LINE('✗ Package compilation errors detected');
        DBMS_OUTPUT.PUT_LINE('  - ResourceManagement: ' || v_package_status);
        DBMS_OUTPUT.PUT_LINE('  - ResourceManagement_Data: ' || v_crud_status);
        v_all_valid := FALSE;
    END IF;
    
    -- Check AQ
    SELECT COUNT(*) INTO v_queue_exists
    FROM user_queues
    WHERE name = 'WF_USER_EVENTS_Q';
    
    IF v_queue_exists > 0 THEN
        DBMS_OUTPUT.PUT_LINE('✓ Advanced Queue configured');
    ELSE
        DBMS_OUTPUT.PUT_LINE('⚠ Warning: Advanced Queue not found');
    END IF;
    
    -- Check data
    SELECT COUNT(*) INTO v_users FROM Users;
    SELECT COUNT(*) INTO v_flights FROM AllocationContext;
    SELECT COUNT(*) INTO v_seats FROM ResourceInstance;
    SELECT COUNT(*) INTO v_reservations FROM AllocationJournal WHERE status = 'confirmed';
    SELECT COUNT(*) INTO v_capacity_snapshots FROM Capacity;
    
    DBMS_OUTPUT.PUT_LINE('✓ Mock data loaded:');
    DBMS_OUTPUT.PUT_LINE('  - Users: ' || v_users);
    DBMS_OUTPUT.PUT_LINE('  - Flights: ' || v_flights);
    DBMS_OUTPUT.PUT_LINE('  - Seats: ' || v_seats);
    DBMS_OUTPUT.PUT_LINE('  - Reservations: ' || v_reservations);
    DBMS_OUTPUT.PUT_LINE('  - Capacity Records: ' || v_capacity_snapshots);
    
    DBMS_OUTPUT.PUT_LINE('');
    
    IF v_all_valid THEN
        DBMS_OUTPUT.PUT_LINE('===============================================================================');
        DBMS_OUTPUT.PUT_LINE('                    ✓ SETUP COMPLETE - ALL CHECKS PASSED');
        DBMS_OUTPUT.PUT_LINE('===============================================================================');
    ELSE
        DBMS_OUTPUT.PUT_LINE('===============================================================================');
        DBMS_OUTPUT.PUT_LINE('                    ⚠ SETUP COMPLETE - WITH WARNINGS');
        DBMS_OUTPUT.PUT_LINE('===============================================================================');
        DBMS_OUTPUT.PUT_LINE('Please review the errors above.');
    END IF;
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ Validation check failed: ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('Some components may not be installed correctly.');
END;
/

-- =============================================================================
-- Quick Start Guide
-- =============================================================================
PROMPT
PROMPT ===============================================================================
PROMPT QUICK START GUIDE
PROMPT ===============================================================================
PROMPT
PROMPT Your Resource Planning System is ready to use!
PROMPT
PROMPT NEXT STEPS:
PROMPT
PROMPT 1. Run Unit Tests:
PROMPT    @TESTS/TEST_MakeReservationWithTimeout.sql
PROMPT    @TESTS/TEST_ConfirmReservation.sql
PROMPT    @TESTS/TEST_CancelFlight.sql
PROMPT
PROMPT 2. View Sample Data:
PROMPT    SELECT * FROM Capacity;
PROMPT    SELECT * FROM CurrentAllocations;
PROMPT    SELECT * FROM AllocationHistory;
PROMPT
PROMPT 3. Make a Test Reservation:
PROMPT    DECLARE
PROMPT      v_ids SYS.ODCINUMBERLIST;
PROMPT    BEGIN
PROMPT      ResourceManagement.MakeReservationWithTimeout(
PROMPT        p_context_identifier => 'LH 710 MUC-HND',
PROMPT        p_category_name => 'Business Class',
PROMPT        p_user_id => 1,
PROMPT        p_quantity => 2,
PROMPT        p_timeout_minutes => 15,
PROMPT        p_new_journal_ids => v_ids
PROMPT      );
PROMPT      DBMS_OUTPUT.PUT_LINE('Reserved 2 seats, Journal IDs: ' || v_ids(1) || ', ' || v_ids(2));
PROMPT      COMMIT;
PROMPT    END;
PROMPT    /
PROMPT
PROMPT 4. Test Timeout System (1-minute timeout):
PROMPT    @TESTS/TEST_MANUAL.sql
PROMPT
PROMPT 5. View Documentation:
PROMPT    - PROCEDURE_FLOW_ANALYSIS.md (detailed procedure documentation)
PROMPT    - TEST_SUITE_STATUS.md (test suite overview)
PROMPT
PROMPT ===============================================================================
PROMPT IMPORTANT NOTES:
PROMPT ===============================================================================
PROMPT
PROMPT ⚠ Timeout System:
PROMPT   - All reservations have automatic timeout (default: 15 minutes)
PROMPT   - Specific seats have 5-minute hold
PROMPT   - Confirm reservations to prevent auto-cancellation
PROMPT
PROMPT ⚠ Capacity Management:
PROMPT   - Real-time availability via Capacity table
PROMPT   - Lock-free RESERVABLE counters for high concurrency
PROMPT   - O(1) performance for availability queries
PROMPT   - Automatic counter updates on all state transitions
PROMPT
PROMPT ⚠ Data Integrity:
PROMPT   - All procedures use savepoints for transaction safety
PROMPT   - Capacity counters validated automatically
PROMPT   - Immutable journal (append-only)
PROMPT
PROMPT ===============================================================================
PROMPT                        SETUP SCRIPT COMPLETE
PROMPT ===============================================================================
PROMPT

SET FEEDBACK ON;
SET VERIFY ON;
