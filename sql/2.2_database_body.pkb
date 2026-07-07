-- =============================================================================
-- 2_database_body.pkb
--
-- BUSINESS LOGIC LAYER - Package Body
-- ====================================
-- Implements ResourceManagement package. Uses ResourceManagement_Data for
-- table access. Patterns: journal-based state, RESERVABLE counters, saga
-- compensation, autonomous journal writes, AQ-driven timeouts.
-- =============================================================================

CREATE OR REPLACE PACKAGE BODY ResourceManagement AS

  --==============================================================================
  -- Private helpers (used by other procedures in this package)
  --==============================================================================
  PROCEDURE LogDebugMessage(p_message IN VARCHAR2) IS
    -- Logs a debug message to the DebugLog table with timestamp for troubleshooting and audit trails.
  BEGIN
    ResourceManagement_Data.LogDebugMessage(p_message);
  END LogDebugMessage;

  -- Helper function to get allocation mode for a category
  FUNCTION GetAllocationModeForCategory(p_category_id IN NUMBER) RETURN VARCHAR2 IS
    v_mode VARCHAR2(10);
  BEGIN
    SELECT allocation_mode INTO v_mode
    FROM ResourceCategory
    WHERE id = p_category_id;
    RETURN v_mode;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 'pool'; -- Default for backward compatibility
  END GetAllocationModeForCategory;

  -- Helper: compensate an autonomous journal entry without touching capacity.
  -- Called when the main transaction must be rolled back after journal entries
  -- were already committed by AddAllocationJournal (autonomous).
  -- The capacity counter is undone by ROLLBACK TO SAVEPOINT (escrow); this
  -- procedure only reverts the journal + ActiveAllocation state.
  --
  -- NOTE on RESERVABLE columns: Capacity errors from RESERVABLE column updates
  -- surface at COMMIT time, not during the UPDATE statement. Therefore, this
  -- compensation is primarily triggered by ActiveAllocation conflicts (-20910)
  -- which DO fire inside the procedure (from AddAllocationJournal's autonomous
  -- transaction). Other compensation handlers (WHEN OTHERS) exist as defensive
  -- programming for unexpected non-capacity errors.
  PROCEDURE CompensateJournalEntry(
    p_journal_id    IN NUMBER,
    p_revert_status IN VARCHAR2,
    p_reason        IN VARCHAR2
  ) IS
    v_context_id           NUMBER;
    v_category_id          NUMBER;
    v_user_id              NUMBER;
    v_resource_instance_id NUMBER;
    v_compensation_id      NUMBER;
  BEGIN
    -- Read the original (already-committed) journal entry
    SELECT context_id, category_id, user_id, resource_instance_id
    INTO v_context_id, v_category_id, v_user_id, v_resource_instance_id
    FROM AllocationJournal
    WHERE id = p_journal_id;

    -- Create compensation entry (autonomous - reverts journal + ActiveAllocation)
    ResourceManagement_Data.AddAllocationJournal(
      p_context_id           => v_context_id,
      p_category_id          => v_category_id,
      p_user_id              => v_user_id,
      p_resource_instance_id => v_resource_instance_id,
      p_status               => p_revert_status,
      p_metadata             => JSON_OBJECT(
                                  'compensation_reason' VALUE p_reason,
                                  'original_journal_id' VALUE p_journal_id
                                ),
      p_journal_id           => v_compensation_id
    );

    LogDebugMessage('COMPENSATION: journal ' || p_journal_id ||
                    ' -> ' || p_revert_status || ' (id=' || v_compensation_id ||
                    ', reason=' || p_reason || ')');
  EXCEPTION
    WHEN OTHERS THEN
      -- Compensation itself failed - log but do NOT re-raise
      -- (we are already inside an exception handler; losing this would mask the original error)
      LogDebugMessage('COMPENSATION WARNING: failed to compensate journal ' ||
                      p_journal_id || ': ' || SQLERRM);
  END CompensateJournalEntry;

  -- Helper: reserve one batch of seats for a category with substitution metadata (used by MakeReservationWithAlternative)
  -- On failure: caller is responsible for ROLLBACK TO savepoint; this helper compensates
  -- all journal entries it committed during THIS call via CompensateJournalEntry.
  FUNCTION reserve_offer_batch(
    p_context_id             NUMBER,
    p_asset_id               NUMBER,
    p_from_category_id       NUMBER,
    p_to_category_id         NUMBER,
    p_from_name              VARCHAR2,
    p_to_name                VARCHAR2,
    p_user_id                NUMBER,
    p_offer_group_id         VARCHAR2,
    p_quantity               NUMBER,
    p_offer_journal_ids IN OUT SYS.ODCINUMBERLIST,
    p_offer_timeout_minutes  NUMBER
  ) RETURN NUMBER IS
    v_available_instances SYS.ODCINUMBERLIST;
    v_offer_metadata     CLOB;
    v_new_id             NUMBER;
    -- Track journal IDs committed in THIS call for compensation on failure
    v_batch_start_idx    NUMBER;
  BEGIN
    IF p_quantity <= 0 THEN RETURN 0; END IF;

    v_batch_start_idx := p_offer_journal_ids.COUNT + 1;

    SELECT ri.id BULK COLLECT INTO v_available_instances
    FROM ResourceInstance ri
    WHERE ri.asset_id = p_asset_id
      AND ri.category_id = p_to_category_id
      AND ri.status = 'available'
      AND NOT EXISTS (
        SELECT 1 FROM CurrentAllocations ca
        WHERE ca.resource_instance_id = ri.id AND ca.context_id = p_context_id
          AND ca.status IN ('reserved', 'confirmed', 'checked-in', 'boarded')
      )
      AND ROWNUM <= p_quantity;

    FOR i IN 1..v_available_instances.COUNT LOOP
      v_offer_metadata := JSON_OBJECT(
        'substitution' VALUE 'true',
        'offer_group_id' VALUE p_offer_group_id,
        'user_id' VALUE p_user_id,
        'from_category_id' VALUE p_from_category_id,
        'to_category_id' VALUE p_to_category_id,
        'from_category_name' VALUE p_from_name,
        'to_category_name' VALUE p_to_name
      );
      ResourceManagement_Data.AddAllocationJournal(
        p_context_id => p_context_id,
        p_category_id => p_to_category_id,
        p_user_id => p_user_id,
        p_resource_instance_id => v_available_instances(i),
        p_status => 'reserved',
        p_metadata => v_offer_metadata,
        p_journal_id => v_new_id
      );
      p_offer_journal_ids.EXTEND;
      p_offer_journal_ids(p_offer_journal_ids.COUNT) := v_new_id;

      ResourceManagement_Data.IncrementCapacityCounter(
        p_context_id => p_context_id,
        p_category_id => p_to_category_id,
        p_active_delta => 1
      );
    END LOOP;

    RETURN v_available_instances.COUNT;
  EXCEPTION
    WHEN OTHERS THEN
      -- Compensate all journal entries committed in THIS batch call
      FOR j IN v_batch_start_idx..p_offer_journal_ids.COUNT LOOP
        CompensateJournalEntry(p_offer_journal_ids(j), 'cancelled', 'offer_batch_failed: ' || SQLERRM);
      END LOOP;
      RAISE;
  END reserve_offer_batch;

  --==============================================================================
  -- Availability and capacity
  --==============================================================================
  PROCEDURE InitializeCapacityForContext(p_context_id IN NUMBER) IS
    -- Creates Capacity records for all categories of an allocation context (flight).
    -- Called automatically when a new AllocationContext is created.
    -- Uses lock-free RESERVABLE columns for high-concurrency counter updates.
    v_asset_id NUMBER;
  BEGIN
    SELECT asset_id INTO v_asset_id FROM AllocationContext WHERE id = p_context_id;
    
    -- Initialize capacity records for all categories of this asset
    FOR cap_rec IN (
      SELECT category_id, quantity 
      FROM AssetCapacity 
      WHERE asset_id = v_asset_id
    ) LOOP
      INSERT INTO Capacity(
        id, context_id, category_id, total_capacity, 
        active_count
      )
      VALUES (
        Capacity_seq.NEXTVAL, p_context_id, cap_rec.category_id, cap_rec.quantity,
        0
      );
    END LOOP;
    
    LogDebugMessage('Initialized capacity for context ID: ' || p_context_id);
  END InitializeCapacityForContext;

  FUNCTION GetCapacityReport(p_context_identifier IN VARCHAR2) RETURN SYS_REFCURSOR IS
    -- Returns a detailed capacity report for a flight showing total, available, and allocated seats by category.
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR
      SELECT 
        ac.context_identifier,
        rc.name as category_name,
        cs.total_capacity,
        (cs.total_capacity - cs.active_count) AS available_count,
        cs.active_count,
        cs.last_updated
      FROM Capacity cs
      JOIN AllocationContext ac ON cs.context_id = ac.id
      JOIN ResourceCategory rc ON cs.category_id = rc.id
      WHERE ac.context_identifier = p_context_identifier
      ORDER BY rc.name;
    RETURN rc;
  END GetCapacityReport;

  --==============================================================================
  -- Asset and context setup
  --==============================================================================
  PROCEDURE ValidateAssetCapacity(p_asset_id IN NUMBER) IS
    -- Validates that the number of ResourceInstance records matches the declared AssetCapacity quantities.
    -- Raises an error if there's a mismatch between declared capacity and actual instance count.
    v_asset_name VARCHAR2(50);
    v_category_name VARCHAR2(50);
    v_expected_count NUMBER;
    v_actual_count NUMBER;
    v_has_errors BOOLEAN := FALSE;
    v_error_messages VARCHAR2(4000) := '';
  BEGIN
    LogDebugMessage('Validating asset capacity for asset ID: ' || p_asset_id);
    
    -- Get asset name for error messages
    SELECT name INTO v_asset_name FROM ResourceAsset WHERE id = p_asset_id;
    
    -- Check each capacity
    FOR cap IN (
      SELECT ac.category_id, ac.quantity, rc.name as category_name
      FROM AssetCapacity ac
      JOIN ResourceCategory rc ON ac.category_id = rc.id
      WHERE ac.asset_id = p_asset_id
    ) LOOP
      -- Count actual instances
      SELECT COUNT(*) INTO v_actual_count
      FROM ResourceInstance
      WHERE asset_id = p_asset_id AND category_id = cap.category_id;
      
      IF v_actual_count != cap.quantity THEN
        v_has_errors := TRUE;
        v_error_messages := v_error_messages || 
          'Category "' || cap.category_name || '": Expected ' || cap.quantity || 
          ' seats, found ' || v_actual_count || ' seats. ';
        
        LogDebugMessage('Validation FAILED for asset ' || v_asset_name || ', category ' || cap.category_name || 
                       ': Expected ' || cap.quantity || ', Found ' || v_actual_count);
      ELSE
        LogDebugMessage('Validation OK for category ' || cap.category_name || ': ' || v_actual_count || ' seats');
      END IF;
    END LOOP;
    
    IF v_has_errors THEN
      RAISE_APPLICATION_ERROR(-20200, 
        'Asset capacity validation failed for "' || v_asset_name || '": ' || v_error_messages);
    ELSE
      LogDebugMessage('Asset capacity validation PASSED for asset ID: ' || p_asset_id);
    END IF;
  END ValidateAssetCapacity;

  PROCEDURE AddCompleteAssetFromJSON(p_json_data IN CLOB, p_new_asset_id OUT NUMBER) IS
    -- Creates a complete aircraft asset from JSON including the asset, all capacity definitions, and resource instances.
    -- All operations are atomic using savepoints - full rollback on any validation failure.
    v_json_obj JSON_OBJECT_T;
    v_asset_obj JSON_OBJECT_T;
    v_capacities_arr JSON_ARRAY_T;
    v_instances_arr JSON_ARRAY_T;
    v_capacity_obj JSON_OBJECT_T;
    v_instance_obj JSON_OBJECT_T;
    v_seats_arr JSON_ARRAY_T;
    v_seat_obj JSON_OBJECT_T;
    
    v_asset_name VARCHAR2(50);
    v_asset_description VARCHAR2(200);
    v_asset_status VARCHAR2(20);
    v_asset_metadata CLOB;
    
    v_category_name VARCHAR2(50);
    v_category_id NUMBER;
    v_quantity NUMBER;
    v_capacity_metadata CLOB;
    
    v_instance_identifier VARCHAR2(50);
    v_instance_status VARCHAR2(20);
    v_instance_metadata CLOB;
    
    v_total_instances_created NUMBER := 0;
    v_total_capacities_created NUMBER := 0;
  BEGIN
    SAVEPOINT before_asset_creation;
    
    LogDebugMessage('=== Starting AddCompleteAssetFromJSON ===');
    
    BEGIN
      -- Parse JSON
      v_json_obj := JSON_OBJECT_T.parse(p_json_data);
      
      -- Step 1: Create Asset
      LogDebugMessage('Step 1: Creating asset...');
      v_asset_obj := v_json_obj.get_object('asset');
      v_asset_name := v_asset_obj.get_string('name');
      v_asset_description := v_asset_obj.get_string('description');
      v_asset_status := v_asset_obj.get_string('status');
      
      IF v_asset_obj.has('metadata') THEN
        v_asset_metadata := v_asset_obj.get_object('metadata').to_clob();
      ELSE
        v_asset_metadata := NULL;
      END IF;
      
      ResourceManagement_Data.AddResourceAsset(
        p_name => v_asset_name,
        p_description => v_asset_description,
        p_status => v_asset_status,
        p_metadata => v_asset_metadata
      );
      
      -- Get the newly created asset ID
      SELECT id INTO p_new_asset_id 
      FROM ResourceAsset 
      WHERE name = v_asset_name AND description = v_asset_description;
      
      LogDebugMessage('Asset created with ID: ' || p_new_asset_id);
      
      -- Step 2: Create Capacities
      LogDebugMessage('Step 2: Creating asset capacities...');
      v_capacities_arr := v_json_obj.get_array('capacities');
      
      FOR i IN 0 .. v_capacities_arr.get_size() - 1 LOOP
        v_capacity_obj := JSON_OBJECT_T(v_capacities_arr.get(i));
        v_category_name := v_capacity_obj.get_string('category_name');
        v_quantity := v_capacity_obj.get_number('quantity');
        
        IF v_capacity_obj.has('metadata') THEN
          v_capacity_metadata := v_capacity_obj.get_object('metadata').to_clob();
        ELSE
          v_capacity_metadata := NULL;
        END IF;
        
        -- Get category ID
        SELECT id INTO v_category_id 
        FROM ResourceCategory 
        WHERE name = v_category_name;
        
        ResourceManagement_Data.AddAssetCapacity(
          p_asset_id => p_new_asset_id,
          p_category_id => v_category_id,
          p_quantity => v_quantity,
          p_metadata => v_capacity_metadata
        );
        
        v_total_capacities_created := v_total_capacities_created + 1;
        LogDebugMessage('  Created capacity for ' || v_category_name || ': ' || v_quantity || ' seats');
      END LOOP;
      
      LogDebugMessage('Created ' || v_total_capacities_created || ' capacity records');
      
      -- Step 3: Create Resource Instances (Seats)
      LogDebugMessage('Step 3: Creating resource instances...');
      v_instances_arr := v_json_obj.get_array('instances');
      
      FOR i IN 0 .. v_instances_arr.get_size() - 1 LOOP
        v_instance_obj := JSON_OBJECT_T(v_instances_arr.get(i));
        v_category_name := v_instance_obj.get_string('category_name');
        
        -- Get category ID
        SELECT id INTO v_category_id 
        FROM ResourceCategory 
        WHERE name = v_category_name;
        
        -- Process seats array
        v_seats_arr := v_instance_obj.get_array('seats');
        
        FOR j IN 0 .. v_seats_arr.get_size() - 1 LOOP
          v_seat_obj := JSON_OBJECT_T(v_seats_arr.get(j));
          v_instance_identifier := v_seat_obj.get_string('identifier');
          v_instance_status := v_seat_obj.get_string('status');
          
          IF v_seat_obj.has('metadata') THEN
            v_instance_metadata := v_seat_obj.get_object('metadata').to_clob();
          ELSE
            v_instance_metadata := NULL;
          END IF;
          
          ResourceManagement_Data.AddResourceInstance(
            p_asset_id => p_new_asset_id,
            p_category_id => v_category_id,
            p_instance_identifier => v_instance_identifier,
            p_status => v_instance_status,
            p_metadata => v_instance_metadata
          );
          
          v_total_instances_created := v_total_instances_created + 1;
        END LOOP;
        
        LogDebugMessage('  Created ' || v_seats_arr.get_size() || ' instances for ' || v_category_name);
      END LOOP;
      
      LogDebugMessage('Created ' || v_total_instances_created || ' total instances');
      
      -- Step 4: Validate
      LogDebugMessage('Step 4: Validating asset capacity...');
      ValidateAssetCapacity(p_new_asset_id);
      
      -- Success!
      LogDebugMessage('=== Asset creation SUCCESSFUL ===');
      LogDebugMessage('Asset ID: ' || p_new_asset_id || ', Name: ' || v_asset_name);
      LogDebugMessage('Capacities: ' || v_total_capacities_created || ', Instances: ' || v_total_instances_created);
      
      --COMMIT;
      
    EXCEPTION
      WHEN OTHERS THEN
        ROLLBACK TO before_asset_creation;
        LogDebugMessage('=== Asset creation FAILED ===');
        LogDebugMessage('Error: ' || SQLERRM);
        LogDebugMessage('Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        RAISE_APPLICATION_ERROR(-20201, 
          'Failed to create asset from JSON: ' || SQLERRM || 
          ' (All changes rolled back)');
    END;
    
  END AddCompleteAssetFromJSON;

  PROCEDURE ScheduleFlightFromJSON(p_json_data IN CLOB, p_new_context_id OUT NUMBER) IS
    -- Creates a new flight (AllocationContext) from JSON data and initializes capacity snapshots.
    -- Validates that the specified aircraft exists and is active before scheduling.
    v_json_obj JSON_OBJECT_T;
    v_flight_obj JSON_OBJECT_T;
    v_asset_id_obj JSON_OBJECT_T;
    v_schedule_obj JSON_OBJECT_T;
    v_departure_obj JSON_OBJECT_T;
    v_arrival_obj JSON_OBJECT_T;
    
    v_context_identifier VARCHAR2(100);
    v_asset_id NUMBER;
    v_asset_id_type VARCHAR2(20);
    v_asset_id_value VARCHAR2(100);
    v_start_date DATE;
    v_end_date DATE;
    v_metadata CLOB;
    
    v_departure_date VARCHAR2(20);
    v_departure_time VARCHAR2(10);
    v_arrival_date VARCHAR2(20);
    v_arrival_time VARCHAR2(10);
    v_datetime_string VARCHAR2(50);
  BEGIN
    SAVEPOINT before_flight_schedule;
    
    LogDebugMessage('=== Starting ScheduleFlightFromJSON ===');
    
    BEGIN
      -- Parse JSON
      v_json_obj := JSON_OBJECT_T.parse(p_json_data);
      v_flight_obj := v_json_obj.get_object('flight');
      
      -- Step 1: Extract flight identifier
      v_context_identifier := v_flight_obj.get_string('context_identifier');
      LogDebugMessage('Scheduling flight: ' || v_context_identifier);
      
      -- Step 2: Resolve asset ID
      v_asset_id_obj := v_flight_obj.get_object('asset_identifier');
      v_asset_id_type := v_asset_id_obj.get_string('type');
      v_asset_id_value := v_asset_id_obj.get_string('value');
      
      CASE v_asset_id_type
        WHEN 'id' THEN
          v_asset_id := TO_NUMBER(v_asset_id_value);
        WHEN 'name' THEN
          BEGIN
            SELECT id INTO v_asset_id 
            FROM ResourceAsset 
            WHERE name = v_asset_id_value AND ROWNUM = 1;
          EXCEPTION
            WHEN NO_DATA_FOUND THEN
              RAISE_APPLICATION_ERROR(-20400, 'Asset not found with name: ' || v_asset_id_value);
          END;
        WHEN 'description' THEN
          BEGIN
            SELECT id INTO v_asset_id 
            FROM ResourceAsset 
            WHERE description = v_asset_id_value AND ROWNUM = 1;
          EXCEPTION
            WHEN NO_DATA_FOUND THEN
              RAISE_APPLICATION_ERROR(-20401, 'Asset not found with description: ' || v_asset_id_value);
          END;
        ELSE
          RAISE_APPLICATION_ERROR(-20402, 'Invalid asset identifier type: ' || v_asset_id_type);
      END CASE;
      
      LogDebugMessage('Resolved asset ID: ' || v_asset_id);
      
      -- Step 3: Parse schedule dates/times
      v_schedule_obj := v_flight_obj.get_object('schedule');
      v_departure_obj := v_schedule_obj.get_object('departure');
      v_arrival_obj := v_schedule_obj.get_object('arrival');
      
      v_departure_date := v_departure_obj.get_string('date');
      v_departure_time := v_departure_obj.get_string('time');
      v_arrival_date := v_arrival_obj.get_string('date');
      v_arrival_time := v_arrival_obj.get_string('time');
      
      -- Combine date and time
      v_datetime_string := v_departure_date || ' ' || v_departure_time;
      v_start_date := TO_DATE(v_datetime_string, 'YYYY-MM-DD HH24:MI');
      
      v_datetime_string := v_arrival_date || ' ' || v_arrival_time;
      v_end_date := TO_DATE(v_datetime_string, 'YYYY-MM-DD HH24:MI');
      
      LogDebugMessage('Departure: ' || TO_CHAR(v_start_date, 'YYYY-MM-DD HH24:MI'));
      LogDebugMessage('Arrival: ' || TO_CHAR(v_end_date, 'YYYY-MM-DD HH24:MI'));
      
      -- Step 4: Additional date validations
      IF v_end_date <= v_start_date THEN
        RAISE_APPLICATION_ERROR(-20403, 
          'Arrival time must be after departure time. Departure: ' || 
          TO_CHAR(v_start_date, 'YYYY-MM-DD HH24:MI') || ', Arrival: ' || 
          TO_CHAR(v_end_date, 'YYYY-MM-DD HH24:MI'));
      END IF;
      
      IF v_start_date < SYSDATE THEN
        RAISE_APPLICATION_ERROR(-20404, 
          'Cannot schedule flight in the past. Departure: ' || 
          TO_CHAR(v_start_date, 'YYYY-MM-DD HH24:MI'));
      END IF;
      
      -- Step 5: Extract metadata if present
      IF v_flight_obj.has('metadata') THEN
        v_metadata := v_flight_obj.get_object('metadata').to_clob();
      ELSE
        v_metadata := NULL;
      END IF;
      
      -- Step 6: Create AllocationContext (with all validations)
      LogDebugMessage('Creating AllocationContext...');
      ResourceManagement_Data.AddAllocationContext(
        p_asset_id => v_asset_id,
        p_context_identifier => v_context_identifier,
        p_start_date => v_start_date,
        p_end_date => v_end_date,
        p_metadata => v_metadata
      );
      
      -- Get the newly created context ID
      SELECT id INTO p_new_context_id
      FROM AllocationContext
      WHERE context_identifier = v_context_identifier
        AND asset_id = v_asset_id
        AND start_date = v_start_date
        AND end_date = v_end_date;
      
      -- Step 7: Verify Capacity records were created
      DECLARE
        v_capacity_count NUMBER;
      BEGIN
        SELECT COUNT(*) INTO v_capacity_count
        FROM Capacity
        WHERE context_id = p_new_context_id;
        
        LogDebugMessage('Created ' || v_capacity_count || ' capacity records');
        
        IF v_capacity_count = 0 THEN
          RAISE_APPLICATION_ERROR(-20405, 
            'No capacity records created. Check AssetCapacity configuration.');
        END IF;
      END;
      
      -- Success!
      LogDebugMessage('=== Flight scheduling SUCCESSFUL ===');
      LogDebugMessage('Context ID: ' || p_new_context_id);
      LogDebugMessage('Flight: ' || v_context_identifier);
      
      --COMMIT;
      
    EXCEPTION
      WHEN OTHERS THEN
        ROLLBACK TO before_flight_schedule;
        LogDebugMessage('=== Flight scheduling FAILED ===');
        LogDebugMessage('Error: ' || SQLERRM);
        LogDebugMessage('Backtrace: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
        RAISE_APPLICATION_ERROR(-20406, 
          'Failed to schedule flight from JSON: ' || SQLERRM || 
          ' (All changes rolled back)');
    END;
    
  END ScheduleFlightFromJSON;

  FUNCTION GetAvailableSeatCount(p_context_identifier IN VARCHAR2, p_category_name IN VARCHAR2) RETURN NUMBER IS
    -- Returns the number of currently available seats for a specific flight and category.
    -- Queries the Capacity table with lock-free RESERVABLE counters for O(1) performance.
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_available_count NUMBER;
  BEGIN
    -- Get context and category IDs
    SELECT ac.id, rc.id
    INTO v_context_id, v_category_id
    FROM AllocationContext ac
    JOIN ResourceCategory rc ON rc.name = p_category_name
    WHERE ac.context_identifier = p_context_identifier;

    -- Read from capacity snapshot (fast O(1) lookup)
    v_available_count := ResourceManagement_Data.GetAvailableCapacity(v_context_id, v_category_id);
      
    RETURN v_available_count;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 0;
  END GetAvailableSeatCount;

  --==============================================================================
  -- Reservation (pool mode) – internal then public
  --==============================================================================
  -- MakeReservation: reserve only (p_timeout_minutes NULL) or reserve + wait + random confirm/decline (p_timeout_minutes set).
  PROCEDURE MakeReservation(
    p_context_identifier IN VARCHAR2, 
    p_category_name IN VARCHAR2, 
    p_user_id IN NUMBER, 
    p_quantity IN NUMBER, 
    p_timeout_minutes IN NUMBER DEFAULT NULL, 
    p_new_journal_ids OUT SYS.ODCINUMBERLIST
  ) IS
    v_available_count NUMBER;
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_asset_id NUMBER;
    v_new_id NUMBER;
    TYPE t_instance_ids IS TABLE OF NUMBER;
    v_available_instances t_instance_ids;
    v_retry_count NUMBER := 0;
    v_success BOOLEAN := FALSE;
    -- Track committed journal IDs per attempt for compensation
    v_attempt_journal_ids SYS.ODCINUMBERLIST;
    e_active_alloc_conflict EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_active_alloc_conflict, -20910);
    v_random_number NUMBER;
    v_current_status VARCHAR2(20);
  BEGIN
    p_new_journal_ids := SYS.ODCINUMBERLIST();

    -- Retry loop for optimistic concurrency control
    WHILE NOT v_success AND v_retry_count < 3 LOOP
      BEGIN
        --======================================================================
        -- PHASE 1: VALIDATION (all checks before any permanent changes)
        --======================================================================
        SAVEPOINT start_reservation;
        v_attempt_journal_ids := SYS.ODCINUMBERLIST();

        v_available_count := GetAvailableSeatCount(p_context_identifier, p_category_name);
        
        IF v_available_count < p_quantity THEN
          RAISE_APPLICATION_ERROR(-20001, 'Not enough seats available. Requested: ' || p_quantity || ', Available: ' || v_available_count);
        END IF;

        SELECT ac.id, ac.asset_id, rc.id 
        INTO v_context_id, v_asset_id, v_category_id
        FROM AllocationContext ac, ResourceCategory rc
        WHERE ac.context_identifier = p_context_identifier AND rc.name = p_category_name;
        
        -- Validate allocation mode - MakeReservation is only for pool mode
        IF GetAllocationModeForCategory(v_category_id) != 'pool' THEN
          RAISE_APPLICATION_ERROR(-20050, 
            'MakeReservation can only be used for contained allocation mode. ' ||
            'Use AllocateResourceDirect for shared allocation mode.');
        END IF;

        -- Fetch available instances WITHOUT locking (optimistic approach)
        SELECT ri.id BULK COLLECT INTO v_available_instances
        FROM ResourceInstance ri
        WHERE ri.asset_id = v_asset_id
          AND ri.category_id = v_category_id
          AND ri.status = 'available'
          AND NOT EXISTS (
            SELECT 1 FROM CurrentAllocations ca
            WHERE ca.resource_instance_id = ri.id 
              AND ca.context_id = v_context_id
              AND ca.status IN ('reserved', 'confirmed', 'checked-in', 'boarded')
          )
          AND ROWNUM <= p_quantity;

        IF v_available_instances.COUNT < p_quantity THEN
          RAISE_APPLICATION_ERROR(-20001, 'Not enough seats available. Requested: ' || p_quantity || ', Found: ' || v_available_instances.COUNT);
        END IF;

        --======================================================================
        -- PHASE 2: ATOMIC BUSINESS STATE
        -- Journal entries are autonomous; capacity updates are part of the
        -- main transaction. On any failure, rollback capacity and compensate
        -- all committed journal entries.
        --======================================================================
        FOR i IN 1..v_available_instances.COUNT LOOP
          -- Phase 2a: Create journal entry (autonomous - commits immediately)
          ResourceManagement_Data.AddAllocationJournal(
            p_context_id => v_context_id,
            p_category_id => v_category_id,
            p_user_id => p_user_id,
            p_resource_instance_id => v_available_instances(i),
            p_status => 'reserved',
            p_metadata => NULL,
            p_journal_id => v_new_id
          );
          
          v_attempt_journal_ids.EXTEND;
          v_attempt_journal_ids(v_attempt_journal_ids.LAST) := v_new_id;
          
          -- Phase 2b: Update capacity (main transaction - escrow)
          ResourceManagement_Data.IncrementCapacityCounter(
            p_context_id => v_context_id,
            p_category_id => v_category_id,
            p_active_delta => 1
          );
        END LOOP;
        
        -- All operations succeeded - copy attempt IDs to output
        p_new_journal_ids := v_attempt_journal_ids;
        v_success := TRUE;
        EXIT;
        
      EXCEPTION
        WHEN e_active_alloc_conflict THEN
          -- Seat taken by concurrent session (ActiveAllocation unique constraint)
          -- Autonomous tx already rolled back for the failed entry - no journal committed for it
          ROLLBACK TO start_reservation;
          -- Compensate journals committed in earlier loop iterations of this attempt
          FOR j IN 1..v_attempt_journal_ids.COUNT LOOP
            CompensateJournalEntry(v_attempt_journal_ids(j), 'cancelled', 'retry_conflict');
          END LOOP;
          
          v_retry_count := v_retry_count + 1;
          
          IF v_retry_count >= 3 THEN
            LogDebugMessage('MakeReservation failed after ' || v_retry_count || ' retries due to contention');
            RAISE_APPLICATION_ERROR(-20001, 'Unable to complete reservation due to high demand. Please try again.');
          END IF;
          
          DBMS_SESSION.SLEEP(POWER(2, v_retry_count - 1) * 0.1);
          LogDebugMessage('MakeReservation retry ' || v_retry_count || ' for context: ' || p_context_identifier);
          
        WHEN OTHERS THEN
          -- Compensate journals committed in THIS attempt, then rollback capacity.
          -- NOTE: With RESERVABLE columns, capacity errors surface at COMMIT (not
          -- here). This handler catches non-capacity errors (e.g., FK violations).
          ROLLBACK TO start_reservation;
          FOR j IN 1..v_attempt_journal_ids.COUNT LOOP
            CompensateJournalEntry(v_attempt_journal_ids(j), 'cancelled', 'reservation_failed: ' || SQLERRM);
          END LOOP;
          RAISE;
      END;
    END LOOP;

    
    -- Optional: wait and make random confirm/decline decision (when p_timeout_minutes is set)
    IF p_timeout_minutes IS NOT NULL THEN
      LogDebugMessage('Reservation created. Waiting ' || p_timeout_minutes || ' minutes before confirmation decision.');
      DBMS_SESSION.SLEEP(p_timeout_minutes * 60);

      FOR i IN 1..p_new_journal_ids.COUNT LOOP
        BEGIN
          SELECT status INTO v_current_status
          FROM CurrentAllocations
          WHERE journal_id = p_new_journal_ids(i);
        EXCEPTION
          WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002, 'Reservation not found for journal ID: ' || p_new_journal_ids(i));
        END;
        IF v_current_status != 'reserved' THEN
          RAISE_APPLICATION_ERROR(-20002, 'Reservation not in reserved state for journal ID: ' || p_new_journal_ids(i) || ' (current=' || v_current_status || ')');
        END IF;
      END LOOP;

      v_random_number := TRUNC(DBMS_RANDOM.VALUE(1, 11));
      IF MOD(v_random_number, 2) = 0 THEN
        LogDebugMessage('Random decision: confirm (value=' || v_random_number || ')');
        FOR i IN 1..p_new_journal_ids.COUNT LOOP
          ConfirmReservation(p_new_journal_ids(i));
        END LOOP;
      ELSE
        LogDebugMessage('Random decision: decline (value=' || v_random_number || ')');
        FOR i IN 1..p_new_journal_ids.COUNT LOOP
          CancelReservation(p_new_journal_ids(i), '{"reason": "random_decline"}');
        END LOOP;
      END IF;

      --COMMIT;
      DBMS_OUTPUT.PUT_LINE('Reservation decision committed (random=' || v_random_number || '). Journal IDs: ' || p_new_journal_ids.COUNT);
    END IF;
    
  END MakeReservation;

  --==============================================================================
  -- Type substitution (offer flow)
  --==============================================================================
  PROCEDURE MakeReservationWithAlternative(
    p_context_identifier         IN VARCHAR2,
    p_original_category_name     IN VARCHAR2,
    p_user_id                    IN NUMBER,
    p_quantity                   IN NUMBER,
    p_alternative_category_names IN VARCHAR2 DEFAULT NULL,
    p_offer_timeout_minutes      IN NUMBER DEFAULT 5,
    p_include_partial_original   IN VARCHAR2 DEFAULT NULL,
    p_offer_group_id             OUT VARCHAR2,
    p_offer_journal_ids          OUT SYS.ODCINUMBERLIST
  ) IS
    -- When original has no/fewer seats, create one offer group. p_include_partial_original = 'Y': reserve from original first, then shortfall from each substitute (e.g. seats together). NULL (default): only substitute categories, p_quantity from each.
    v_context_id          NUMBER;
    v_asset_id            NUMBER;
    v_original_category_id NUMBER;
    v_available_count     NUMBER;
    TYPE t_cat_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    v_alt_category_ids    t_cat_ids;
    v_alt_count           PLS_INTEGER := 0;
    v_cat_id              NUMBER;
    v_from_name           VARCHAR2(100);
    v_to_name             VARCHAR2(100);
    v_str                 VARCHAR2(4000);
    v_pos                 PLS_INTEGER;
    v_name                VARCHAR2(4000);
    v_n                   NUMBER;
    v_remaining           NUMBER;
  BEGIN
    p_offer_journal_ids := SYS.ODCINUMBERLIST();
    p_offer_group_id := NULL;

    -- Resolve context, asset, original category
    BEGIN
      SELECT ac.id, ac.asset_id INTO v_context_id, v_asset_id
      FROM AllocationContext ac
      WHERE ac.context_identifier = p_context_identifier;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20510, 'Context not found: ' || p_context_identifier);
    END;
    BEGIN
      SELECT id INTO v_original_category_id FROM ResourceCategory WHERE name = p_original_category_name;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20511, 'Category not found: ' || p_original_category_name);
    END;

    IF GetAllocationModeForCategory(v_original_category_id) != 'pool' THEN
      RAISE_APPLICATION_ERROR(-20050, 'MakeReservationWithAlternative is only for contained allocation mode.');
    END IF;

    v_available_count := GetAvailableSeatCount(p_context_identifier, p_original_category_name);
    IF v_available_count >= p_quantity THEN
      -- Enough in original: standard flow (no offer group)
      MakeReservation(
        p_context_identifier => p_context_identifier,
        p_category_name      => p_original_category_name,
        p_user_id            => p_user_id,
        p_quantity           => p_quantity,
        p_timeout_minutes    => p_offer_timeout_minutes,
        p_new_journal_ids    => p_offer_journal_ids
      );
      RETURN;
    END IF;

    -- Build list of alternative category IDs
    IF p_alternative_category_names IS NOT NULL AND TRIM(p_alternative_category_names) IS NOT NULL THEN
      v_str := TRIM(p_alternative_category_names) || ',';
      v_pos := 1;
      WHILE v_pos <= LENGTH(v_str) LOOP
        v_name := TRIM(SUBSTR(v_str, v_pos, INSTR(v_str, ',', v_pos) - v_pos));
        v_pos := INSTR(v_str, ',', v_pos) + 1;
        IF v_name IS NOT NULL THEN
          BEGIN
            SELECT id INTO v_cat_id FROM ResourceCategory WHERE name = v_name;
            v_alt_count := v_alt_count + 1;
            v_alt_category_ids(v_alt_count) := v_cat_id;
          EXCEPTION
            WHEN NO_DATA_FOUND THEN
              RAISE_APPLICATION_ERROR(-20512, 'Alternative category not found: ' || v_name);
          END;
        END IF;
      END LOOP;
    ELSE
      FOR r IN (
        SELECT cs.to_category_id
        FROM CategorySubstitution cs
        JOIN ResourceCategory rc ON cs.from_category_id = rc.id
        WHERE rc.name = p_original_category_name
          AND cs.auto_offer = 'Y'
          AND cs.is_allowed = 'Y'
          AND (cs.valid_from IS NULL OR cs.valid_from <= SYSDATE)
          AND (cs.valid_until IS NULL OR cs.valid_until >= SYSDATE)
        ORDER BY cs.priority
      ) LOOP
        v_alt_count := v_alt_count + 1;
        v_alt_category_ids(v_alt_count) := r.to_category_id;
      END LOOP;
    END IF;

    IF v_alt_count = 0 THEN
      RAISE_APPLICATION_ERROR(-20001, 'Not enough seats in ' || p_original_category_name || ' and no alternatives configured.');
    END IF;

    p_offer_group_id := SYS_GUID();
    SELECT name INTO v_from_name FROM ResourceCategory WHERE id = v_original_category_id;

    -- p_include_partial_original = 'Y': reserve from original first, then shortfall from each substitute. NULL (default): only substitute categories.
    v_n := 0;
    v_remaining := p_quantity;
    IF UPPER(TRIM(NVL(p_include_partial_original, 'N'))) = 'Y' AND v_available_count > 0 THEN
      v_n := reserve_offer_batch(
        p_context_id             => v_context_id,
        p_asset_id               => v_asset_id,
        p_from_category_id       => v_original_category_id,
        p_to_category_id         => v_original_category_id,
        p_from_name              => v_from_name,
        p_to_name                => v_from_name,
        p_user_id                => p_user_id,
        p_offer_group_id         => p_offer_group_id,
        p_quantity               => LEAST(v_available_count, p_quantity),
        p_offer_journal_ids      => p_offer_journal_ids,
        p_offer_timeout_minutes  => p_offer_timeout_minutes
      );
      v_remaining := p_quantity - v_n;
    END IF;

    -- Substitutes: when partial original active, reserve v_remaining from EACH substitute; otherwise p_quantity from each (upgrade-only bundles)
    FOR i IN 1..v_alt_count LOOP
      v_cat_id := v_alt_category_ids(i);
      SELECT name INTO v_to_name FROM ResourceCategory WHERE id = v_cat_id;
      v_n := GetAvailableSeatCount(p_context_identifier, v_to_name);
      IF v_n <= 0 THEN
        CONTINUE;
      END IF;
      IF UPPER(TRIM(NVL(p_include_partial_original, 'N'))) = 'Y' THEN
        IF v_remaining <= 0 THEN EXIT; END IF;
        v_n := reserve_offer_batch(
          p_context_id             => v_context_id,
          p_asset_id               => v_asset_id,
          p_from_category_id       => v_original_category_id,
          p_to_category_id         => v_cat_id,
          p_from_name              => v_from_name,
          p_to_name                => v_to_name,
          p_user_id                => p_user_id,
          p_offer_group_id         => p_offer_group_id,
          p_quantity               => LEAST(v_n, v_remaining),
          p_offer_journal_ids      => p_offer_journal_ids,
          p_offer_timeout_minutes  => p_offer_timeout_minutes
        );
      ELSE
        IF v_n < p_quantity THEN CONTINUE; END IF;
        v_n := reserve_offer_batch(
          p_context_id             => v_context_id,
          p_asset_id               => v_asset_id,
          p_from_category_id       => v_original_category_id,
          p_to_category_id         => v_cat_id,
          p_from_name              => v_from_name,
          p_to_name                => v_to_name,
          p_user_id                => p_user_id,
          p_offer_group_id         => p_offer_group_id,
          p_quantity               => p_quantity,
          p_offer_journal_ids      => p_offer_journal_ids,
          p_offer_timeout_minutes  => p_offer_timeout_minutes
        );
      END IF;
    END LOOP;

    IF p_offer_journal_ids.COUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20001, 'No seats available in ' || p_original_category_name || ' or alternatives.');
    END IF;

    COMMIT;
    LogDebugMessage('MakeReservationWithAlternative: offer_group=' || p_offer_group_id || ', journals=' || p_offer_journal_ids.COUNT);
  END MakeReservationWithAlternative;

  PROCEDURE ConfirmSubstitutionOffer(
    p_offer_group_id         IN VARCHAR2,
    p_selected_category_name IN VARCHAR2,
    p_user_id                IN NUMBER
  ) IS
    v_from_name VARCHAR2(100);  -- original category name (from metadata) so we can confirm original + selected when user picks a substitute
  BEGIN
    IF p_offer_group_id IS NULL THEN
      RAISE_APPLICATION_ERROR(-20520, 'Offer group id required.');
    END IF;
    IF p_selected_category_name IS NULL OR TRIM(p_selected_category_name) IS NULL THEN
      RAISE_APPLICATION_ERROR(-20521, 'Selected category name required.');
    END IF;

    -- When user selects a substitute, they get that category + original (e.g. 1 Economy + 1 Premium). When they select original, they get original only.
    BEGIN
      SELECT JSON_VALUE(aj.metadata, '$.from_category_name')
        INTO v_from_name
        FROM AllocationJournal aj
        JOIN CurrentAllocations ca ON ca.journal_id = aj.id
        WHERE JSON_VALUE(aj.metadata, '$.offer_group_id') = p_offer_group_id AND ca.user_id = p_user_id
        AND ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        v_from_name := NULL;
    END;

    -- Confirm: selected category; when selected is a substitute, also confirm original (from_category_name) so user gets 2 seats (original + chosen substitute)
    FOR r IN (
      SELECT aj.id
      FROM AllocationJournal aj
      JOIN CurrentAllocations ca ON ca.journal_id = aj.id
      WHERE JSON_VALUE(aj.metadata, '$.offer_group_id') = p_offer_group_id
        AND ca.user_id = p_user_id
        AND (
          JSON_VALUE(aj.metadata, '$.to_category_name') = TRIM(p_selected_category_name)
          OR (v_from_name IS NOT NULL AND JSON_VALUE(aj.metadata, '$.to_category_name') = v_from_name)
        )
    ) LOOP
      ConfirmReservation(r.id);
    END LOOP;

    -- Cancel the rest in the group (other categories)
    FOR r IN (
      SELECT aj.id
      FROM AllocationJournal aj
      JOIN CurrentAllocations ca ON ca.journal_id = aj.id
      WHERE JSON_VALUE(aj.metadata, '$.offer_group_id') = p_offer_group_id
        AND ca.user_id = p_user_id
        AND (JSON_VALUE(aj.metadata, '$.to_category_name') IS NULL OR JSON_VALUE(aj.metadata, '$.to_category_name') != TRIM(p_selected_category_name))
        AND (v_from_name IS NULL OR JSON_VALUE(aj.metadata, '$.to_category_name') != v_from_name)
    ) LOOP
      CancelReservation(r.id, '{"reason": "substitution_offer_declined", "offer_group_id": "' || p_offer_group_id || '", "selected_category": "' || REPLACE(TRIM(p_selected_category_name), '"', '\"') || '"}');
    END LOOP;

    COMMIT;
    LogDebugMessage('ConfirmSubstitutionOffer: offer_group=' || p_offer_group_id || ', category=' || p_selected_category_name || ' confirmed.');
  END ConfirmSubstitutionOffer;

  PROCEDURE DeclineSubstitutionOffer(
    p_offer_group_id IN VARCHAR2,
    p_user_id        IN NUMBER
  ) IS
  BEGIN
    IF p_offer_group_id IS NULL THEN
      RAISE_APPLICATION_ERROR(-20523, 'Offer group id required.');
    END IF;
    FOR r IN (
      SELECT aj.id
      FROM AllocationJournal aj
      JOIN CurrentAllocations ca ON ca.journal_id = aj.id
      WHERE JSON_VALUE(aj.metadata, '$.offer_group_id') = p_offer_group_id
        AND ca.user_id = p_user_id
    ) LOOP
      CancelReservation(r.id, '{"reason": "declined_by_user", "offer_group_id": "' || p_offer_group_id || '"}');
    END LOOP;
    COMMIT;
    LogDebugMessage('DeclineSubstitutionOffer: offer_group=' || p_offer_group_id || ', all offers cancelled.');
  END DeclineSubstitutionOffer;

  PROCEDURE MakeReservationByInstanceId(
    p_context_identifier IN VARCHAR2,
    p_user_id IN NUMBER,
    p_instance_id IN NUMBER,
    p_timeout_minutes IN NUMBER DEFAULT 5,  -- Use Case 4: Short hold for seat selection
    p_new_journal_id OUT NUMBER
  ) IS
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_asset_id NUMBER;
    v_instance_status VARCHAR2(20);
    v_instance_asset_id NUMBER;
    v_instance_category_id NUMBER;
    v_instance_identifier VARCHAR2(50);
    v_existing_allocation NUMBER;
    v_random_number NUMBER;
    v_current_status VARCHAR2(20);
    v_journal_committed BOOLEAN := FALSE;
  BEGIN
    LogDebugMessage('=== Starting MakeReservationByInstanceId (Use Case 4: Seat Hold) ===');
    LogDebugMessage('Context: ' || p_context_identifier || ', User: ' || p_user_id || ', Instance: ' || p_instance_id);
    
    -- STEP 1: Resolve context and get asset_id
    BEGIN
      SELECT id, asset_id INTO v_context_id, v_asset_id
      FROM AllocationContext
      WHERE context_identifier = p_context_identifier;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20600, 'Flight not found: ' || p_context_identifier);
    END;
    
    LogDebugMessage('Resolved context_id: ' || v_context_id || ', asset_id: ' || v_asset_id);
    
    -- STEP 2: Validate instance exists and get details
    BEGIN
      SELECT status, asset_id, category_id, instance_identifier
      INTO v_instance_status, v_instance_asset_id, v_instance_category_id, v_instance_identifier
      FROM ResourceInstance
      WHERE id = p_instance_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20601, 'Resource instance not found with ID: ' || p_instance_id);
    END;
    
    LogDebugMessage('Instance ' || p_instance_id || ' (' || v_instance_identifier || ') - Status: ' || v_instance_status);
    
    -- STEP 3: Check instance belongs to correct aircraft
    IF v_instance_asset_id != v_asset_id THEN
      RAISE_APPLICATION_ERROR(-20602, 
        'Instance ' || p_instance_id || ' does not belong to this flight. ' ||
        'Instance is on asset ' || v_instance_asset_id || ', flight uses asset ' || v_asset_id);
    END IF;
    
    -- STEP 4: Check instance is physically available (not under maintenance)
    IF v_instance_status != 'available' THEN
      RAISE_APPLICATION_ERROR(-20603, 
        'Instance ' || p_instance_id || ' (' || v_instance_identifier || ') is not available. ' ||
        'Current status: ' || v_instance_status);
    END IF;
    
    -- STEP 5: Check instance is not already allocated on this flight
    SELECT COUNT(*) INTO v_existing_allocation
    FROM CurrentAllocations
    WHERE resource_instance_id = p_instance_id
      AND context_id = v_context_id
      AND status IN ('reserved', 'confirmed', 'checked-in', 'boarded');
    
    IF v_existing_allocation > 0 THEN
      RAISE_APPLICATION_ERROR(-20604, 
        'Instance ' || p_instance_id || ' (' || v_instance_identifier || ') is already reserved on this flight');
    END IF;
    
    LogDebugMessage('All validations passed. Creating reservation...');
    
    -- PHASE 2: ATOMIC BUSINESS STATE
    SAVEPOINT before_reservation;
    
    ResourceManagement_Data.AddAllocationJournal(
      p_context_id => v_context_id,
      p_category_id => v_instance_category_id,
      p_user_id => p_user_id,
      p_resource_instance_id => p_instance_id,
      p_status => 'reserved',
      p_metadata => NULL,
      p_journal_id => p_new_journal_id
    );
    v_journal_committed := TRUE;
    
    LogDebugMessage('Created journal entry: ' || p_new_journal_id);
    
    ResourceManagement_Data.IncrementCapacityCounter(
      p_context_id => v_context_id,
      p_category_id => v_instance_category_id,
      p_active_delta => 1
    );
    LogDebugMessage('Updated capacity counters');
    
    LogDebugMessage('Seat hold created. Waiting 5 minutes before confirmation decision.');
    DBMS_SESSION.SLEEP(300);

    -- Check table state before deciding
    BEGIN
      SELECT status INTO v_current_status
      FROM CurrentAllocations
      WHERE journal_id = p_new_journal_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20002, 'Reservation not found for journal ID: ' || p_new_journal_id);
    END;

    IF v_current_status != 'reserved' THEN
      RAISE_APPLICATION_ERROR(-20002, 'Reservation not in reserved state for journal ID: ' || p_new_journal_id || ' (current=' || v_current_status || ')');
    END IF;

    v_random_number := TRUNC(DBMS_RANDOM.VALUE(1, 11));
    IF MOD(v_random_number, 2) = 0 THEN
      LogDebugMessage('Random decision: confirm (value=' || v_random_number || ')');
      ConfirmReservation(p_new_journal_id);
    ELSE
      LogDebugMessage('Random decision: decline (value=' || v_random_number || ')');
      CancelReservation(p_new_journal_id, '{"reason": "random_decline"}');
    END IF;

    COMMIT;
    
    LogDebugMessage('=== MakeReservationByInstanceId SUCCESSFUL ===');
    LogDebugMessage('Seat ' || v_instance_identifier || ' reserved for user ' || p_user_id);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK TO before_reservation;
      IF v_journal_committed THEN
        CompensateJournalEntry(p_new_journal_id, 'cancelled', 'reservation_failed: ' || SQLERRM);
        p_new_journal_id := NULL;
      END IF;
      LogDebugMessage('=== MakeReservationByInstanceId FAILED ===');
      LogDebugMessage('Error: ' || SQLERRM);
      RAISE;
  END MakeReservationByInstanceId;

  --==============================================================================
  --==============================================================================
  -- Shared allocation (direct mode, time-overlap conflict detection)
  --==============================================================================
  FUNCTION CheckResourceTimeConflict(
    p_resource_instance_id IN NUMBER,
    p_context_identifier IN VARCHAR2
  ) RETURN NUMBER IS
    v_context_id NUMBER;
    v_start_date DATE;
    v_end_date DATE;
    v_conflict_context_id NUMBER;
  BEGIN
    -- Get context details
    SELECT id, start_date, end_date 
    INTO v_context_id, v_start_date, v_end_date
    FROM AllocationContext
    WHERE context_identifier = p_context_identifier;
    
    -- Check for time conflicts
    v_conflict_context_id := ResourceManagement_Data.GetResourceTimeConflict(
      p_resource_instance_id => p_resource_instance_id,
      p_start_date => v_start_date,
      p_end_date => v_end_date,
      p_exclude_context_id => v_context_id
    );
    
    RETURN v_conflict_context_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20700, 'Context not found: ' || p_context_identifier);
  END CheckResourceTimeConflict;
  
  FUNCTION GetResourceSchedule(
    p_resource_instance_id IN NUMBER
  ) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR
      SELECT 
        rs.resource_instance_id,
        rs.instance_identifier,
        rs.context_id,
        rs.context_identifier,
        rs.context_start,
        rs.context_end,
        rs.status,
        rs.user_id,
        rs.category_id
      FROM ResourceSchedule rs
      WHERE rs.resource_instance_id = p_resource_instance_id
      ORDER BY rs.context_start;
    RETURN rc;
  END GetResourceSchedule;
  
  FUNCTION IsResourceAvailable(
    p_resource_instance_id IN NUMBER,
    p_context_identifier IN VARCHAR2
  ) RETURN VARCHAR2 IS
    v_context_id NUMBER;
    v_start_date DATE;
    v_end_date DATE;
    v_category_id NUMBER;
    v_allocation_mode VARCHAR2(10);
    v_existing_count NUMBER;
  BEGIN
    -- Get context details
    SELECT id, start_date, end_date 
    INTO v_context_id, v_start_date, v_end_date
    FROM AllocationContext
    WHERE context_identifier = p_context_identifier;
    
    -- Get resource's category and allocation mode
    SELECT ri.category_id, rc.allocation_mode
    INTO v_category_id, v_allocation_mode
    FROM ResourceInstance ri
    JOIN ResourceCategory rc ON ri.category_id = rc.id
    WHERE ri.id = p_resource_instance_id;
    
    IF v_allocation_mode = 'direct' THEN
      -- Direct mode: Check time-overlap across all contexts
      RETURN ResourceManagement_Data.IsResourceAvailableForInterval(
        p_resource_instance_id => p_resource_instance_id,
        p_start_date => v_start_date,
        p_end_date => v_end_date,
        p_exclude_context_id => NULL
      );
    ELSE
      -- Pool mode: Check within this context only
      SELECT COUNT(*) INTO v_existing_count
      FROM CurrentAllocations ca
      WHERE ca.resource_instance_id = p_resource_instance_id
        AND ca.context_id = v_context_id;
      
      IF v_existing_count > 0 THEN
        RETURN 'N';
      ELSE
        RETURN 'Y';
      END IF;
    END IF;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 'N';  -- Resource or context not found
  END IsResourceAvailable;
  
  PROCEDURE AllocateResourceDirect(
    p_context_identifier IN VARCHAR2,
    p_resource_instance_id IN NUMBER,
    p_user_id IN NUMBER,
    p_category_id IN NUMBER DEFAULT NULL,
    p_timeout_minutes IN NUMBER DEFAULT 15,
    p_new_journal_id OUT NUMBER
  ) IS
    v_context_id NUMBER;
    v_start_date DATE;
    v_end_date DATE;
    v_resource_category_id NUMBER;
    v_resource_status VARCHAR2(20);
    v_instance_identifier VARCHAR2(50);
    v_conflict_context_id NUMBER;
    v_conflict_context_name VARCHAR2(100);
  BEGIN
    LogDebugMessage('=== Starting AllocateResourceDirect ===');
    LogDebugMessage('Context: ' || p_context_identifier || ', Resource: ' || p_resource_instance_id || ', User: ' || p_user_id);
    
    SAVEPOINT start_direct_allocation;
    
    BEGIN
      -- STEP 1: Get context details
      BEGIN
        SELECT id, start_date, end_date 
        INTO v_context_id, v_start_date, v_end_date
        FROM AllocationContext
        WHERE context_identifier = p_context_identifier;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          RAISE_APPLICATION_ERROR(-20700, 'Context not found: ' || p_context_identifier);
      END;
      
      LogDebugMessage('Context resolved: ID=' || v_context_id || ', Interval=[' || v_start_date || ', ' || v_end_date || ']');
      
      -- STEP 2: Get resource details
      BEGIN
        SELECT category_id, status, instance_identifier
        INTO v_resource_category_id, v_resource_status, v_instance_identifier
        FROM ResourceInstance
        WHERE id = p_resource_instance_id;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          RAISE_APPLICATION_ERROR(-20701, 'Resource instance not found: ' || p_resource_instance_id);
      END;
      
      -- Use provided category_id or default to resource's category
      v_resource_category_id := NVL(p_category_id, v_resource_category_id);
      
      LogDebugMessage('Resource: ' || v_instance_identifier || ', Status: ' || v_resource_status);
      
      -- STEP 3: Check intrinsic availability
      IF v_resource_status != 'available' THEN
        RAISE_APPLICATION_ERROR(-20702, 
          'Resource ' || v_instance_identifier || ' is not available. Current status: ' || v_resource_status);
      END IF;
      
      -- STEP 4: Check time-overlap conflicts across ALL contexts
      v_conflict_context_id := ResourceManagement_Data.GetResourceTimeConflict(
        p_resource_instance_id => p_resource_instance_id,
        p_start_date => v_start_date,
        p_end_date => v_end_date,
        p_exclude_context_id => NULL
      );
      
      IF v_conflict_context_id IS NOT NULL THEN
        -- Get conflict context name for error message
        SELECT context_identifier INTO v_conflict_context_name
        FROM AllocationContext WHERE id = v_conflict_context_id;
        
        RAISE_APPLICATION_ERROR(-20703, 
          'Resource ' || v_instance_identifier || ' has a conflicting allocation in context: ' || v_conflict_context_name ||
          ' (time interval overlaps with ' || p_context_identifier || ')');
      END IF;
      
      LogDebugMessage('No time conflicts found. Creating allocation...');
      
      --======================================================================
      -- PHASE 2: ATOMIC BUSINESS STATE (autonomous transaction)
      --======================================================================
      
      -- Create journal entry (autonomous - commits immediately)
      ResourceManagement_Data.AddAllocationJournal(
        p_context_id => v_context_id,
        p_category_id => v_resource_category_id,
        p_user_id => p_user_id,
        p_resource_instance_id => p_resource_instance_id,
        p_status => 'reserved',
        p_metadata => '{"allocation_mode": "direct"}',
        p_journal_id => p_new_journal_id
      );
      
      LogDebugMessage('Created journal entry: ' || p_new_journal_id);
      
      -- NOTE: No capacity counter update for shared allocation mode
      -- Availability is determined by time-overlap checking, not counters
      
      -- NOTE: No AQ timeout scheduling in current flow
      
      LogDebugMessage('=== AllocateResourceDirect SUCCESSFUL ===');
      LogDebugMessage('Resource ' || v_instance_identifier || ' allocated to context ' || p_context_identifier);
      
    EXCEPTION
      WHEN OTHERS THEN
        ROLLBACK TO start_direct_allocation;
        LogDebugMessage('=== AllocateResourceDirect FAILED ===');
        LogDebugMessage('Error: ' || SQLERRM);
        RAISE;
    END;
    
  END AllocateResourceDirect;

  --==============================================================================
  -- Journal Operations
  --==============================================================================

  PROCEDURE ConfirmReservation(p_journal_id IN NUMBER) IS
    --===========================================================================
    -- Transitions a reservation from 'reserved' to 'confirmed' status.
    -- 
    -- TRANSACTION STRATEGY:
    -- AddAllocationJournal (autonomous) commits the journal + ActiveAllocation
    -- update immediately. No capacity delta (status transition only).
    -- If the allocation was concurrently cancelled, AddAllocationJournal raises
    -- -20911 (ActiveAllocation row missing). This propagates to the caller.
    --===========================================================================
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_user_id NUMBER;
    v_resource_instance_id NUMBER;
    v_current_status VARCHAR2(20);
    v_new_journal_id NUMBER;
  BEGIN
    LogDebugMessage('Attempting to confirm reservation for journal ID: ' || p_journal_id);
    
    BEGIN
      SELECT context_id, category_id, user_id, resource_instance_id, status
      INTO v_context_id, v_category_id, v_user_id, v_resource_instance_id, v_current_status
      FROM CurrentAllocations
      WHERE journal_id = p_journal_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        LogDebugMessage('Confirmation failed for journal ID ' || p_journal_id || '. Reservation not found.');
        RAISE_APPLICATION_ERROR(-20002, 'Reservation not found.');
    END;
    
    IF v_current_status != 'reserved' THEN
      LogDebugMessage('Confirmation failed for journal ID ' || p_journal_id ||
                      '. Expected reserved, got: ' || v_current_status);
      RAISE_APPLICATION_ERROR(-20002,
        'Confirmation failed. Expected status ''reserved'', current: ' || v_current_status);
    END IF;
    
    ResourceManagement_Data.AddAllocationJournal(
      p_context_id => v_context_id,
      p_category_id => v_category_id,
      p_user_id => v_user_id,
      p_resource_instance_id => v_resource_instance_id,
      p_status => 'confirmed',
      p_metadata => NULL,
      p_journal_id => v_new_journal_id
    );
    
    LogDebugMessage('Successfully confirmed reservation for journal ID: ' || p_journal_id);
  END ConfirmReservation;

  PROCEDURE CancelReservation(p_journal_id IN NUMBER, p_cancellation_metadata IN CLOB DEFAULT NULL) IS
    --===========================================================================
    -- Cancels a reservation from any active status.
    -- p_cancellation_metadata: optional JSON/metadata for the journal entry.
    -- 
    -- TRANSACTION STRATEGY:
    -- AddAllocationJournal (autonomous) commits the journal + ActiveAllocation
    -- DELETE immediately. Capacity decrement (RESERVABLE) is deferred to commit.
    --===========================================================================
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_user_id NUMBER;
    v_resource_instance_id NUMBER;
    v_current_status VARCHAR2(20);
    v_new_journal_id NUMBER;
  BEGIN
    LogDebugMessage('Attempting to cancel reservation for journal ID: ' || p_journal_id);
    
    BEGIN
      SELECT context_id, category_id, user_id, resource_instance_id, status
      INTO v_context_id, v_category_id, v_user_id, v_resource_instance_id, v_current_status
      FROM CurrentAllocations 
      WHERE journal_id = p_journal_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        LogDebugMessage('Cancellation failed for journal ID ' || p_journal_id || '. Reservation not found.');
        RAISE_APPLICATION_ERROR(-20003, 'Reservation not found.');
    END;
    
    ResourceManagement_Data.AddAllocationJournal(
      p_context_id => v_context_id,
      p_category_id => v_category_id,
      p_user_id => v_user_id,
      p_resource_instance_id => v_resource_instance_id,
      p_status => 'cancelled',
      p_metadata => p_cancellation_metadata,
      p_journal_id => v_new_journal_id
    );
    
    IF v_current_status IN ('reserved', 'confirmed', 'checked-in', 'boarded', 'blocked')
       AND GetAllocationModeForCategory(v_category_id) = 'pool' THEN
      ResourceManagement_Data.IncrementCapacityCounter(
        p_context_id => v_context_id,
        p_category_id => v_category_id,
        p_active_delta => -1
      );
    END IF;
    
    LogDebugMessage('Successfully cancelled reservation for journal ID: ' || p_journal_id);
  END CancelReservation;
  
  PROCEDURE AssignSpecificSeat(p_journal_id IN NUMBER, p_instance_identifier IN VARCHAR2) IS
    --===========================================================================
    -- Assigns a specific seat to an existing reservation.
    -- NOTE: This procedure does NOT change capacity counters - it only changes
    -- which specific seat is assigned. The allocation count remains the same.
    -- 
    -- TRANSACTION STRATEGY:
    -- PHASE 1: Validate (check reservation exists, seat available, etc.)
    -- PHASE 2: Create journal entry (autonomous - commits immediately)
    --          No capacity changes needed - just seat assignment
    --===========================================================================
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_user_id NUMBER;
    v_asset_id NUMBER;
    v_target_instance_id NUMBER;
    v_current_instance_id NUMBER;
    v_new_journal_id NUMBER;
    v_current_status VARCHAR2(20);
    v_is_taken NUMBER;
  BEGIN
    LogDebugMessage('Attempting to assign seat ' || p_instance_identifier || ' to journal ID: ' || p_journal_id);
    
    --======================================================================
    -- PHASE 1: VALIDATION
    --======================================================================
    
    -- Get current allocation
    BEGIN
      SELECT context_id, category_id, user_id, resource_instance_id, status
      INTO v_context_id, v_category_id, v_user_id, v_current_instance_id, v_current_status
      FROM CurrentAllocations WHERE journal_id = p_journal_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20022, 'Reservation not found for journal ID: ' || p_journal_id);
    END;

    IF v_current_instance_id IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(-20020, 'A specific seat is already assigned to this reservation.');
    END IF;

    -- Find the target instance
    BEGIN
      SELECT ac.asset_id INTO v_asset_id FROM AllocationContext ac WHERE ac.id = v_context_id;
      
      SELECT id INTO v_target_instance_id FROM ResourceInstance
      WHERE asset_id = v_asset_id AND instance_identifier = p_instance_identifier;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20022, 'Seat ' || p_instance_identifier || ' not found for this flight.');
    END;

    -- Check if the target seat is available
    BEGIN
      SELECT 1 INTO v_is_taken FROM CurrentAllocations
      WHERE resource_instance_id = v_target_instance_id 
        AND context_id = v_context_id
        AND status IN ('reserved', 'confirmed', 'checked-in', 'boarded');
      
      -- If we get here, the seat is taken
      RAISE_APPLICATION_ERROR(-20021, 'Seat ' || p_instance_identifier || ' is already taken.');
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        NULL; -- Seat is not taken, proceed
    END;

    --======================================================================
    -- PHASE 2: CREATE JOURNAL ENTRY (autonomous - no capacity changes needed)
    --======================================================================
    ResourceManagement_Data.AddAllocationJournal(
      p_context_id => v_context_id,
      p_category_id => v_category_id,
      p_user_id => v_user_id,
      p_resource_instance_id => v_target_instance_id,
      p_status => v_current_status,
      p_metadata => NULL,
      p_journal_id => v_new_journal_id
    );

    LogDebugMessage('Assigned seat ' || p_instance_identifier || ' to journal ID ' || p_journal_id);
  EXCEPTION
    WHEN OTHERS THEN
      LogDebugMessage('Error assigning seat: ' || SQLERRM);
      RAISE;
  END AssignSpecificSeat;

  PROCEDURE UnconfirmReservation(p_journal_id IN NUMBER) IS
    --===========================================================================
    -- Moves a reservation from 'confirmed' back to 'reserved' (INVERSE of Confirm).
    -- 
    -- TRANSACTION STRATEGY:
    -- AddAllocationJournal (autonomous) commits the journal + ActiveAllocation
    -- update immediately. No capacity delta (status transition only).
    --===========================================================================
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_user_id NUMBER;
    v_resource_instance_id NUMBER;
    v_current_status VARCHAR2(20);
    v_new_journal_id NUMBER;
  BEGIN
    LogDebugMessage('Attempting to unconfirm reservation for journal ID: ' || p_journal_id);
    
    BEGIN
      SELECT context_id, category_id, user_id, resource_instance_id, status
      INTO v_context_id, v_category_id, v_user_id, v_resource_instance_id, v_current_status
      FROM CurrentAllocations 
      WHERE journal_id = p_journal_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20004, 'Reservation not found.');
    END;
    
    IF v_current_status != 'confirmed' THEN
      RAISE_APPLICATION_ERROR(-20004, 'Reservation not in confirmed state. Current status: ' || v_current_status);
    END IF;
    
    ResourceManagement_Data.AddAllocationJournal(
      p_context_id => v_context_id,
      p_category_id => v_category_id,
      p_user_id => v_user_id,
      p_resource_instance_id => v_resource_instance_id,
      p_status => 'reserved',
      p_metadata => NULL,
      p_journal_id => v_new_journal_id
    );
    
    LogDebugMessage('Unconfirmed reservation for journal ID ' || p_journal_id);
  END UnconfirmReservation;

  PROCEDURE ReverseJournalEntry(p_journal_id IN NUMBER, p_target_status IN VARCHAR2, p_reason IN VARCHAR2, p_new_journal_id OUT NUMBER) IS
    --===========================================================================
    -- Generic compensating transaction procedure for edge cases.
    -- Creates a new journal entry with the specified target status.
    -- 
    -- WARNING: This procedure does NOT update capacity counters!
    -- For normal operations, use the specific procedures:
    --   - ConfirmReservation, CancelReservation, CheckInUser, etc.
    -- 
    -- Use this only for administrative corrections where you need to
    -- change status WITHOUT affecting capacity counts.
    --
    -- TRANSACTION STRATEGY:
    -- PHASE 1: Validate (check entry exists, status is different)
    -- PHASE 2: Create journal entry only (autonomous - no capacity changes)
    --===========================================================================
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_user_id NUMBER;
    v_instance_id NUMBER;
    v_current_status VARCHAR2(20);
  BEGIN
    LogDebugMessage('Attempting to reverse journal entry for ID: ' || p_journal_id || 
                    ' to status: ' || p_target_status || ' Reason: ' || p_reason);
    
    --======================================================================
    -- PHASE 1: VALIDATION
    --======================================================================
    BEGIN
      SELECT context_id, category_id, user_id, resource_instance_id, status
      INTO v_context_id, v_category_id, v_user_id, v_instance_id, v_current_status
      FROM CurrentAllocations WHERE journal_id = p_journal_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        LogDebugMessage('Reversal failed for journal ID ' || p_journal_id || '. Entry not found.');
        RAISE_APPLICATION_ERROR(-20005, 'Journal entry not found.');
    END;
    
    IF v_current_status = p_target_status THEN
      LogDebugMessage('Reversal unnecessary - already in target status: ' || p_target_status);
      RAISE_APPLICATION_ERROR(-20005, 'Allocation already in status: ' || p_target_status);
    END IF;
    
    --======================================================================
    -- PHASE 2: CREATE JOURNAL ENTRY ONLY (autonomous - no capacity changes)
    --======================================================================
    ResourceManagement_Data.AddAllocationJournal(
      p_context_id => v_context_id,
      p_category_id => v_category_id,
      p_user_id => v_user_id,
      p_resource_instance_id => v_instance_id,
      p_status => p_target_status,
      p_metadata => '{"reason": "' || p_reason || '", "previous_status": "' || v_current_status || '"}',
      p_journal_id => p_new_journal_id
    );
    
    LogDebugMessage('Successfully reversed journal ID ' || p_journal_id || 
                    ' from ' || v_current_status || ' to ' || p_target_status || 
                    '. New journal entry ID: ' || p_new_journal_id);
  EXCEPTION
    WHEN OTHERS THEN
      LogDebugMessage('Error reversing journal entry: ' || SQLERRM);
      RAISE;
  END ReverseJournalEntry;

  --==============================================================================
  -- Administrative (context, asset, mass operations)
  --==============================================================================
  PROCEDURE ActivateAsset(p_asset_id IN NUMBER) IS
    -- Sets an aircraft asset to 'active' status, making it available for flight scheduling.
    v_asset_name VARCHAR2(50);
  BEGIN
    SAVEPOINT start_activate_asset;
    
    -- Get asset name for logging
    BEGIN
      SELECT name INTO v_asset_name FROM ResourceAsset WHERE id = p_asset_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20019, 'Failed to activate asset. Asset ID not found: ' || p_asset_id);
    END;
    
    UPDATE ResourceAsset SET status = 'active' WHERE id = p_asset_id;
    
    LogDebugMessage('Activated asset: ' || v_asset_name || ' (ID: ' || p_asset_id || ')');
    --COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK TO start_activate_asset;
      LogDebugMessage('Error activating asset: ' || SQLERRM);
      RAISE;
  END ActivateAsset;
  
  PROCEDURE DeactivateAsset(p_asset_id IN NUMBER) IS
    -- Sets an aircraft asset to 'not active' status. Validates no future flights are scheduled and no active reservations exist.
    v_asset_name VARCHAR2(50);
    v_active_reservations NUMBER;
    v_future_flights NUMBER;
  BEGIN
    SAVEPOINT start_deactivate_asset;
    
    -- Get asset name for logging
    BEGIN
      SELECT name INTO v_asset_name FROM ResourceAsset WHERE id = p_asset_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20020, 'Failed to deactivate asset. Asset ID not found: ' || p_asset_id);
    END;
    
    -- Safety Check 1: Ensure there are no future flights scheduled for this asset
    SELECT COUNT(*)
    INTO v_future_flights
    FROM AllocationContext
    WHERE asset_id = p_asset_id
      AND end_date >= SYSDATE;
      
    IF v_future_flights > 0 THEN
      RAISE_APPLICATION_ERROR(-20021, 
        'Cannot deactivate asset "' || v_asset_name || '". ' ||
        'Has ' || v_future_flights || ' future flight(s) scheduled. ' ||
        'Please cancel or reschedule these flights before deactivating the asset.');
    END IF;
    
    -- Safety Check 2: Ensure there are no active reservations for this asset (redundant but extra safety)
    SELECT COUNT(DISTINCT aj.id)
    INTO v_active_reservations
    FROM AllocationJournal aj
    JOIN AllocationContext ac ON aj.context_id = ac.id
    WHERE ac.asset_id = p_asset_id
      AND ac.end_date >= SYSDATE
      AND aj.status IN ('reserved', 'confirmed', 'checked-in', 'boarded');
      
    IF v_active_reservations > 0 THEN
      RAISE_APPLICATION_ERROR(-20006, 
        'Cannot deactivate asset "' || v_asset_name || '". ' ||
        'Has ' || v_active_reservations || ' active reservation(s) on future flights.');
    END IF;

    UPDATE ResourceAsset SET status = 'not active' WHERE id = p_asset_id;
    
    LogDebugMessage('Deactivated asset: ' || v_asset_name || ' (ID: ' || p_asset_id || ') - No future flights or active reservations');
    --COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK TO start_deactivate_asset;
      LogDebugMessage('Error deactivating asset: ' || SQLERRM);
      RAISE;
  END DeactivateAsset;

  FUNCTION GetFlightManifest(p_context_identifier IN VARCHAR2) RETURN SYS_REFCURSOR IS
    -- Availability/capacity query: passenger manifest for context.
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR
      SELECT aj.id, u.name as user_name, rc.name as category_name, ri.instance_identifier, aj.status, aj.entry_timestamp
      FROM AllocationJournal aj
      JOIN AllocationContext ac ON aj.context_id = ac.id
      JOIN Users u ON aj.user_id = u.id
      LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
      JOIN ResourceCategory rc ON ri.category_id = rc.id
      WHERE ac.context_identifier = p_context_identifier
      ORDER BY aj.entry_timestamp DESC;
    RETURN rc;
  END GetFlightManifest;

  PROCEDURE CheckInUser(p_journal_id IN NUMBER) IS
    --===========================================================================
    -- Transitions from 'confirmed' to 'checked-in' status.
    -- 
    -- TRANSACTION STRATEGY:
    -- AddAllocationJournal (autonomous) commits the journal + ActiveAllocation
    -- update immediately. No capacity delta (status transition only).
    --===========================================================================
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_user_id NUMBER;
    v_resource_instance_id NUMBER;
    v_current_status VARCHAR2(20);
    v_new_journal_id NUMBER;
  BEGIN
    LogDebugMessage('Attempting to check-in user for journal ID: ' || p_journal_id);
    
    BEGIN
      SELECT context_id, category_id, user_id, resource_instance_id, status
      INTO v_context_id, v_category_id, v_user_id, v_resource_instance_id, v_current_status
      FROM CurrentAllocations WHERE journal_id = p_journal_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20010, 'Check-in failed. Reservation not found.');
    END;

    IF v_current_status != 'confirmed' THEN
      RAISE_APPLICATION_ERROR(-20010, 'Check-in failed. Not in confirmed state. Current status: ' || v_current_status);
    END IF;
    
    ResourceManagement_Data.AddAllocationJournal(
      p_context_id => v_context_id,
      p_category_id => v_category_id,
      p_user_id => v_user_id,
      p_resource_instance_id => v_resource_instance_id,
      p_status => 'checked-in',
      p_metadata => NULL,
      p_journal_id => v_new_journal_id
    );
    
    LogDebugMessage('Successfully checked in user for journal ID: ' || p_journal_id);
  END CheckInUser;

  PROCEDURE CancelCheckIn(p_journal_id IN NUMBER) IS
    --===========================================================================
    -- Reverts check-in from 'checked-in' back to 'confirmed' (INVERSE operation).
    -- 
    -- TRANSACTION STRATEGY:
    -- AddAllocationJournal (autonomous) commits the journal + ActiveAllocation
    -- update immediately. No capacity delta (status transition only).
    --===========================================================================
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_user_id NUMBER;
    v_resource_instance_id NUMBER;
    v_current_status VARCHAR2(20);
    v_new_journal_id NUMBER;
  BEGIN
    LogDebugMessage('Attempting to cancel check-in for journal ID: ' || p_journal_id);
    
    BEGIN
      SELECT context_id, category_id, user_id, resource_instance_id, status
      INTO v_context_id, v_category_id, v_user_id, v_resource_instance_id, v_current_status
      FROM CurrentAllocations WHERE journal_id = p_journal_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20011, 'Cancel check-in failed. Reservation not found.');
    END;

    IF v_current_status != 'checked-in' THEN
      RAISE_APPLICATION_ERROR(-20011, 'Cancel check-in failed. Not in checked-in state. Current status: ' || v_current_status);
    END IF;
    
    ResourceManagement_Data.AddAllocationJournal(
      p_context_id => v_context_id,
      p_category_id => v_category_id,
      p_user_id => v_user_id,
      p_resource_instance_id => v_resource_instance_id,
      p_status => 'confirmed',
      p_metadata => NULL,
      p_journal_id => v_new_journal_id
    );
    
    LogDebugMessage('Successfully cancelled check-in for journal ID: ' || p_journal_id);
  END CancelCheckIn;

  PROCEDURE BoardUser(p_journal_id IN NUMBER) IS
    --===========================================================================
    -- Transitions from 'checked-in' to 'boarded' status.
    -- 
    -- TRANSACTION STRATEGY:
    -- AddAllocationJournal (autonomous) commits the journal + ActiveAllocation
    -- update immediately. No capacity delta (status transition only).
    --===========================================================================
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_user_id NUMBER;
    v_resource_instance_id NUMBER;
    v_current_status VARCHAR2(20);
    v_new_journal_id NUMBER;
  BEGIN
    LogDebugMessage('Attempting to board user for journal ID: ' || p_journal_id);
    
    BEGIN
      SELECT context_id, category_id, user_id, resource_instance_id, status
      INTO v_context_id, v_category_id, v_user_id, v_resource_instance_id, v_current_status
      FROM CurrentAllocations WHERE journal_id = p_journal_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20012, 'Boarding failed. Reservation not found.');
    END;

    IF v_current_status != 'checked-in' THEN
      RAISE_APPLICATION_ERROR(-20012, 'Boarding failed. Not in checked-in state. Current status: ' || v_current_status);
    END IF;
    
    ResourceManagement_Data.AddAllocationJournal(
      p_context_id => v_context_id,
      p_category_id => v_category_id,
      p_user_id => v_user_id,
      p_resource_instance_id => v_resource_instance_id,
      p_status => 'boarded',
      p_metadata => NULL,
      p_journal_id => v_new_journal_id
    );
    
    LogDebugMessage('Successfully boarded user for journal ID: ' || p_journal_id);
  END BoardUser;

  PROCEDURE DeboardUser(p_journal_id IN NUMBER) IS
    --===========================================================================
    -- Reverts boarding from 'boarded' back to 'checked-in' (INVERSE operation).
    -- 
    -- TRANSACTION STRATEGY:
    -- AddAllocationJournal (autonomous) commits the journal + ActiveAllocation
    -- update immediately. No capacity delta (status transition only).
    --===========================================================================
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_user_id NUMBER;
    v_resource_instance_id NUMBER;
    v_current_status VARCHAR2(20);
    v_new_journal_id NUMBER;
  BEGIN
    LogDebugMessage('Attempting to deboard user for journal ID: ' || p_journal_id);
    
    BEGIN
      SELECT context_id, category_id, user_id, resource_instance_id, status
      INTO v_context_id, v_category_id, v_user_id, v_resource_instance_id, v_current_status
      FROM CurrentAllocations WHERE journal_id = p_journal_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20013, 'Deboarding failed. Reservation not found.');
    END;

    IF v_current_status != 'boarded' THEN
      RAISE_APPLICATION_ERROR(-20013, 'Deboarding failed. Not in boarded state. Current status: ' || v_current_status);
    END IF;
    
    ResourceManagement_Data.AddAllocationJournal(
      p_context_id => v_context_id,
      p_category_id => v_category_id,
      p_user_id => v_user_id,
      p_resource_instance_id => v_resource_instance_id,
      p_status => 'checked-in',
      p_metadata => NULL,
      p_journal_id => v_new_journal_id
    );
    
    LogDebugMessage('Successfully deboarded user for journal ID: ' || p_journal_id);
  END DeboardUser;

  PROCEDURE BlockResource(
    p_context_identifier IN VARCHAR2,
    p_resource_instance_id IN NUMBER,
    p_reason IN VARCHAR2 DEFAULT NULL,
    p_metadata IN CLOB DEFAULT NULL,
    p_new_journal_id OUT NUMBER
  ) IS
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_instance_category_id NUMBER;
    v_current_status VARCHAR2(20);
    v_has_active NUMBER := 0;
    v_active_delta NUMBER := 0;
    v_journal_metadata CLOB;
  BEGIN
    -- Resolve context
    BEGIN
      SELECT id INTO v_context_id
      FROM AllocationContext
      WHERE context_identifier = p_context_identifier;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20030, 'Context not found: ' || p_context_identifier);
    END;

    -- Resolve resource instance and category
    BEGIN
      SELECT category_id INTO v_instance_category_id
      FROM ResourceInstance
      WHERE id = p_resource_instance_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20031, 'Resource instance not found: ' || p_resource_instance_id);
    END;

    v_category_id := v_instance_category_id;

    -- Check if there is already an active entry for this (context, instance)
    BEGIN
      SELECT status INTO v_current_status
      FROM CurrentAllocations
      WHERE context_id = v_context_id
        AND resource_instance_id = p_resource_instance_id;
      v_has_active := 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        v_has_active := 0;
    END;

    IF v_has_active = 0 THEN
      v_active_delta := 1;
    END IF;

    -- Journal metadata: use p_metadata if provided, else build from p_reason
    v_journal_metadata := p_metadata;
    IF v_journal_metadata IS NULL AND p_reason IS NOT NULL THEN
      v_journal_metadata := '{"block_reason": "' || REPLACE(p_reason, '"', '\"') || '"}';
    END IF;

    ResourceManagement_Data.AddAllocationJournal(
      p_context_id => v_context_id,
      p_category_id => v_category_id,
      p_user_id => NULL,
      p_resource_instance_id => p_resource_instance_id,
      p_status => 'blocked',
      p_metadata => v_journal_metadata,
      p_journal_id => p_new_journal_id
    );

    IF v_active_delta != 0 AND GetAllocationModeForCategory(v_category_id) = 'pool' THEN
      ResourceManagement_Data.IncrementCapacityCounter(
        p_context_id => v_context_id,
        p_category_id => v_category_id,
        p_active_delta => v_active_delta
      );
    END IF;
  END BlockResource;

  PROCEDURE UnblockResource(
    p_journal_id IN NUMBER,
    p_reason IN VARCHAR2 DEFAULT NULL,
    p_new_journal_id OUT NUMBER
  ) IS
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_resource_instance_id NUMBER;
    v_current_status VARCHAR2(20);
  BEGIN
    -- Validate current status is blocked
    BEGIN
      SELECT context_id, category_id, resource_instance_id, status
      INTO v_context_id, v_category_id, v_resource_instance_id, v_current_status
      FROM CurrentAllocations
      WHERE journal_id = p_journal_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20032, 'Blocked allocation not found for journal ID: ' || p_journal_id);
    END;

    IF v_current_status != 'blocked' THEN
      RAISE_APPLICATION_ERROR(-20033, 'Unblock failed. Current status is not blocked: ' || v_current_status);
    END IF;

    ResourceManagement_Data.AddAllocationJournal(
      p_context_id => v_context_id,
      p_category_id => v_category_id,
      p_user_id => NULL,
      p_resource_instance_id => v_resource_instance_id,
      p_status => 'cancelled',
      p_metadata => CASE
        WHEN p_reason IS NULL THEN NULL
        ELSE '{"unblock_reason": "' || REPLACE(p_reason, '"', '\"') || '"}'
      END,
      p_journal_id => p_new_journal_id
    );

    IF GetAllocationModeForCategory(v_category_id) = 'pool' THEN
      ResourceManagement_Data.IncrementCapacityCounter(
        p_context_id => v_context_id,
        p_category_id => v_category_id,
        p_active_delta => -1
      );
    END IF;
  END UnblockResource;

  PROCEDURE CancelFlight(p_context_identifier IN VARCHAR2, p_reason IN VARCHAR2) IS
    -- Cancels an entire flight and all associated reservations atomically.
    -- Blocks ALL resources of the asset associated with the context (not just currently allocated ones).
    -- Updates AllocationContext metadata and creates audit trail.
    -- On failure: rollback capacity + compensate all committed block journals.
    v_context_id NUMBER;
    v_asset_id NUMBER;
    v_blocked_count NUMBER := 0;
    v_current_metadata CLOB;
    v_cancellation_metadata CLOB;
    v_journal_metadata CLOB;
    v_block_journal_id NUMBER;
    -- Track all committed block journal IDs for compensation on failure
    v_committed_journal_ids SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
  BEGIN
    LogDebugMessage('=== Starting CancelFlight ===');
    LogDebugMessage('Context: ' || p_context_identifier || ', Reason: ' || p_reason);
    
    -- Validate flight exists and get context + asset
    BEGIN
      SELECT id, asset_id INTO v_context_id, v_asset_id
      FROM AllocationContext
      WHERE context_identifier = p_context_identifier;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20500, 'Flight not found: ' || p_context_identifier);
    END;

    SAVEPOINT start_flight_cancellation;
    
    v_journal_metadata := JSON_OBJECT(
      'source' VALUE 'flight_cancellation',
      'context_identifier' VALUE p_context_identifier,
      'reason' VALUE p_reason,
      'message' VALUE 'Flight "' || p_context_identifier || '" was cancelled by the system. Reason: ' || p_reason
    );
    
    -- Block ALL resources of the asset associated with this context
    IF v_asset_id IS NOT NULL THEN
      DECLARE
        TYPE t_instance_ids IS TABLE OF NUMBER;
        v_resource_instance_ids t_instance_ids;
      BEGIN
        SELECT id
        BULK COLLECT INTO v_resource_instance_ids
        FROM ResourceInstance
        WHERE asset_id = v_asset_id
        ORDER BY id;
        FOR i IN 1..v_resource_instance_ids.COUNT LOOP
          BlockResource(
            p_context_identifier => p_context_identifier,
            p_resource_instance_id => v_resource_instance_ids(i),
            p_reason => NULL,
            p_metadata => v_journal_metadata,
            p_new_journal_id => v_block_journal_id
          );
          v_committed_journal_ids.EXTEND;
          v_committed_journal_ids(v_committed_journal_ids.LAST) := v_block_journal_id;
          v_blocked_count := v_blocked_count + 1;
        END LOOP;
      END;
    ELSE
      -- Direct allocation context (no asset): block only currently allocated resources
      DECLARE
        TYPE t_instance_ids IS TABLE OF NUMBER;
        v_resource_instance_ids t_instance_ids;
      BEGIN
        SELECT ca.resource_instance_id
        BULK COLLECT INTO v_resource_instance_ids
        FROM CurrentAllocations ca
        WHERE ca.context_id = v_context_id
          AND ca.status IN ('reserved', 'confirmed', 'checked-in', 'boarded')
          AND ca.resource_instance_id IS NOT NULL
        ORDER BY ca.journal_id;
        FOR i IN 1..v_resource_instance_ids.COUNT LOOP
          BlockResource(
            p_context_identifier => p_context_identifier,
            p_resource_instance_id => v_resource_instance_ids(i),
            p_reason => NULL,
            p_metadata => v_journal_metadata,
            p_new_journal_id => v_block_journal_id
          );
          v_committed_journal_ids.EXTEND;
          v_committed_journal_ids(v_committed_journal_ids.LAST) := v_block_journal_id;
          v_blocked_count := v_blocked_count + 1;
        END LOOP;
      END;
    END IF;

    -- Mark the AllocationContext as cancelled in metadata
    SELECT metadata INTO v_current_metadata
    FROM AllocationContext
    WHERE id = v_context_id;
    
    v_cancellation_metadata := JSON_OBJECT(
      'status' VALUE 'cancelled',
      'cancellation_timestamp' VALUE TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZH:TZM'),
      'cancellation_reason' VALUE p_reason,
      'resources_blocked' VALUE v_blocked_count,
      'original_metadata' VALUE v_current_metadata
    );
    
    UPDATE AllocationContext
    SET metadata = v_cancellation_metadata
    WHERE id = v_context_id;

    -- TODO: NOTIFICATION REQUIRED - Send general cancellation notification
    -- Notification Type: 'FLIGHT_CANCELLED_ANNOUNCEMENT'
    -- Flight: p_context_identifier
    -- Resources blocked: v_blocked_count
    -- Reason: p_reason
    -- Use case: Public announcement, update displays, alert crew, etc.

    LogDebugMessage('Successfully blocked ' || v_blocked_count || ' resources');
    LogDebugMessage('=== CancelFlight SUCCESSFUL ===');
    --COMMIT;
      
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK TO start_flight_cancellation;
      -- Compensate all committed block journals (capacity already rolled back)
      FOR j IN 1..v_committed_journal_ids.COUNT LOOP
        CompensateJournalEntry(v_committed_journal_ids(j), 'cancelled', 'flight_cancel_failed: ' || SQLERRM);
      END LOOP;
      LogDebugMessage('=== CancelFlight FAILED ===');
      LogDebugMessage('Error: ' || SQLERRM);
      RAISE_APPLICATION_ERROR(-20501, 
        'Failed to cancel flight ' || p_context_identifier || ': ' || SQLERRM ||
        ' (All changes rolled back, ' || v_committed_journal_ids.COUNT || ' journals compensated)');
  END CancelFlight;

  PROCEDURE RescheduleFlight(p_context_id IN NUMBER, p_new_start_date IN DATE, p_new_end_date IN DATE) IS
    -- Updates the departure and arrival times for a flight. Counts affected passengers for notification purposes.
    v_context_identifier VARCHAR2(100);
    v_affected_users NUMBER := 0;
  BEGIN
    SAVEPOINT start_reschedule_flight;
    
    LogDebugMessage('Rescheduling flight for context ID: ' || p_context_id);
    
    -- Get context identifier for notifications
    SELECT context_identifier INTO v_context_identifier 
    FROM AllocationContext 
    WHERE id = p_context_id;
    
    -- Count affected users
    SELECT COUNT(DISTINCT user_id) INTO v_affected_users
    FROM CurrentAllocations
    WHERE context_id = p_context_id
      AND status IN ('reserved', 'confirmed', 'checked-in');
    
    UPDATE AllocationContext
    SET start_date = p_new_start_date, end_date = p_new_end_date
    WHERE id = p_context_id;
    
    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20017, 'Failed to reschedule. Context ID not found: ' || p_context_id);
    END IF;
    
    -- TODO: NOTIFICATION REQUIRED - Flight reschedule notification
    -- Context ID: p_context_id
    -- Flight: v_context_identifier
    -- Old Dates: (stored in metadata or query before update)
    -- New Start: p_new_start_date
    -- New End: p_new_end_date
    -- Affected Users: v_affected_users
    -- Notification Type: 'FLIGHT_RESCHEDULED'
    -- Notify all passengers with active reservations
    
    LogDebugMessage('Successfully rescheduled flight ' || v_context_identifier || ', affecting ' || v_affected_users || ' users');
    --COMMIT;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      ROLLBACK TO start_reschedule_flight;
      RAISE_APPLICATION_ERROR(-20017, 'Failed to reschedule. Context ID not found: ' || p_context_id);
    WHEN OTHERS THEN
      ROLLBACK TO start_reschedule_flight;
      LogDebugMessage('Error rescheduling flight: ' || SQLERRM);
      RAISE;
  END RescheduleFlight;

  PROCEDURE ChangeAircraft(p_context_id IN NUMBER, p_new_asset_id IN NUMBER) IS
    -- Changes the aircraft for a scheduled flight. WARNING: Incomplete implementation - requires capacity validation and seat reassignment logic.
    v_old_asset_id NUMBER;
    CURSOR c_capacities(p_asset_id NUMBER) IS SELECT category_id, quantity FROM AssetCapacity WHERE asset_id = p_asset_id;
    v_new_capacity NUMBER;
    v_old_capacity NUMBER;
    v_booked_count NUMBER;
  BEGIN
    LogDebugMessage('Changing aircraft for context ID: ' || p_context_id || ' to new asset ID: ' || p_new_asset_id);
    
    SELECT asset_id INTO v_old_asset_id FROM AllocationContext WHERE id = p_context_id;

    -- COMPLEXITY: This procedure is highly complex in a real-world scenario.
    -- The main challenge is handling capacity differences between the old and new asset.
    -- The logic below is a simplified check. A full implementation would need to
    -- define business rules for how to handle overbookings (e.g., who to bump,
    -- move to other flights, etc.).

    FOR old_cap_rec IN c_capacities(v_old_asset_id) LOOP
      -- Get new capacity for the same category
      BEGIN
        SELECT quantity INTO v_new_capacity 
        FROM AssetCapacity 
        WHERE asset_id = p_new_asset_id AND category_id = old_cap_rec.category_id;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          v_new_capacity := 0; -- New aircraft doesn't have this category
      END;

      -- Get current bookings for this category using CurrentAllocations
      SELECT COUNT(*) INTO v_booked_count
      FROM CurrentAllocations
      WHERE context_id = p_context_id
        AND category_id = old_cap_rec.category_id
        AND status IN ('reserved', 'confirmed', 'checked-in', 'boarded');

      IF v_booked_count > v_new_capacity THEN
        RAISE_APPLICATION_ERROR(-20018, 'Aircraft change failed. New aircraft has insufficient capacity for category ' || old_cap_rec.category_id || '. Booked: ' || v_booked_count || ', New Capacity: ' || v_new_capacity);
      END IF;
    END LOOP;

    -- If all capacity checks pass, update the asset
    UPDATE AllocationContext
    SET asset_id = p_new_asset_id
    WHERE id = p_context_id;
    
    LogDebugMessage('Successfully changed aircraft for context ID: ' || p_context_id);
    --COMMIT;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20019, 'Context ID not found: ' || p_context_id);
    WHEN OTHERS THEN
      LogDebugMessage('Failed to change aircraft for context ID: ' || p_context_id || '. Error: ' || SQLERRM);
      ROLLBACK;
      RAISE;
  END ChangeAircraft;

  --==============================================================================
  --==============================================================================
  -- Type substitution (FindSubstitutions – query only; offer flow above)
  --==============================================================================
  FUNCTION FindSubstitutions(
    p_context_identifier IN VARCHAR2,
    p_category_name IN VARCHAR2
  ) RETURN SYS_REFCURSOR IS
    --===========================================================================
    -- Finds available substitutions when the requested category is unavailable.
    -- 
    -- Returns a cursor with substitution options including:
    --   - Target category name and type (upgrade/downgrade/lateral)
    --   - Cost adjustment (positive = user pays more, negative = refund)
    --   - Available capacity in target category
    --   - Priority (lower = offer first)
    --   - Whether auto-offer is enabled
    --
    -- Example usage:
    --   DECLARE
    --     v_subs SYS_REFCURSOR;
    --   BEGIN
    --     v_subs := ResourceManagement.FindSubstitutions('LH710', 'Economy');
    --     -- Process cursor to offer alternatives to user
    --   END;
    --===========================================================================
    v_context_id NUMBER;
    v_category_id NUMBER;
    v_available_count NUMBER;
    rc SYS_REFCURSOR;
  BEGIN
    LogDebugMessage('FindSubstitutions for ' || p_context_identifier || ', category: ' || p_category_name);
    
    -- Resolve context and category IDs
    BEGIN
      SELECT ac.id INTO v_context_id
      FROM AllocationContext ac
      WHERE ac.context_identifier = p_context_identifier;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20710, 'Context not found: ' || p_context_identifier);
    END;
    
    BEGIN
      SELECT id INTO v_category_id
      FROM ResourceCategory
      WHERE name = p_category_name;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20711, 'Category not found: ' || p_category_name);
    END;
    
    -- Check if the requested category actually has no availability
    SELECT NVL(total_capacity - active_count, 0) INTO v_available_count
    FROM Capacity
    WHERE context_id = v_context_id AND category_id = v_category_id;
    
    IF v_available_count > 0 THEN
      LogDebugMessage('Category ' || p_category_name || ' still has ' || v_available_count || ' available');
    END IF;
    
    -- Return available substitutions with capacity
    rc := ResourceManagement_Data.GetAvailableSubstitutionsForContext(v_context_id, v_category_id);
    
    RETURN rc;
  EXCEPTION
    WHEN OTHERS THEN
      LogDebugMessage('Error in FindSubstitutions: ' || SQLERRM);
      RAISE;
  END FindSubstitutions;

  --==============================================================================
  -- Workflow integration (Oracle AQ, collaboration)
  --==============================================================================
  PROCEDURE send_event(
    p_payload                in varchar2)
