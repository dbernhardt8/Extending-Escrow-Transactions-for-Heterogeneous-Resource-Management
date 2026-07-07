-- =============================================================================
-- Comprehensive Mock Data Insertion Script
-- =============================================================================
-- This script populates the database with an extensive set of mock data for
-- a flight reservation use case.
--
-- Key Features:
--   - Creates 12 aircraft with realistic seating configurations
--   - Generates 12 scheduled flights (long-haul and short-haul)
--   - Creates individual seat instances for each aircraft
--   - Populates 200 test users
--   - Creates realistic booking patterns (70-95% load factor)
--   - Initializes capacity snapshots for real-time availability tracking
--   - Reconciles capacity counters with journal data
--   - Includes 3 unavailable seats with metadata (maintenance, damage, retired)
--
-- Prerequisites:
--   - Database schema created (@sql/1_database_model.sql)
--   - CRUD package installed (@sql/3.1 and 3.2)
--   - ResourceManagement package installed (@sql/2.1 and 2.2)
--   - Empty tables (run @sql/0_cleanup_all.sql first if needed)
--
-- =============================================================================

SET SERVEROUTPUT ON;

BEGIN
    DBMS_OUTPUT.PUT_LINE('--- Starting Mock Data Insertion ---');
END;
/

-- -----------------------------------------------------------------------------
-- Step 1: Populate Core Lookup Tables
-- -----------------------------------------------------------------------------
BEGIN
    DBMS_OUTPUT.PUT_LINE('Populating lookup tables...');

    -- ResourceStatus (for AllocationJournal entries)
    INSERT INTO ResourceStatus (name, description) VALUES ('reserved', 'The resource is held but not yet finalized.');
    INSERT INTO ResourceStatus (name, description) VALUES ('confirmed', 'The resource allocation is confirmed and paid.');
    INSERT INTO ResourceStatus (name, description) VALUES ('cancelled', 'The reservation has been cancelled.');
    INSERT INTO ResourceStatus (name, description) VALUES ('timed_out', 'The reservation was automatically cancelled due to timeout.');
    INSERT INTO ResourceStatus (name, description) VALUES ('checked-in', 'The user has checked in.');
    INSERT INTO ResourceStatus (name, description) VALUES ('boarded', 'The user has boarded.');
    INSERT INTO ResourceStatus (name, description) VALUES ('no-show', 'The user did not show up.');
    
    -- ResourceInstanceStatus (for ResourceInstance physical state)
    -- MVP: Simple binary state - operational or not
    INSERT INTO ResourceInstanceStatus (name, description) VALUES ('available', 'The resource is operational and available for allocation.');
    INSERT INTO ResourceInstanceStatus (name, description) VALUES ('unavailable', 'The resource is not operational (maintenance, damage, retired, etc).');

    -- ResourceCategory (Seat Classes)
    INSERT INTO ResourceCategory (id, name, description) VALUES (ResourceCategory_seq.NEXTVAL, 'Economy Class', 'Standard seating with limited amenities.');
    INSERT INTO ResourceCategory (id, name, description) VALUES (ResourceCategory_seq.NEXTVAL, 'Premium Economy', 'Enhanced comfort and services over Economy.');
    INSERT INTO ResourceCategory (id, name, description) VALUES (ResourceCategory_seq.NEXTVAL, 'Business Class', 'Superior comfort, services, and privacy for business travelers.');
    INSERT INTO ResourceCategory (id, name, description) VALUES (ResourceCategory_seq.NEXTVAL, 'First Class', 'The highest level of luxury, comfort, and service.');
    
    DBMS_OUTPUT.PUT_LINE('Lookup tables populated.');
END;
/

