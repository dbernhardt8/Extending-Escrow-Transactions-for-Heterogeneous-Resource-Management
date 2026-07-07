-- =============================================================================
-- 3.2_crud_body.pkb
--
-- DATA ACCESS LAYER - Package Body (CRUD Operations)
-- ===================================================
-- This package implements basic Create, Read, Update, Delete operations
-- for all database tables without complex business logic.
--
-- KEY IMPLEMENTATION DETAILS:
-- - AddAllocationJournal: Uses PRAGMA AUTONOMOUS_TRANSACTION to ensure
--   journal entries are committed immediately (audit trail durability)
-- - IncrementCapacityCounter: Updates RESERVABLE columns with delta-based
--   changes for lock-free high-concurrency counter management
--
-- All procedures are domain-agnostic; domain-specific logic resides in
-- the ResourceManagement package (Business Logic Layer).
-- =============================================================================

CREATE OR REPLACE PACKAGE BODY ResourceManagement_Data AS

  --==============================================================================
  -- Utility Operations
  --==============================================================================
  PROCEDURE LogDebugMessage(p_message IN VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    AddDebugLog(p_message => p_message, p_metadata => NULL);
    COMMIT;
  END LogDebugMessage;

  --==============================================================================
  -- Resource Category Operations
  --==============================================================================
  PROCEDURE AddResourceCategory(
    p_name IN VARCHAR2, 
    p_description IN VARCHAR2,
    p_allocation_mode IN VARCHAR2 DEFAULT 'pool',
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    -- Validate allocation_mode
    IF p_allocation_mode NOT IN ('pool', 'direct') THEN
      RAISE_APPLICATION_ERROR(-20050, 'Invalid allocation_mode: ' || p_allocation_mode || '. Must be ''pool'' or ''direct''.');
    END IF;
    
    INSERT INTO ResourceCategory (id, name, description, allocation_mode, metadata)
    VALUES (ResourceCategory_seq.NEXTVAL, p_name, p_description, p_allocation_mode, p_metadata);
  END AddResourceCategory;

  PROCEDURE UpdateResourceCategory(
    p_id IN NUMBER, 
    p_name IN VARCHAR2, 
    p_description IN VARCHAR2,
    p_allocation_mode IN VARCHAR2 DEFAULT NULL,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    -- Validate allocation_mode if provided
    IF p_allocation_mode IS NOT NULL AND p_allocation_mode NOT IN ('pool', 'direct') THEN
      RAISE_APPLICATION_ERROR(-20050, 'Invalid allocation_mode: ' || p_allocation_mode || '. Must be ''pool'' or ''direct''.');
    END IF;
    
    UPDATE ResourceCategory
    SET name = p_name, 
        description = p_description,
        allocation_mode = NVL(p_allocation_mode, allocation_mode),
        metadata = p_metadata
    WHERE id = p_id;
  END UpdateResourceCategory;

  PROCEDURE DeleteResourceCategory(p_id IN NUMBER) IS
  BEGIN
    DELETE FROM ResourceCategory WHERE id = p_id;
  END DeleteResourceCategory;

  FUNCTION GetResourceCategory(p_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR
    SELECT * FROM ResourceCategory WHERE id = p_id;
    RETURN rc;
  END GetResourceCategory;
  
  FUNCTION GetCategoryAllocationMode(p_category_id IN NUMBER) RETURN VARCHAR2 IS
    v_mode VARCHAR2(10);
  BEGIN
    SELECT allocation_mode INTO v_mode
    FROM ResourceCategory
    WHERE id = p_category_id;
    RETURN v_mode;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END GetCategoryAllocationMode;

  --==============================================================================
  -- Resource Status Operations
  --==============================================================================
  PROCEDURE AddResourceStatus(
    p_name IN VARCHAR2, 
    p_description IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    INSERT INTO ResourceStatus (name, description, metadata)
    VALUES (p_name, p_description, p_metadata);
  END AddResourceStatus;

  PROCEDURE UpdateResourceStatus(
    p_name IN VARCHAR2, 
    p_description IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    UPDATE ResourceStatus
    SET name = p_name, 
        description = p_description,
        metadata = p_metadata
    WHERE name = p_name;
  END UpdateResourceStatus;

  PROCEDURE DeleteResourceStatus(p_name IN VARCHAR2) IS
  BEGIN
    DELETE FROM ResourceStatus WHERE name = p_name;
  END DeleteResourceStatus;

  FUNCTION GetResourceStatus(p_name IN VARCHAR2) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR
    SELECT * FROM ResourceStatus WHERE name = p_name;
    RETURN rc;
  END GetResourceStatus;

  --==============================================================================
  -- Resource Instance Status Operations
  --==============================================================================
  PROCEDURE AddResourceInstanceStatus(
    p_name IN VARCHAR2, 
    p_description IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    INSERT INTO ResourceInstanceStatus (name, description, metadata)
    VALUES (p_name, p_description, p_metadata);
  END AddResourceInstanceStatus;

  PROCEDURE UpdateResourceInstanceStatus(
    p_name IN VARCHAR2, 
    p_description IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    UPDATE ResourceInstanceStatus
    SET name = p_name, 
        description = p_description,
        metadata = p_metadata
    WHERE name = p_name;
  END UpdateResourceInstanceStatus;

  PROCEDURE DeleteResourceInstanceStatus(p_name IN VARCHAR2) IS
  BEGIN
    DELETE FROM ResourceInstanceStatus WHERE name = p_name;
  END DeleteResourceInstanceStatus;

  FUNCTION GetResourceInstanceStatus(p_name IN VARCHAR2) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR
    SELECT * FROM ResourceInstanceStatus WHERE name = p_name;
    RETURN rc;
  END GetResourceInstanceStatus;

  --==============================================================================
  -- User Operations
  --==============================================================================
  PROCEDURE AddUser(
    p_name IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    INSERT INTO Users (id, name, metadata)
    VALUES (Users_seq.NEXTVAL, p_name, p_metadata);
  END AddUser;

  PROCEDURE UpdateUser(
    p_id IN NUMBER, 
    p_name IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    UPDATE Users
    SET name = p_name,
        metadata = p_metadata
    WHERE id = p_id;
  END UpdateUser;

  PROCEDURE DeleteUser(p_id IN NUMBER) IS
  BEGIN
    DELETE FROM Users WHERE id = p_id;
  END DeleteUser;

  FUNCTION GetUser(p_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR
    SELECT * FROM Users WHERE id = p_id;
    RETURN rc;
  END GetUser;

  FUNCTION GetUserByName(p_name IN VARCHAR2) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR 
    SELECT * FROM Users WHERE name = p_name;
    RETURN rc;
  END GetUserByName;

  --==============================================================================
  -- Resource Asset Operations
  --==============================================================================
  PROCEDURE AddResourceAsset(
    p_name IN VARCHAR2, 
    p_description IN VARCHAR2, 
    p_status IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    INSERT INTO ResourceAsset(id, name, description, status, metadata)
    VALUES (ResourceAsset_seq.NEXTVAL, p_name, p_description, p_status, p_metadata);
  END AddResourceAsset;

  PROCEDURE UpdateResourceAsset(
    p_asset_id IN NUMBER, 
    p_name IN VARCHAR2, 
    p_description IN VARCHAR2, 
    p_status IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    UPDATE ResourceAsset
    SET name = p_name, 
        description = p_description, 
        status = p_status,
        metadata = p_metadata
    WHERE id = p_asset_id;
  END UpdateResourceAsset;
  
  PROCEDURE DeleteResourceAsset(p_asset_id IN NUMBER) IS
  BEGIN
    -- Add cascading delete logic if necessary, e.g., for capacities and contexts
    DELETE FROM ResourceAsset WHERE id = p_asset_id;
  END DeleteResourceAsset;

  FUNCTION GetResourceAsset(p_asset_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR SELECT * FROM ResourceAsset WHERE id = p_asset_id;
    RETURN rc;
  END GetResourceAsset;

  --==============================================================================
  -- Asset Capacity Operations
  --==============================================================================
  PROCEDURE AddAssetCapacity(
    p_asset_id IN NUMBER, 
    p_category_id IN NUMBER, 
    p_quantity IN NUMBER,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    INSERT INTO AssetCapacity(id, asset_id, category_id, quantity, metadata)
    VALUES (AssetCapacity_seq.NEXTVAL, p_asset_id, p_category_id, p_quantity, p_metadata);
  END AddAssetCapacity;

  PROCEDURE UpdateAssetCapacity(
    p_capacity_id IN NUMBER, 
    p_asset_id IN NUMBER, 
    p_category_id IN NUMBER, 
    p_quantity IN NUMBER,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    UPDATE AssetCapacity
    SET asset_id = p_asset_id, 
        category_id = p_category_id, 
        quantity = p_quantity,
        metadata = p_metadata
    WHERE id = p_capacity_id;
  END UpdateAssetCapacity;

  PROCEDURE DeleteAssetCapacity(p_capacity_id IN NUMBER) IS
  BEGIN
    DELETE FROM AssetCapacity WHERE id = p_capacity_id;
  END DeleteAssetCapacity;

  FUNCTION GetAssetCapacity(p_asset_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR SELECT * FROM AssetCapacity WHERE asset_id = p_asset_id;
    RETURN rc;
  END GetAssetCapacity;

  --==============================================================================
  -- Resource Instance Operations
  --==============================================================================
  PROCEDURE AddResourceInstance(
    p_asset_id IN NUMBER,
    p_category_id IN NUMBER,
    p_instance_identifier IN VARCHAR2,
    p_status IN VARCHAR2 DEFAULT 'available',
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    INSERT INTO ResourceInstance(id, asset_id, category_id, instance_identifier, status, metadata)
    VALUES (ResourceInstance_seq.NEXTVAL, p_asset_id, p_category_id, p_instance_identifier, p_status, p_metadata);
  END AddResourceInstance;

  PROCEDURE UpdateResourceInstance(
    p_id IN NUMBER,
    p_asset_id IN NUMBER,
    p_category_id IN NUMBER,
    p_instance_identifier IN VARCHAR2,
    p_status IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    UPDATE ResourceInstance
    SET asset_id = p_asset_id,
        category_id = p_category_id,
        instance_identifier = p_instance_identifier,
        status = p_status,
        metadata = p_metadata
    WHERE id = p_id;
  END UpdateResourceInstance;

  PROCEDURE DeleteResourceInstance(p_id IN NUMBER) IS
  BEGIN
    DELETE FROM ResourceInstance WHERE id = p_id;
  END DeleteResourceInstance;

  FUNCTION GetResourceInstance(p_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR SELECT * FROM ResourceInstance WHERE id = p_id;
    RETURN rc;
  END GetResourceInstance;

  FUNCTION GetResourceInstancesByAsset(p_asset_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR SELECT * FROM ResourceInstance WHERE asset_id = p_asset_id ORDER BY instance_identifier;
    RETURN rc;
  END GetResourceInstancesByAsset;

  --==============================================================================
  -- Allocation Context Operations
  --==============================================================================
  PROCEDURE AddAllocationContext(
    p_asset_id IN NUMBER, 
    p_context_identifier IN VARCHAR2, 
    p_start_date IN DATE, 
    p_end_date IN DATE,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
    v_context_id NUMBER;
    v_asset_status VARCHAR2(20);
    v_overlapping_flights NUMBER;
    v_capacity_count NUMBER;
  BEGIN
    SAVEPOINT before_context_creation;
    
    BEGIN
      -- VALIDATION 1: Check if asset exists and is active
      BEGIN
        SELECT status INTO v_asset_status FROM ResourceAsset WHERE id = p_asset_id;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          RAISE_APPLICATION_ERROR(-20300, 'Asset ID ' || p_asset_id || ' does not exist');
      END;
      
      IF v_asset_status != 'active' THEN
        RAISE_APPLICATION_ERROR(-20301, 'Cannot schedule flight on inactive asset (status: ' || v_asset_status || ')');
      END IF;
      
      -- VALIDATION 2: Check for overlapping flights with same aircraft
      SELECT COUNT(*) INTO v_overlapping_flights
      FROM AllocationContext
      WHERE asset_id = p_asset_id
        AND (
          -- New flight starts during existing flight
          (p_start_date >= start_date AND p_start_date < end_date)
          OR
          -- New flight ends during existing flight
          (p_end_date > start_date AND p_end_date <= end_date)
          OR
          -- New flight completely contains existing flight
          (p_start_date <= start_date AND p_end_date >= end_date)
        );
      
      IF v_overlapping_flights > 0 THEN
        RAISE_APPLICATION_ERROR(-20302, 
          'Aircraft is already scheduled for overlapping time period (' || 
          v_overlapping_flights || ' conflicting flight(s) found)');
      END IF;
      
      -- VALIDATION 3: Check if asset has capacity configuration
      SELECT COUNT(*) INTO v_capacity_count
      FROM AssetCapacity
      WHERE asset_id = p_asset_id;
      
      IF v_capacity_count = 0 THEN
        RAISE_APPLICATION_ERROR(-20303, 'Asset has no capacity configuration. Please configure AssetCapacity first.');
      END IF;
      
      -- Insert the context
      INSERT INTO AllocationContext(id, asset_id, context_identifier, start_date, end_date, metadata)
      VALUES (AllocationContext_seq.NEXTVAL, p_asset_id, p_context_identifier, p_start_date, p_end_date, p_metadata)
      RETURNING id INTO v_context_id;
      
      -- Initialize capacity for poolable categories only. Capacity reflects journal state:
      -- at context creation the journal is empty, so active_count = 0 and total_capacity = declared quantity.
      -- Later, IncrementCapacityCounter updates active_count based on journal entries (active states:
      -- reserved, confirmed, checked-in, boarded).
      FOR cap_rec IN (
        SELECT ac.category_id, ac.quantity
        FROM AssetCapacity ac
        JOIN ResourceCategory rc ON ac.category_id = rc.id
        WHERE ac.asset_id = p_asset_id
          AND rc.allocation_mode = 'pool'
      ) LOOP
        INSERT INTO Capacity(
          id, context_id, category_id, total_capacity,
          active_count
        )
        VALUES (
          Capacity_seq.NEXTVAL, v_context_id, cap_rec.category_id, cap_rec.quantity,
          0
        );
      END LOOP;
      
    EXCEPTION
      WHEN OTHERS THEN
        ROLLBACK TO before_context_creation;
        RAISE;
    END;
  END AddAllocationContext;

  PROCEDURE UpdateAllocationContext(
    p_context_id IN NUMBER, 
    p_asset_id IN NUMBER, 
    p_context_identifier IN VARCHAR2, 
    p_start_date IN DATE, 
    p_end_date IN DATE,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    UPDATE AllocationContext
    SET asset_id = p_asset_id, 
        context_identifier = p_context_identifier, 
        start_date = p_start_date, 
        end_date = p_end_date,
        metadata = p_metadata
    WHERE id = p_context_id;
  END UpdateAllocationContext;

  PROCEDURE DeleteAllocationContext(p_context_id IN NUMBER) IS
  BEGIN
    DELETE FROM AllocationContext WHERE id = p_context_id;
  END DeleteAllocationContext;

  FUNCTION GetAllocationContext(p_context_identifier IN VARCHAR2) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR SELECT * FROM AllocationContext WHERE context_identifier = p_context_identifier;
    RETURN rc;
  END GetAllocationContext;
  
  -- Creates an allocation context without an asset (for shared allocation mode)
  -- No capacity counters are initialized since resources are allocated individually
  PROCEDURE AddDirectAllocationContext(
    p_context_identifier IN VARCHAR2, 
    p_start_date IN DATE, 
    p_end_date IN DATE,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
    v_context_id NUMBER;
  BEGIN
    -- Validate dates
    IF p_start_date > p_end_date THEN
      RAISE_APPLICATION_ERROR(-20310, 'Start date cannot be after end date');
    END IF;
    
    -- Insert the context without an asset
    INSERT INTO AllocationContext(id, asset_id, context_identifier, start_date, end_date, metadata)
    VALUES (AllocationContext_seq.NEXTVAL, NULL, p_context_identifier, p_start_date, p_end_date, p_metadata)
    RETURNING id INTO v_context_id;
    
    -- No capacity initialization for shared allocation contexts
    -- Resources are allocated individually with time-overlap checking
    
  END AddDirectAllocationContext;
  
  FUNCTION GetContextTimeInterval(
    p_context_id IN NUMBER, 
    p_start_date OUT DATE, 
    p_end_date OUT DATE
  ) RETURN BOOLEAN IS
  BEGIN
    SELECT start_date, end_date 
    INTO p_start_date, p_end_date
    FROM AllocationContext
    WHERE id = p_context_id;
    RETURN TRUE;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN FALSE;
  END GetContextTimeInterval;
  
  --==============================================================================
  -- Time-Based Availability Operations (for Shared Allocation)
  --==============================================================================
  
  FUNCTION IsResourceAvailableForInterval(
    p_resource_instance_id IN NUMBER,
    p_start_date IN DATE,
    p_end_date IN DATE,
    p_exclude_context_id IN NUMBER DEFAULT NULL
  ) RETURN VARCHAR2 IS
    v_conflict_count NUMBER;
  BEGIN
    -- Check for any active allocation in overlapping time intervals
    SELECT COUNT(*) INTO v_conflict_count
    FROM ResourceSchedule rs
    WHERE rs.resource_instance_id = p_resource_instance_id
      AND rs.context_start < p_end_date      -- Existing starts before new ends
      AND rs.context_end > p_start_date      -- Existing ends after new starts
      AND (p_exclude_context_id IS NULL OR rs.context_id != p_exclude_context_id);
    
    IF v_conflict_count > 0 THEN
      RETURN 'N';
    ELSE
      RETURN 'Y';
    END IF;
  END IsResourceAvailableForInterval;
  
  FUNCTION GetResourceTimeConflict(
    p_resource_instance_id IN NUMBER,
    p_start_date IN DATE,
    p_end_date IN DATE,
    p_exclude_context_id IN NUMBER DEFAULT NULL
  ) RETURN NUMBER IS
    v_conflict_context_id NUMBER;
  BEGIN
    -- Find the first conflicting context
    SELECT rs.context_id INTO v_conflict_context_id
    FROM ResourceSchedule rs
    WHERE rs.resource_instance_id = p_resource_instance_id
      AND rs.context_start < p_end_date
      AND rs.context_end > p_start_date
      AND (p_exclude_context_id IS NULL OR rs.context_id != p_exclude_context_id)
      AND ROWNUM = 1;
    
    RETURN v_conflict_context_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END GetResourceTimeConflict;

  --==============================================================================
  -- Capacity Operations (Lock-Free Counters with RESERVABLE)
  --==============================================================================
  PROCEDURE AddCapacity(
    p_context_id IN NUMBER,
    p_category_id IN NUMBER,
    p_total_capacity IN NUMBER,
    p_active_count IN NUMBER,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    INSERT INTO Capacity(
      id, context_id, category_id, total_capacity, active_count, metadata
    )
    VALUES (
      Capacity_seq.NEXTVAL, p_context_id, p_category_id, 
      p_total_capacity, p_active_count, p_metadata
    );
  END AddCapacity;

  PROCEDURE UpdateCapacity(
    p_id IN NUMBER,
    p_active_count IN NUMBER,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
    v_old_active NUMBER;
  BEGIN
    -- Get current values to calculate deltas (required for RESERVABLE columns)
    SELECT active_count
    INTO v_old_active
    FROM Capacity WHERE id = p_id FOR UPDATE;
    
    -- RESERVABLE columns require delta-based updates (column = column + delta)
    -- Each must be updated in a separate statement
    IF p_active_count != v_old_active THEN
      UPDATE Capacity SET active_count = active_count + (p_active_count - v_old_active) WHERE id = p_id;
    END IF;
    
    -- Update non-RESERVABLE columns separately
    UPDATE Capacity
    SET last_updated = CURRENT_TIMESTAMP,
        metadata = p_metadata
    WHERE id = p_id;
  END UpdateCapacity;

  PROCEDURE IncrementCapacityCounter(
    p_context_id IN NUMBER,
    p_category_id IN NUMBER,
    p_active_delta IN NUMBER
  ) IS
    --===========================================================================
    -- Capacity counters are part of the caller's transaction.
    -- Only the allocation journal is autonomous; capacity updates should
    -- commit/rollback with the main transaction to keep escrow semantics.
    --
    -- NOTE: active_count is a RESERVABLE column. Oracle defers the actual row
    -- UPDATE to commit time (lock-free reservation). This means errors from
    -- RESERVABLE operations (constraint violations, trigger errors) surface at
    -- COMMIT, not during the UPDATE statement. Callers must handle compensation
    -- at the commit boundary if needed.
    --===========================================================================
    v_capacity_id NUMBER;
  BEGIN
    -- Get the capacity ID for this context/category combination
    SELECT id INTO v_capacity_id
    FROM Capacity
    WHERE context_id = p_context_id AND category_id = p_category_id;
    
    -- RESERVABLE columns require delta-based updates with format: column = column + delta
    -- Each counter must be updated in a separate statement
    
    IF p_active_delta != 0 THEN
      UPDATE Capacity SET active_count = active_count + p_active_delta WHERE id = v_capacity_id;
    END IF;

    -- Force immediate constraint evaluation for capacity limits
    EXECUTE IMMEDIATE 'SET CONSTRAINTS chk_capacity_valid IMMEDIATE';
  END IncrementCapacityCounter;

  PROCEDURE DeleteCapacity(p_id IN NUMBER) IS
  BEGIN
    DELETE FROM Capacity WHERE id = p_id;
  END DeleteCapacity;

  FUNCTION GetCapacity(p_context_id IN NUMBER, p_category_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR 
      SELECT * FROM Capacity 
      WHERE context_id = p_context_id AND category_id = p_category_id;
    RETURN rc;
  END GetCapacity;

  FUNCTION GetCapacityById(p_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR SELECT * FROM Capacity WHERE id = p_id;
    RETURN rc;
  END GetCapacityById;

  FUNCTION GetAvailableCapacity(p_context_id IN NUMBER, p_category_id IN NUMBER) RETURN NUMBER IS
    v_total NUMBER;
    v_active NUMBER;
  BEGIN
    SELECT total_capacity, active_count INTO v_total, v_active
    FROM Capacity
    WHERE context_id = p_context_id AND category_id = p_category_id;
    
    RETURN v_total - v_active;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 0;
  END GetAvailableCapacity;

  --==============================================================================
  -- Allocation Journal Operations (Autonomous for Permanent Audit Trail)
  --==============================================================================
  PROCEDURE AddAllocationJournal(
    p_context_id IN NUMBER,
    p_category_id IN NUMBER,
    p_user_id IN NUMBER,
    p_resource_instance_id IN NUMBER,
    p_status IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL,
    p_journal_id OUT NUMBER
  ) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    -- Generate new ID
    SELECT AllocationJournal_seq.NEXTVAL INTO p_journal_id FROM DUAL;
    
    -- Insert journal entry (commits immediately and permanently)
    INSERT INTO AllocationJournal(id, context_id, category_id, user_id, resource_instance_id, status, metadata)
    VALUES (p_journal_id, p_context_id, p_category_id, p_user_id, p_resource_instance_id, p_status, p_metadata);
    
    -- Maintain ActiveAllocation lock table (only for instance-level allocations).
    -- Each branch validates row-count to detect concurrent modifications:
    --   INSERT → DUP_VAL_ON_INDEX  (-20910) if already reserved
    --   UPDATE → SQL%ROWCOUNT = 0  (-20911) if concurrently cancelled
    --   DELETE → SQL%ROWCOUNT = 0  (-20912) if already cancelled/completed
    IF p_resource_instance_id IS NOT NULL THEN
      IF p_status IN ('cancelled', 'completed') THEN
        -- Terminal status: release the lock so the resource can be re-allocated
        DELETE FROM ActiveAllocation
        WHERE context_id = p_context_id
          AND resource_instance_id = p_resource_instance_id;

        IF SQL%ROWCOUNT = 0 THEN
          ROLLBACK; -- Rollback the journal entry (nothing to cancel)
          RAISE_APPLICATION_ERROR(-20912,
            'Active allocation already removed (concurrent cancel/complete). '
            || 'resource_instance=' || p_resource_instance_id
            || ', context=' || p_context_id);
        END IF;
      ELSIF p_status IN ('reserved', 'blocked') THEN
        -- Initial allocation: claim the lock (UNIQUE constraint prevents double-booking)
        BEGIN
          INSERT INTO ActiveAllocation (context_id, resource_instance_id, journal_id)
          VALUES (p_context_id, p_resource_instance_id, p_journal_id);
        EXCEPTION
          WHEN DUP_VAL_ON_INDEX THEN
            ROLLBACK; -- Rollback the journal entry + failed lock insert
            RAISE_APPLICATION_ERROR(-20910,
              'Active allocation already exists for resource instance '
              || p_resource_instance_id || ' in context ' || p_context_id || '.');
        END;
      ELSE
        -- Status transition (confirmed, checked-in, boarded, etc.):
        -- update the journal reference on the existing lock row
        UPDATE ActiveAllocation
        SET journal_id = p_journal_id
        WHERE context_id = p_context_id
          AND resource_instance_id = p_resource_instance_id;

        IF SQL%ROWCOUNT = 0 THEN
          ROLLBACK; -- Rollback the journal entry (allocation was concurrently cancelled)
          RAISE_APPLICATION_ERROR(-20911,
            'Active allocation not found for status transition to '''
            || p_status || '''. resource_instance=' || p_resource_instance_id
            || ', context=' || p_context_id
            || ' (concurrent cancel may have removed it).');
        END IF;
      END IF;
    END IF;
    
    -- Commit this autonomous transaction
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK; -- Rollback only this autonomous transaction
      RAISE;
  END AddAllocationJournal;

  PROCEDURE UpdateAllocationJournal(
    p_id IN NUMBER,
    p_context_id IN NUMBER,
    p_category_id IN NUMBER,
    p_user_id IN NUMBER,
    p_resource_instance_id IN NUMBER,
    p_status IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    UPDATE AllocationJournal
    SET context_id = p_context_id,
        category_id = p_category_id,
        user_id = p_user_id,
        resource_instance_id = p_resource_instance_id,
        status = p_status,
        metadata = p_metadata
    WHERE id = p_id;
  END UpdateAllocationJournal;

  PROCEDURE DeleteAllocationJournal(p_id IN NUMBER) IS
  BEGIN
    DELETE FROM AllocationJournal WHERE id = p_id;
  END DeleteAllocationJournal;

  FUNCTION GetAllocationJournal(p_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR SELECT * FROM AllocationJournal WHERE id = p_id;
    RETURN rc;
  END GetAllocationJournal;

  FUNCTION GetAllocationJournalByContext(p_context_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR 
      SELECT * FROM AllocationJournal 
      WHERE context_id = p_context_id 
      ORDER BY entry_timestamp DESC;
    RETURN rc;
  END GetAllocationJournalByContext;

  --==============================================================================
  -- Workflow Log Operations
  --==============================================================================
  PROCEDURE AddWorkflowLog(
    p_event_id IN VARCHAR2,
    p_workflow_id IN NUMBER,
    p_wf_static_id IN VARCHAR2,
    p_act_static_id IN VARCHAR2,
    p_message IN VARCHAR2,
    p_status IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    INSERT INTO WorkflowLog(id, event_id, workflow_id, wf_static_id, act_static_id, message, message_ts, status, metadata)
    VALUES (WorkflowLog_seq.NEXTVAL, p_event_id, p_workflow_id, p_wf_static_id, p_act_static_id, p_message, SYSTIMESTAMP, p_status, p_metadata);
  END AddWorkflowLog;

  PROCEDURE UpdateWorkflowLog(
    p_id IN NUMBER,
    p_event_id IN VARCHAR2,
    p_workflow_id IN NUMBER,
    p_wf_static_id IN VARCHAR2,
    p_act_static_id IN VARCHAR2,
    p_message IN VARCHAR2,
    p_status IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    UPDATE WorkflowLog
    SET event_id = p_event_id,
        workflow_id = p_workflow_id,
        wf_static_id = p_wf_static_id,
        act_static_id = p_act_static_id,
        message = p_message,
        status = p_status,
        metadata = p_metadata
    WHERE id = p_id;
  END UpdateWorkflowLog;

  PROCEDURE DeleteWorkflowLog(p_id IN NUMBER) IS
  BEGIN
    DELETE FROM WorkflowLog WHERE id = p_id;
  END DeleteWorkflowLog;

  FUNCTION GetWorkflowLog(p_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR SELECT * FROM WorkflowLog WHERE id = p_id;
    RETURN rc;
  END GetWorkflowLog;

  FUNCTION GetWorkflowLogByWorkflowId(p_workflow_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR 
      SELECT * FROM WorkflowLog 
      WHERE workflow_id = p_workflow_id 
      ORDER BY message_ts DESC;
    RETURN rc;
  END GetWorkflowLogByWorkflowId;

  --==============================================================================
  -- Workflow Collaboration Operations
  --==============================================================================
  PROCEDURE AddWorkflowCollaboration(
    p_event_id IN VARCHAR2,
    p_workflow_id IN NUMBER,
    p_collaboration_name IN VARCHAR2,
    p_event_data IN CLOB,
    p_state IN VARCHAR2,
    p_activity_static_id IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    INSERT INTO WorkflowCollaboration(
      id, event_id, workflow_id, collaboration_name, 
      collaboration_start, event_data, state, activity_static_id, metadata
    )
    VALUES (
      WorkflowCollaboration_seq.NEXTVAL, p_event_id, p_workflow_id, p_collaboration_name,
      SYSTIMESTAMP, p_event_data, p_state, p_activity_static_id, p_metadata
    );
  END AddWorkflowCollaboration;

  PROCEDURE UpdateWorkflowCollaboration(
    p_id IN NUMBER,
    p_event_id IN VARCHAR2,
    p_workflow_id IN NUMBER,
    p_collaboration_name IN VARCHAR2,
    p_event_data IN CLOB,
    p_state IN VARCHAR2,
    p_activity_static_id IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    UPDATE WorkflowCollaboration
    SET event_id = p_event_id,
        workflow_id = p_workflow_id,
        collaboration_name = p_collaboration_name,
        event_data = p_event_data,
        state = p_state,
        activity_static_id = p_activity_static_id,
        metadata = p_metadata
    WHERE id = p_id;
  END UpdateWorkflowCollaboration;

  PROCEDURE DeleteWorkflowCollaboration(p_id IN NUMBER) IS
  BEGIN
    DELETE FROM WorkflowCollaboration WHERE id = p_id;
  END DeleteWorkflowCollaboration;

  FUNCTION GetWorkflowCollaboration(p_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR SELECT * FROM WorkflowCollaboration WHERE id = p_id;
    RETURN rc;
  END GetWorkflowCollaboration;

  FUNCTION GetWorkflowCollaborationByWorkflowId(p_workflow_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR 
      SELECT * FROM WorkflowCollaboration 
      WHERE workflow_id = p_workflow_id 
      ORDER BY collaboration_start DESC;
    RETURN rc;
  END GetWorkflowCollaborationByWorkflowId;

  --==============================================================================
  -- Debug Log Operations
  --==============================================================================
  PROCEDURE AddDebugLog(
    p_message IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    INSERT INTO DebugLog(id, message, metadata)
    VALUES (DebugLog_seq.NEXTVAL, p_message, p_metadata);
  END AddDebugLog;

  PROCEDURE DeleteDebugLog(p_id IN NUMBER) IS
  BEGIN
    DELETE FROM DebugLog WHERE id = p_id;
  END DeleteDebugLog;

  FUNCTION GetDebugLog(p_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR SELECT * FROM DebugLog WHERE id = p_id;
    RETURN rc;
  END GetDebugLog;

  FUNCTION GetRecentDebugLogs(p_limit IN NUMBER DEFAULT 100) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR 
      SELECT * FROM (
        SELECT * FROM DebugLog 
        ORDER BY log_timestamp DESC
      ) WHERE ROWNUM <= p_limit;
    RETURN rc;
  END GetRecentDebugLogs;

  PROCEDURE ClearDebugLogs IS
  BEGIN
    DELETE FROM DebugLog;
  END ClearDebugLogs;

  --==============================================================================
  -- Category Hierarchy Operations
  --==============================================================================
  PROCEDURE UpdateCategoryHierarchy(
    p_category_id IN NUMBER,
    p_hierarchy_level IN NUMBER,
    p_base_price IN NUMBER DEFAULT NULL
  ) IS
  BEGIN
    UPDATE ResourceCategory
    SET hierarchy_level = p_hierarchy_level,
        base_price = NVL(p_base_price, base_price)
    WHERE id = p_category_id;
    
    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20700, 'Category not found: ' || p_category_id);
    END IF;
  END UpdateCategoryHierarchy;

  --==============================================================================
  -- Category Substitution Operations
  --==============================================================================
  PROCEDURE AddCategorySubstitution(
    p_from_category_id IN NUMBER,
    p_to_category_id IN NUMBER,
    p_cost_adjustment IN NUMBER DEFAULT 0,
    p_priority IN NUMBER DEFAULT 1,
    p_is_allowed IN VARCHAR2 DEFAULT 'Y',
    p_auto_offer IN VARCHAR2 DEFAULT 'N',
    p_requires_approval IN VARCHAR2 DEFAULT 'N',
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    INSERT INTO CategorySubstitution(
      id, from_category_id, to_category_id, cost_adjustment, priority,
      is_allowed, auto_offer, requires_approval, metadata
    )
    VALUES (
      CategorySubstitution_seq.NEXTVAL, p_from_category_id, p_to_category_id,
      p_cost_adjustment, p_priority, p_is_allowed, p_auto_offer, 
      p_requires_approval, p_metadata
    );
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      RAISE_APPLICATION_ERROR(-20701, 
        'Substitution rule already exists for category ' || p_from_category_id || 
        ' -> ' || p_to_category_id);
  END AddCategorySubstitution;
  
  PROCEDURE UpdateCategorySubstitution(
    p_id IN NUMBER,
    p_cost_adjustment IN NUMBER,
    p_priority IN NUMBER,
    p_is_allowed IN VARCHAR2,
    p_auto_offer IN VARCHAR2,
    p_requires_approval IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  ) IS
  BEGIN
    UPDATE CategorySubstitution
    SET cost_adjustment = p_cost_adjustment,
        priority = p_priority,
        is_allowed = p_is_allowed,
        auto_offer = p_auto_offer,
        requires_approval = p_requires_approval,
        metadata = p_metadata
    WHERE id = p_id;
    
    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20702, 'Substitution rule not found: ' || p_id);
    END IF;
  END UpdateCategorySubstitution;
  
  PROCEDURE DeleteCategorySubstitution(p_id IN NUMBER) IS
  BEGIN
    DELETE FROM CategorySubstitution WHERE id = p_id;
  END DeleteCategorySubstitution;
  
  FUNCTION GetCategorySubstitutions(p_from_category_id IN NUMBER) RETURN SYS_REFCURSOR IS
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR
      SELECT * FROM AvailableSubstitutions
      WHERE from_category_id = p_from_category_id
      ORDER BY priority;
    RETURN rc;
  END GetCategorySubstitutions;
  
  FUNCTION GetAvailableSubstitutionsForContext(
    p_context_id IN NUMBER,
    p_from_category_id IN NUMBER
  ) RETURN SYS_REFCURSOR IS
    --===========================================================================
    -- Returns available substitutions for a category within a specific context.
    -- Only returns substitutions where the target category has available capacity.
    --
    -- Results include:
    --   - Substitution details (type, cost adjustment, priority)
    --   - Target category info (name, hierarchy, base price)
    --   - Available capacity in the target category
    --===========================================================================
    rc SYS_REFCURSOR;
  BEGIN
    OPEN rc FOR
      SELECT 
        avs.substitution_id,
        avs.from_category_id,
        avs.from_category_name,
        avs.to_category_id,
        avs.to_category_name,
        avs.substitution_type,
        avs.cost_adjustment,
        avs.priority,
        avs.auto_offer,
        avs.requires_approval,
        (c.total_capacity - c.active_count) AS to_category_available,
        avs.to_base_price - avs.from_base_price AS base_price_difference
      FROM AvailableSubstitutions avs
      JOIN Capacity c ON c.category_id = avs.to_category_id 
                     AND c.context_id = p_context_id
      WHERE avs.from_category_id = p_from_category_id
        AND (c.total_capacity - c.active_count) > 0
      ORDER BY avs.priority, avs.cost_adjustment;
    RETURN rc;
  END GetAvailableSubstitutionsForContext;

END ResourceManagement_Data;
/

show err;