is
    -- Enqueues an event payload to the workflow queue for async processing. Used for workflow integration.
    l_enqueue_options        dbms_aq.enqueue_options_t;
    l_message_properties     dbms_aq.message_properties_t;
    l_msgid                  raw(16);
    l_payload                sys.aq$_jms_text_message;
    l_recipients             dbms_aq.aq$_recipient_list_t;
begin
    l_payload                := sys.aq$_jms_text_message.construct();
    l_payload.set_text(p_payload);

    -- For multi-consumer queue, specify the recipient
    l_recipients := DBMS_AQ.AQ$_RECIPIENT_LIST_T(
        SYS.AQ$_AGENT('WF_USER_EVENTS_QC', NULL, NULL));
    l_message_properties.recipient_list := l_recipients;

    dbms_aq.enqueue(
        queue_name           => c_wf_user_events_q,
        enqueue_options      => l_enqueue_options,
        message_properties   => l_message_properties,
        payload              => l_payload,
        msgid                => l_msgid);
    COMMIT;
end send_event;

procedure create_collaboration(
    p_event_id               in varchar2,
    p_workflow_id            in number,
    p_collaboration_name     in varchar2,
    p_data                   in clob)
is
    -- Creates a workflow collaboration record to track async workflow activities and their state.
begin
    insert
      into WorkflowCollaboration(
            event_id,
            workflow_id,
            collaboration_name,
            collaboration_start,
            event_data,
            state)
     values (
            p_event_id,
            p_workflow_id,
            p_collaboration_name,
            systimestamp,
            p_data,
            'Started');