-- -----------------------------------------------------------------------------
-- Step 2: Populate Resource Assets (Aircraft)
-- -----------------------------------------------------------------------------
BEGIN
    DBMS_OUTPUT.PUT_LINE('Populating aircraft (ResourceAsset)...');
    
    INSERT INTO ResourceAsset (id, name, description, status) VALUES (ResourceAsset_seq.NEXTVAL, 'Airbus A380-800', 'Superjumbo - D-AIMA', 'active');
    INSERT INTO ResourceAsset (id, name, description, status) VALUES (ResourceAsset_seq.NEXTVAL, 'Boeing 747-8', 'Queen of the Skies - D-ABYA', 'active');
    INSERT INTO ResourceAsset (id, name, description, status) VALUES (ResourceAsset_seq.NEXTVAL, 'Airbus A350-900', 'XWB - D-AIXN', 'active');
    INSERT INTO ResourceAsset (id, name, description, status) VALUES (ResourceAsset_seq.NEXTVAL, 'Boeing 777-300ER', 'Triple Seven - D-ALFK', 'active');
    INSERT INTO ResourceAsset (id, name, description, status) VALUES (ResourceAsset_seq.NEXTVAL, 'Airbus A330-300', 'Wide-body - D-AIKR', 'active');
    INSERT INTO ResourceAsset (id, name, description, status) VALUES (ResourceAsset_seq.NEXTVAL, 'Airbus A321neo', 'Narrow-body long range - D-AIEA', 'active');
    INSERT INTO ResourceAsset (id, name, description, status) VALUES (ResourceAsset_seq.NEXTVAL, 'Airbus A320-200', 'Workhorse - D-AIZC', 'active');
    INSERT INTO ResourceAsset (id, name, description, status) VALUES (ResourceAsset_seq.NEXTVAL, 'Boeing 737-800', 'Classic - D-ABKA', 'active');
    INSERT INTO ResourceAsset (id, name, description, status) VALUES (ResourceAsset_seq.NEXTVAL, 'Embraer E195', 'Regional Jet - D-AEBJ', 'active');
    INSERT INTO ResourceAsset (id, name, description, status) VALUES (ResourceAsset_seq.NEXTVAL, 'Bombardier CRJ900', 'Regional Jet - D-ACNL', 'active');
    INSERT INTO ResourceAsset (id, name, description, status) VALUES (ResourceAsset_seq.NEXTVAL, 'Airbus A350-900', 'XWB - D-AIXO', 'active');
    INSERT INTO ResourceAsset (id, name, description, status) VALUES (ResourceAsset_seq.NEXTVAL, 'Airbus A320-200', 'Workhorse - D-AIZD', 'active');

    DBMS_OUTPUT.PUT_LINE('Aircraft populated.');
END;
/

-- -----------------------------------------------------------------------------
-- Step 3: Populate Asset Capacities (Aircraft Seating Configurations)
-- -----------------------------------------------------------------------------
DECLARE
    v_asset_id NUMBER;
    v_cat_id_eco NUMBER;
    v_cat_id_pre NUMBER;
    v_cat_id_bus NUMBER;
    v_cat_id_fir NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Populating seat capacities (AssetCapacity)...');

    SELECT id INTO v_cat_id_eco FROM ResourceCategory WHERE name = 'Economy Class';
    SELECT id INTO v_cat_id_pre FROM ResourceCategory WHERE name = 'Premium Economy';
    SELECT id INTO v_cat_id_bus FROM ResourceCategory WHERE name = 'Business Class';
    SELECT id INTO v_cat_id_fir FROM ResourceCategory WHERE name = 'First Class';

    -- A380-800
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A380-800';
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_fir, 8);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_bus, 78);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_pre, 52);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_eco, 371);

    -- B747-8
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Boeing 747-8';
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_fir, 8);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_bus, 80);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_pre, 32);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_eco, 244);
    
    -- A350-900 (D-AIXN)
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A350-900' AND description = 'XWB - D-AIXN';
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_bus, 48);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_pre, 21);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_eco, 224);
    
    -- A350-900 (D-AIXO)
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A350-900' AND description = 'XWB - D-AIXO';
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_bus, 48);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_pre, 21);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_eco, 224);

    -- B777-300ER
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Boeing 777-300ER';
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_bus, 42);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_pre, 28);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_eco, 236);

    -- A330-300
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A330-300';
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_bus, 30);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_pre, 21);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_eco, 203);

    -- A321neo
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A321neo';
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_bus, 28);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_eco, 163);

    -- A320-200 (D-AIZC)
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A320-200' AND description = 'Workhorse - D-AIZC';
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_bus, 24);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_eco, 144);
    
    -- A320-200 (D-AIZD)
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A320-200' AND description = 'Workhorse - D-AIZD';
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_bus, 24);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_eco, 144);

    -- B737-800
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Boeing 737-800';
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_bus, 12);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_eco, 168);

    -- E195
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Embraer E195';
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_bus, 8);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_eco, 108);

    -- CRJ900
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Bombardier CRJ900';
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_bus, 10);
    INSERT INTO AssetCapacity (id, asset_id, category_id, quantity) VALUES (AssetCapacity_seq.NEXTVAL, v_asset_id, v_cat_id_eco, 80);
    
    DBMS_OUTPUT.PUT_LINE('Seat capacities populated.');
END;
/

-- -----------------------------------------------------------------------------
-- Step 4: Populate Users
-- -----------------------------------------------------------------------------
BEGIN
    DBMS_OUTPUT.PUT_LINE('Populating users...');
    -- Generate 200 users
    FOR i IN 1..200 LOOP
        INSERT INTO Users (id, name) VALUES (Users_seq.NEXTVAL, 'Passenger ' || LPAD(i, 3, '0'));
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('200 users populated.');
END;
/

-- -----------------------------------------------------------------------------
-- Step 5: Populate Allocation Contexts (Flights)
-- -----------------------------------------------------------------------------
DECLARE
    v_asset_id NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Populating flights (AllocationContext)...');
    
    -- Long Haul
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A380-800';
    INSERT INTO AllocationContext (id, asset_id, context_identifier, start_date, end_date) VALUES (AllocationContext_seq.NEXTVAL, v_asset_id, 'LH 710 MUC-HND', TO_DATE('2025-10-25 22:10', 'YYYY-MM-DD HH24:MI'), TO_DATE('2025-10-26 17:05', 'YYYY-MM-DD HH24:MI'));
    
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Boeing 747-8';
    INSERT INTO AllocationContext (id, asset_id, context_identifier, start_date, end_date) VALUES (AllocationContext_seq.NEXTVAL, v_asset_id, 'LH 430 FRA-ORD', TO_DATE('2025-11-01 10:45', 'YYYY-MM-DD HH24:MI'), TO_DATE('2025-11-01 13:15', 'YYYY-MM-DD HH24:MI'));
    
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A350-900' AND description = 'XWB - D-AIXN';
    INSERT INTO AllocationContext (id, asset_id, context_identifier, start_date, end_date) VALUES (AllocationContext_seq.NEXTVAL, v_asset_id, 'LH 772 MUC-SIN', TO_DATE('2025-11-05 22:20', 'YYYY-MM-DD HH24:MI'), TO_DATE('2025-11-06 17:20', 'YYYY-MM-DD HH24:MI'));
    
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Boeing 777-300ER';
    INSERT INTO AllocationContext (id, asset_id, context_identifier, start_date, end_date) VALUES (AllocationContext_seq.NEXTVAL, v_asset_id, 'LH 400 FRA-JFK', TO_DATE('2025-11-10 08:20', 'YYYY-MM-DD HH24:MI'), TO_DATE('2025-11-10 11:30', 'YYYY-MM-DD HH24:MI'));

    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A330-300';
    INSERT INTO AllocationContext (id, asset_id, context_identifier, start_date, end_date) VALUES (AllocationContext_seq.NEXTVAL, v_asset_id, 'LH 500 FRA-GIG', TO_DATE('2025-11-12 21:55', 'YYYY-MM-DD HH24:MI'), TO_DATE('2025-11-13 06:50', 'YYYY-MM-DD HH24:MI'));
    
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A350-900' AND description = 'XWB - D-AIXO';
    INSERT INTO AllocationContext (id, asset_id, context_identifier, start_date, end_date) VALUES (AllocationContext_seq.NEXTVAL, v_asset_id, 'LH 726 FRA-PVG', TO_DATE('2025-10-28 17:10', 'YYYY-MM-DD HH24:MI'), TO_DATE('2025-10-29 09:55', 'YYYY-MM-DD HH24:MI'));

    -- Short/Medium Haul
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A321neo';
    INSERT INTO AllocationContext (id, asset_id, context_identifier, start_date, end_date) VALUES (AllocationContext_seq.NEXTVAL, v_asset_id, 'LH 1840 MUC-MAD', TO_DATE('2025-10-15 09:00', 'YYYY-MM-DD HH24:MI'), TO_DATE('2025-10-15 11:45', 'YYYY-MM-DD HH24:MI'));
    
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A320-200' AND description = 'Workhorse - D-AIZC';
    INSERT INTO AllocationContext (id, asset_id, context_identifier, start_date, end_date) VALUES (AllocationContext_seq.NEXTVAL, v_asset_id, 'LH 2474 MUC-LHR', TO_DATE('2025-10-20 07:15', 'YYYY-MM-DD HH24:MI'), TO_DATE('2025-10-20 08:25', 'YYYY-MM-DD HH24:MI'));
    
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Airbus A320-200' AND description = 'Workhorse - D-AIZD';
    INSERT INTO AllocationContext (id, asset_id, context_identifier, start_date, end_date) VALUES (AllocationContext_seq.NEXTVAL, v_asset_id, 'LH 2475 LHR-MUC', TO_DATE('2025-10-20 09:30', 'YYYY-MM-DD HH24:MI'), TO_DATE('2025-10-20 12:30', 'YYYY-MM-DD HH24:MI'));

    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Boeing 737-800';
    INSERT INTO AllocationContext (id, asset_id, context_identifier, start_date, end_date) VALUES (AllocationContext_seq.NEXTVAL, v_asset_id, 'LH 321 FRA-FCO', TO_DATE('2025-11-18 14:00', 'YYYY-MM-DD HH24:MI'), TO_DATE('2025-11-18 15:55', 'YYYY-MM-DD HH24:MI'));

    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Embraer E195';
    INSERT INTO AllocationContext (id, asset_id, context_identifier, start_date, end_date) VALUES (AllocationContext_seq.NEXTVAL, v_asset_id, 'LH 2202 MUC-LUX', TO_DATE('2025-11-22 18:05', 'YYYY-MM-DD HH24:MI'), TO_DATE('2025-11-22 19:15', 'YYYY-MM-DD HH24:MI'));

    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'Bombardier CRJ900';
    INSERT INTO AllocationContext (id, asset_id, context_identifier, start_date, end_date) VALUES (AllocationContext_seq.NEXTVAL, v_asset_id, 'LH 1100 FRA-STR', TO_DATE('2025-11-25 20:50', 'YYYY-MM-DD HH24:MI'), TO_DATE('2025-11-25 21:30', 'YYYY-MM-DD HH24:MI'));
    
    DBMS_OUTPUT.PUT_LINE('Flights populated.');