exception
    when others then
        LogDebugMessage('create_collaboration error: ' || sqlerrm || ' for event_id: ' || p_event_id || ', workflow_id: ' || p_workflow_id);

end create_collaboration;

procedure complete_collaboration(
    p_workflow_id            in number,
    p_collaboration_name     in varchar2,
    p_activity_static_id     in varchar2)
is
    -- Marks a workflow collaboration as completed, updating its state and recording the end timestamp.
begin
    update WorkflowCollaboration
       set state              = 'Completed',
           activity_static_id = p_activity_static_id,
           collaboration_end  = systimestamp
     where workflow_id        = p_workflow_id
       and collaboration_name = p_collaboration_name;
end complete_collaboration;


procedure start_workflow_event(
    p_event                  in sys.json_object_t)
is
    l_application_id         number;
    l_workflow_id            number;
    l_workflow_static_id     varchar2(255);
    l_workflow_initiator     varchar2(255);
    l_workflow_parameters    apex_workflow.t_workflow_parameters;
    l_collaboration_name     varchar2(255);
    l_data                   sys.json_object_t;
    l_data_keys              sys.json_key_list;
begin
    l_application_id         := p_event.get_number(ce_event_application_id);
    l_workflow_static_id     := p_event.get_string(ce_event_workflow_static_id);
    l_workflow_initiator     := p_event.get_string(ce_event_workflow_initiator);
    l_collaboration_name     := p_event.get_string(ce_event_collaboration_name);
    l_data                   := p_event.get_object(ce_event_data);
    l_data_keys              := l_data.get_keys;

    for i in 1 .. l_data_keys.count loop
        l_workflow_parameters(i) := 
            apex_workflow.t_workflow_parameter(
                static_id    => l_data_keys(i),
                string_value => l_data.get_string(l_data_keys(i)));
    end loop;

    LogDebugMessage('Start Workflow ' || l_workflow_static_id || ', application ' || l_application_id || ', collaboration ' || l_collaboration_name || ', event_id ' || p_event.get_string(ce_event_id));

    apex_session.create_session(
        p_app_id            => l_application_id,
        p_page_id           => 0,
        p_username          => l_workflow_initiator);

    l_workflow_id := apex_workflow.start_workflow(
        p_application_id     => l_application_id,
        p_static_id          => l_workflow_static_id,
        p_parameters         => l_workflow_parameters,
        p_detail_pk          => p_event.get_string(ce_event_workflow_detail_pk),
        p_initiator          => l_workflow_initiator);

    -- create collaboration
    create_collaboration(
        p_event_id           => p_event.get_string(ce_event_id),
        p_workflow_id        => l_workflow_id,
        p_collaboration_name => l_collaboration_name,
        p_data               => l_data.to_clob);

    dbms_output.put_line('Started Workflow ' || l_workflow_static_id || ', instance id: ' || l_workflow_id);

    apex_session.delete_session;