END;
/

-- -----------------------------------------------------------------------------
-- Step 5.5: Initialize Capacity Snapshots for All Flights
-- -----------------------------------------------------------------------------
DECLARE
    v_flight_count NUMBER := 0;
    v_package_exists NUMBER;
BEGIN
    -- Verify ResourceManagement package exists
    SELECT COUNT(*) INTO v_package_exists
    FROM user_objects
    WHERE object_type = 'PACKAGE'
      AND object_name = 'RESOURCEMANAGEMENT';
    
    IF v_package_exists = 0 THEN
        RAISE_APPLICATION_ERROR(-20999, 
            'ResourceManagement package not found. Please run @sql/2.1_database_specification.pks and @sql/2.2_database_body.pkb first.');
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('Initializing capacity snapshots for all flights...');
    
    -- Initialize capacity snapshot for each flight
    -- This creates real-time capacity tracking for availability queries
    FOR flight_rec IN (SELECT id, context_identifier FROM AllocationContext) LOOP
        BEGIN
            ResourceManagement.InitializeCapacityForContext(flight_rec.id);
            v_flight_count := v_flight_count + 1;
            DBMS_OUTPUT.PUT_LINE('  ✓ Initialized capacity for: ' || flight_rec.context_identifier);
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  ✗ Error initializing ' || flight_rec.context_identifier || ': ' || SQLERRM);
                RAISE;
        END;
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('Capacity snapshots initialized for ' || v_flight_count || ' flights.');
END;
/

-- -----------------------------------------------------------------------------
-- Step 6: Populate Resource Instances (Individual Seats)
-- -----------------------------------------------------------------------------
DECLARE
    v_asset_id NUMBER;
    v_cat_id_eco NUMBER;
    v_cat_id_pre NUMBER;
    v_cat_id_bus NUMBER;
    v_cat_id_fir NUMBER;
    v_instance_count NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Populating resource instances (individual seats)...');

    SELECT id INTO v_cat_id_eco FROM ResourceCategory WHERE name = 'Economy Class';
    SELECT id INTO v_cat_id_pre FROM ResourceCategory WHERE name = 'Premium Economy';
    SELECT id INTO v_cat_id_bus FROM ResourceCategory WHERE name = 'Business Class';
    SELECT id INTO v_cat_id_fir FROM ResourceCategory WHERE name = 'First Class';

    -- Create individual seats for each asset based on their capacity
    FOR asset_rec IN (SELECT id, name FROM ResourceAsset WHERE status = 'active') LOOP
        v_asset_id := asset_rec.id;
        
        -- Create seats for each category this asset has
        FOR cap_rec IN (SELECT category_id, quantity FROM AssetCapacity WHERE asset_id = v_asset_id) LOOP
            v_instance_count := 0;
            
            -- Create individual seat instances
            FOR i IN 1..cap_rec.quantity LOOP
                v_instance_count := v_instance_count + 1;
                
                -- Generate seat identifier based on category
                DECLARE
                    v_seat_identifier VARCHAR2(10);
                    v_row_num NUMBER;
                    v_seat_letter CHAR(1);
                BEGIN
                    -- Simple seat naming: 1A, 1B, 1C, 2A, 2B, etc.
                    v_row_num := CEIL(v_instance_count / 6);
                    v_seat_letter := SUBSTR('ABCDEF', MOD(v_instance_count - 1, 6) + 1, 1);
                    v_seat_identifier := TO_CHAR(v_row_num) || v_seat_letter;
                    
                    INSERT INTO ResourceInstance (id, asset_id, category_id, instance_identifier, status)
                    VALUES (ResourceInstance_seq.NEXTVAL, v_asset_id, cap_rec.category_id, v_seat_identifier, 'available');
                EXCEPTION
                    WHEN OTHERS THEN
                        -- Ignore duplicate seat identifiers (can happen with multiple categories)
                        NULL;
                END;
            END LOOP;
        END LOOP;
        
        DBMS_OUTPUT.PUT_LINE('  Created ' || v_instance_count || ' seats for ' || asset_rec.name);
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('Resource instances populated.');
END;
/

-- -----------------------------------------------------------------------------
-- Step 6.5: Mark Some Seats as Unavailable (with metadata explaining why)
-- -----------------------------------------------------------------------------
DECLARE
    v_seat_id NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Marking some seats as unavailable...');
    
    -- Example 1: Seat under maintenance
    SELECT id INTO v_seat_id 
    FROM ResourceInstance 
    WHERE instance_identifier = '10A' 
      AND asset_id = (SELECT MIN(id) FROM ResourceAsset WHERE name = 'Airbus A380-800')
      AND ROWNUM = 1;
    
    UPDATE ResourceInstance 
    SET status = 'unavailable',
        metadata = '{"reason": "maintenance", "type": "scheduled", "issue": "seat_mechanism", "until": "2025-12-01", "notes": "Reclining mechanism needs replacement"}'
    WHERE id = v_seat_id;
    
    -- Example 2: Seat blocked due to damage
    SELECT id INTO v_seat_id 
    FROM ResourceInstance 
    WHERE instance_identifier = '15C' 
      AND asset_id = (SELECT MIN(id) FROM ResourceAsset WHERE name = 'Boeing 747-8')
      AND ROWNUM = 1;
    
    UPDATE ResourceInstance 
    SET status = 'unavailable',
        metadata = '{"reason": "blocked", "type": "damage", "issue": "tray_table_broken", "reported_date": "2025-10-15", "reported_by": "Crew"}'
    WHERE id = v_seat_id;
    
    -- Example 3: Permanently retired seat
    SELECT id INTO v_seat_id 
    FROM ResourceInstance 
    WHERE instance_identifier = '8B' 
      AND asset_id = (SELECT MIN(id) FROM ResourceAsset WHERE name = 'Airbus A350-900')
      AND ROWNUM = 1;
    
    UPDATE ResourceInstance 
    SET status = 'unavailable',
        metadata = '{"reason": "retired", "type": "permanent", "date": "2025-09-01", "notes": "Reconfiguration - seat removed for crew rest area"}'
    WHERE id = v_seat_id;
    
    DBMS_OUTPUT.PUT_LINE('3 seats marked as unavailable with metadata.');
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('Warning: Could not find seats to mark as unavailable. Skipping.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error marking seats unavailable: ' || SQLERRM);
END;
/