exception
    when others then
        LogDebugMessage(
            p_message => 'start_workflow error ' || dbms_utility.format_error_backtrace);

end start_workflow_event;

procedure send_message_event(
    p_event                  in sys.json_object_t)
is
    l_application_id         number;
    l_workflow_id            number;
    l_workflow_static_id     varchar2(255);
    l_collaboration_name     varchar2(255);
    l_activity_static_id     varchar2(255);
    l_params                 wwv_flow_global.vc_map;
begin
    l_application_id         := p_event.get_number(ce_event_application_id);
    l_workflow_static_id     := p_event.get_string(ce_event_workflow_static_id);
    l_workflow_id            := p_event.get_number(ce_event_workflow_id);
    l_collaboration_name     := p_event.get_string(ce_event_collaboration_name);
    l_activity_static_id     := p_event.get_string(ce_event_activity_static_id);

    LogDebugMessage('Send Message for ' || l_collaboration_name || ', application ' || l_application_id || ', workflow ID ' || l_workflow_id || ', activity ' || l_activity_static_id || ', event_id ' || p_event.get_string(ce_event_id));

    apex_session.create_session(
        p_app_id            => l_application_id,
        p_page_id           => 0,
        p_username          => null);

    apex_workflow.continue_activity(
        p_instance_id        => l_workflow_id,
        p_static_id          => l_activity_static_id,
        p_activity_params    => l_params);

    dbms_output.put_line('Send Message ' || l_collaboration_name || ', workflow id: ' || l_workflow_id);

    apex_session.delete_session;
exception
    when others then
        LogDebugMessage(
            p_message => 'send_message error ' || dbms_utility.format_error_backtrace);
end send_message_event;

procedure handle_payload(
    p_payload                in varchar2)
is
    l_json_payload           sys.json_object_t;
    l_ce_event_type          varchar2(255);
    l_journal_id             number;
    v_current_status         varchar2(20);
begin
    LogDebugMessage('handle_payload received: ' || p_payload);
    l_json_payload           := sys.json_object_t(p_payload);

    if l_json_payload.has(ce_event_type) then
        -- This looks like a CloudEvent for the workflow
        l_ce_event_type := l_json_payload.get_string(ce_event_type);
        LogDebugMessage('Payload is a CloudEvent with type: ' || l_ce_event_type);

        case l_ce_event_type
            when ce_event_type_start_workflow then
                start_workflow_event(p_event => l_json_payload);
            when ce_event_type_send_message then
                send_message_event(p_event => l_json_payload);
            else
                LogDebugMessage('Unsupported CloudEvent Type: ' || l_ce_event_type);
                dbms_output.put_line('Unsupported Event Type ' || l_ce_event_type);
        end case;

    elsif l_json_payload.has('journal_id') then
        -- This is a timeout message for a reservation
        l_journal_id := l_json_payload.get_number('journal_id');
        LogDebugMessage('Payload is a timeout message for journal_id: ' || l_journal_id);

        begin
            -- Check current status using CurrentAllocations view
            select status into v_current_status 
            from CurrentAllocations 
            where journal_id = l_journal_id;

            if v_current_status = 'reserved' then
                CancelReservation(
                  p_journal_id => l_journal_id,
                  p_cancellation_metadata => '{"source": "timeout", "message": "Reservation cancelled due to timeout"}'
                );
                LogDebugMessage('Reservation cancelled due to timeout for journal_id: ' || l_journal_id);
            else
                LogDebugMessage('Timeout arrived for journal_id ' || l_journal_id || ', but status was already "' || v_current_status || '". No action taken.');
            end if;
        exception
            when no_data_found then
                LogDebugMessage('Timeout arrived for journal_id ' || l_journal_id || ', but the allocation was not found or already cancelled.');
        end;
    
    else
        LogDebugMessage('Unknown payload format received in handle_payload: ' || p_payload);
    end if;