-- -----------------------------------------------------------------------------
-- Step 7: Populate Allocation Journal (Reservations and Cancellations)
-- -----------------------------------------------------------------------------
DECLARE
    CURSOR c_flights IS SELECT id, context_identifier, asset_id FROM AllocationContext;
    CURSOR c_users IS SELECT id FROM Users;
    
    v_context_id NUMBER;
    v_asset_id NUMBER;
    v_context_identifier VARCHAR2(100);
    v_user_id NUMBER;
    v_category_id NUMBER;
    v_num_reservations NUMBER;
    v_num_cancellations NUMBER;
    v_journal_date TIMESTAMP;
    v_resource_instance_id NUMBER;

    TYPE user_id_table IS TABLE OF Users.id%TYPE;
    TYPE instance_id_table IS TABLE OF NUMBER;
    all_user_ids user_id_table;
    available_instances instance_id_table;

BEGIN
    DBMS_OUTPUT.PUT_LINE('Populating booking journal...');
    
    -- Load all user IDs into a collection for faster access
    OPEN c_users;
    FETCH c_users BULK COLLECT INTO all_user_ids;
    CLOSE c_users;

    -- Loop through each flight
    FOR flight_rec IN c_flights LOOP
        v_context_id := flight_rec.id;
        v_asset_id := flight_rec.asset_id;
        v_context_identifier := flight_rec.context_identifier;
        
        DBMS_OUTPUT.PUT_LINE(' > Processing flight: ' || v_context_identifier);

        -- Loop through each seat category for the current flight
        FOR cat IN (
            SELECT category_id, COUNT(*) as total_seats
            FROM ResourceInstance
            WHERE asset_id = v_asset_id
            GROUP BY category_id
        )
        LOOP
            v_category_id := cat.category_id;
            
            -- Get available instances for this category
            SELECT id BULK COLLECT INTO available_instances
            FROM ResourceInstance
            WHERE asset_id = v_asset_id
              AND category_id = v_category_id
            ORDER BY DBMS_RANDOM.VALUE;
            
            -- Decide a random load factor (70% to 95%)
            v_num_reservations := TRUNC(available_instances.COUNT * (0.7 + (DBMS_RANDOM.VALUE * 0.25)));

            -- Make reservations using actual resource instances
            FOR i IN 1..LEAST(v_num_reservations, available_instances.COUNT) LOOP
                -- Pick a random user
                v_user_id := all_user_ids(TRUNC(DBMS_RANDOM.VALUE(1, all_user_ids.COUNT)) + 1);
                -- Pick a random date in September 2025
                v_journal_date := TO_TIMESTAMP('2025-09-01 00:00:00', 'YYYY-MM-DD HH24:MI:SS') + 
                                  NUMTODSINTERVAL(TRUNC(DBMS_RANDOM.VALUE(0, 28*24*60*60)), 'SECOND');

                -- Insert with specific resource instance
                INSERT INTO AllocationJournal(id, context_id, category_id, user_id, resource_instance_id, status, entry_timestamp)
                VALUES (AllocationJournal_seq.NEXTVAL, v_context_id, v_category_id, v_user_id, 
                        available_instances(i), 'confirmed', v_journal_date);
            END LOOP;

            -- Add some cancellations (approx 5% of bookings)
            v_num_cancellations := TRUNC(v_num_reservations * 0.05);
            FOR i IN 1..v_num_cancellations LOOP
                -- Find a random confirmed booking to cancel
                BEGIN
                    SELECT user_id, resource_instance_id INTO v_user_id, v_resource_instance_id
                    FROM (
                        SELECT user_id, resource_instance_id
                        FROM CurrentAllocations
                        WHERE context_id = v_context_id 
                          AND category_id = v_category_id 
                          AND status = 'confirmed'
                        ORDER BY DBMS_RANDOM.VALUE
                    ) WHERE ROWNUM = 1;
                    
                    v_journal_date := TO_TIMESTAMP('2025-09-15 00:00:00', 'YYYY-MM-DD HH24:MI:SS') + 
                                      NUMTODSINTERVAL(TRUNC(DBMS_RANDOM.VALUE(0, 14*24*60*60)), 'SECOND');

                    -- Create cancellation entry (immutable journal - new entry, not update)
                    INSERT INTO AllocationJournal(id, context_id, category_id, user_id, resource_instance_id, status, entry_timestamp)
                    VALUES (AllocationJournal_seq.NEXTVAL, v_context_id, v_category_id, v_user_id, 
                            v_resource_instance_id, 'cancelled', v_journal_date);

                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        NULL; -- No booking to cancel, just skip
                END;
            END LOOP;

        END LOOP; -- end category loop
    END LOOP; -- end flight loop
    
    DBMS_OUTPUT.PUT_LINE('Booking journal populated.');
END;
/

-- -----------------------------------------------------------------------------
-- Step 7.5: Reconcile Capacity Snapshots
-- -----------------------------------------------------------------------------
DECLARE
    v_reconcile_count NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Reconciling capacity snapshots with journal data...');
    DBMS_OUTPUT.PUT_LINE('  (This is necessary because we directly inserted into AllocationJournal');
    DBMS_OUTPUT.PUT_LINE('   bypassing the normal reservation procedures that update capacity counters)');
    
    -- Reconcile recalculates capacity counters from the AllocationJournal
    -- to ensure capacity records accurately reflect the current state
    FOR capacity_rec IN (
        SELECT DISTINCT cs.context_id, cs.category_id, ac.context_identifier
        FROM Capacity cs
        JOIN AllocationContext ac ON cs.context_id = ac.id
    ) LOOP
        BEGIN
            ResourceManagement.ReconcileCapacity(
                p_context_id => capacity_rec.context_id,
                p_category_id => capacity_rec.category_id
            );
            v_reconcile_count := v_reconcile_count + 1;
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  ✗ Error reconciling ' || capacity_rec.context_identifier || ': ' || SQLERRM);
                RAISE;
        END;
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('✓ Reconciled ' || v_reconcile_count || ' capacity records.');
END;
/

-- Verify capacity accuracy
DECLARE
    v_total_capacity_records NUMBER;
    v_total_discrepancies NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Verifying capacity record accuracy...');
    
    SELECT COUNT(*) INTO v_total_capacity_records FROM Capacity;
    
    -- Check for any discrepancies
    FOR check_rec IN (
        SELECT 
            ac.context_identifier,
            rc.name as category,
            cs.available_count,
            cs.reserved_count,
            cs.confirmed_count,
            cs.total_capacity
        FROM Capacity cs
        JOIN AllocationContext ac ON cs.context_id = ac.id
        JOIN ResourceCategory rc ON cs.category_id = rc.id
        WHERE cs.available_count + cs.reserved_count + cs.confirmed_count + 
              cs.checked_in_count + cs.boarded_count > cs.total_capacity
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('  ⚠ Discrepancy found: ' || check_rec.context_identifier || 
                             ' - ' || check_rec.category);
        v_total_discrepancies := v_total_discrepancies + 1;
    END LOOP;
    
    IF v_total_discrepancies = 0 THEN
        DBMS_OUTPUT.PUT_LINE('✓ All ' || v_total_capacity_records || ' capacity records verified - no discrepancies found.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('⚠ Found ' || v_total_discrepancies || ' discrepancies. Please investigate.');
    END IF;
END;
/

-- -----------------------------------------------------------------------------
-- Final Commit
-- -----------------------------------------------------------------------------
COMMIT;

-- -----------------------------------------------------------------------------
-- Summary Statistics
-- -----------------------------------------------------------------------------
DECLARE
    v_count NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=========================================================================');
    DBMS_OUTPUT.PUT_LINE('MOCK DATA INSERTION SUMMARY');
    DBMS_OUTPUT.PUT_LINE('=========================================================================');
    DBMS_OUTPUT.PUT_LINE('');
    
    -- Aircraft
    SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE status = 'active';
    DBMS_OUTPUT.PUT_LINE('Aircraft (Active):           ' || LPAD(v_count, 6));
    
    -- Categories
    SELECT COUNT(*) INTO v_count FROM ResourceCategory;
    DBMS_OUTPUT.PUT_LINE('Seat Categories:             ' || LPAD(v_count, 6));
    
    -- Total Seats
    SELECT COUNT(*) INTO v_count FROM ResourceInstance;
    DBMS_OUTPUT.PUT_LINE('Total Seats (Instances):     ' || LPAD(v_count, 6));
    
    -- Available vs Unavailable Seats
    SELECT COUNT(*) INTO v_count FROM ResourceInstance WHERE status = 'available';
    DBMS_OUTPUT.PUT_LINE('  - Available:               ' || LPAD(v_count, 6));
    SELECT COUNT(*) INTO v_count FROM ResourceInstance WHERE status = 'unavailable';
    DBMS_OUTPUT.PUT_LINE('  - Unavailable:             ' || LPAD(v_count, 6));
    
    -- Users
    SELECT COUNT(*) INTO v_count FROM Users;
    DBMS_OUTPUT.PUT_LINE('Users:                       ' || LPAD(v_count, 6));
    
    -- Flights
    SELECT COUNT(*) INTO v_count FROM AllocationContext;
    DBMS_OUTPUT.PUT_LINE('Flights Scheduled:           ' || LPAD(v_count, 6));
    
    -- Capacity Records
    SELECT COUNT(*) INTO v_count FROM Capacity;
    DBMS_OUTPUT.PUT_LINE('Capacity Records:            ' || LPAD(v_count, 6));
    
    -- Reservations
    SELECT COUNT(*) INTO v_count FROM AllocationJournal WHERE status = 'confirmed';
    DBMS_OUTPUT.PUT_LINE('Reservations (Confirmed):    ' || LPAD(v_count, 6));
    
    SELECT COUNT(*) INTO v_count FROM AllocationJournal WHERE status = 'cancelled';
    DBMS_OUTPUT.PUT_LINE('Reservations (Cancelled):    ' || LPAD(v_count, 6));
    
    SELECT COUNT(DISTINCT user_id) INTO v_count FROM AllocationJournal;
    DBMS_OUTPUT.PUT_LINE('Unique Passengers:           ' || LPAD(v_count, 6));
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=========================================================================');
    DBMS_OUTPUT.PUT_LINE('✓ MOCK DATA INSERTION COMPLETE');
    DBMS_OUTPUT.PUT_LINE('=========================================================================');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Next Steps:');
    DBMS_OUTPUT.PUT_LINE('  1. Verify data: SELECT * FROM Capacity;');
    DBMS_OUTPUT.PUT_LINE('  2. Run tests: @TESTS/TEST_MakeReservationWithTimeout.sql');
    DBMS_OUTPUT.PUT_LINE('  3. Check capacity: SELECT * FROM CurrentAllocations;');
    DBMS_OUTPUT.PUT_LINE('  4. View flight manifest: SELECT * FROM AllocationHistory;');
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- -----------------------------------------------------------------------------
-- Sample Data Preview
-- -----------------------------------------------------------------------------
PROMPT
PROMPT =========================================================================
PROMPT SAMPLE DATA PREVIEW
PROMPT =========================================================================
PROMPT
PROMPT Capacity Sample (First 10 Flight/Category Combinations):

SELECT ac.context_identifier as flight, rc.name as category, cs.total_capacity, cs.available_count, cs.reserved_count, cs.confirmed_count, cs.cancelled_count FROM Capacity cs JOIN AllocationContext ac ON cs.context_id = ac.id JOIN ResourceCategory rc ON cs.category_id = rc.id ORDER BY ac.context_identifier, rc.name FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT Current Allocations Sample:

SELECT ac.context_identifier as flight, u.name as passenger, rc.name as category, ri.instance_identifier as seat, aj.status FROM CurrentAllocations ca JOIN AllocationJournal aj ON ca.journal_id = aj.id JOIN AllocationContext ac ON ca.context_id = ac.id JOIN Users u ON ca.user_id = u.id JOIN ResourceCategory rc ON ca.category_id = rc.id LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id ORDER BY ac.context_identifier, ri.instance_identifier FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT =========================================================================
PROMPT Mock data ready for testing!
PROMPT =========================================================================