exception
    when others then
        LogDebugMessage('handle_payload error: ' || sqlerrm || ' -- Payload: ' || p_payload);
        -- Re-raising here would cause AQ to retry, which could be bad for a malformed message.
        -- For debugging, we log and consume. For production, consider an exception queue.
end handle_payload;

procedure user_events_callback(
    context                  raw,
    reginfo                  sys.aq$_reg_info,
    descr                    sys.aq$_descriptor,
    payload                  raw,
    payloadl                 number)
is
    -- Oracle AQ callback procedure that processes timeout messages from the queue.
    -- Automatically cancels unpaid reservations when their timeout period expires (Use Case 4).
    -- This callback is triggered when delayed messages transition from WAITING (state 1) to READY (state 0).
    l_dequeue_options        dbms_aq.dequeue_options_t;
    l_message_properties     dbms_aq.message_properties_t;
    l_message_handle         raw(16);
    l_payload                sys.aq$_jms_text_message;
    l_payload_text           varchar2(32767);
    e_no_messages            exception;
    pragma exception_init(e_no_messages, -25228);
begin
    LogDebugMessage('user_events_callback invoked on queue: ' || descr.queue_name || ' for msgid: ' || rawtohex(descr.msg_id) || ', consumer: ' || descr.consumer_name);
    
    -- Set dequeue options properly for callback-triggered dequeue
    -- CRITICAL: When msgid is specified, don't set navigation to first_message
    l_dequeue_options.msgid            := descr.msg_id;
    l_dequeue_options.consumer_name    := descr.consumer_name;
    l_dequeue_options.wait             := dbms_aq.no_wait;  -- Don't wait for messages
    l_dequeue_options.visibility       := dbms_aq.immediate;  -- Immediate visibility (default, but explicit for clarity)
    -- NOTE: navigation is not set when msgid is provided - this is correct
    
    loop
        begin
            -- (1.) Dequeue payload from WF_USER_EVENTS_Q
            LogDebugMessage('Attempting to dequeue message...');
            dbms_aq.dequeue(
                queue_name         => descr.queue_name,
                dequeue_options    => l_dequeue_options,
                message_properties => l_message_properties,
                payload            => l_payload,
                msgid              => l_message_handle);
            
            LogDebugMessage('Message dequeued successfully. Message ID: ' || rawtohex(l_message_handle));
            
            -- (2.) Interpret the payload
            l_payload.get_text(l_payload_text);
            LogDebugMessage('Message payload: ' || l_payload_text);
            handle_payload(l_payload_text);
        
            -- (3.) Commit the message (remove from queue)
            commit;
            LogDebugMessage('Message processed and committed.');
            
            -- After processing the specific message, exit the loop
            exit;
        exception
            when e_no_messages then
                LogDebugMessage('No more messages in queue.');
                commit;
                exit;
        end;
    end loop;
    
    LogDebugMessage('user_events_callback completed successfully.');
exception
    when others then
        LogDebugMessage('user_events_callback FATAL ERROR: ' || sqlerrm || ' | Backtrace: ' || dbms_utility.format_error_backtrace);
        rollback;
        -- Don't re-raise to prevent callback from being disabled
end user_events_callback;

END ResourceManagement;
/

show err;