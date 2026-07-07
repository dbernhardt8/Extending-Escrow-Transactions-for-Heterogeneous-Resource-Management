-- =============================================================================
-- MANUAL_MaintenanceOverlap_Contained.sql
-- =============================================================================
-- Manual, cell-style test: maintenance overlap behavior for contained/pool mode.
--
-- Scenario:
--   1) Create Flight A (normal context)
--   2) Create maintenance context for M1 + M2 overlapping Flight A
--   3) Assert blocked was retroactively written to Flight A for M1 + M2
--   4) Try creating Flight B overlapping Flight A -> expect -20302
--   5) Create Flight C not overlapping A but inside maintenance window
--   6) Assert Flight C automatically contains blocked for M1 + M2
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_MaintenanceOverlap_Contained ===');
END;
/

-- =============================================================================
-- Cell 0: Cleanup
-- =============================================================================
DECLARE
  v_j NUMBER; v_aa NUMBER; v_c NUMBER; v_ctx NUMBER; v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (
    SELECT id FROM AllocationContext
    WHERE context_identifier IN (
      'MANUAL_Maint_Flight_A',
      'MANUAL_Maint_Flight_B',
      'MANUAL_Maint_Flight_C',
      'MANUAL_Maint_Period_1'
    )
  );
  v_aa := SQL%ROWCOUNT;

  DELETE FROM AllocationJournal
  WHERE context_id IN (
    SELECT id FROM AllocationContext
    WHERE context_identifier IN (
      'MANUAL_Maint_Flight_A',
      'MANUAL_Maint_Flight_B',
      'MANUAL_Maint_Flight_C',
      'MANUAL_Maint_Period_1'
    )
  );
  v_j := SQL%ROWCOUNT;

  DELETE FROM Capacity
  WHERE context_id IN (
    SELECT id FROM AllocationContext
    WHERE context_identifier IN (
      'MANUAL_Maint_Flight_A',
      'MANUAL_Maint_Flight_B',
      'MANUAL_Maint_Flight_C',
      'MANUAL_Maint_Period_1'
    )
  );
  v_c := SQL%ROWCOUNT;

  DELETE FROM AllocationContext
  WHERE context_identifier IN (
    'MANUAL_Maint_Flight_A',
    'MANUAL_Maint_Flight_B',
    'MANUAL_Maint_Flight_C',
    'MANUAL_Maint_Period_1'
  );
  v_ctx := SQL%ROWCOUNT;

  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Maint_Pool_Asset');
  v_ri := SQL%ROWCOUNT;

  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Maint_Pool_Asset');
  v_ac := SQL%ROWCOUNT;

  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Maint_Pool_Asset';
  v_ra := SQL%ROWCOUNT;

  DELETE FROM Users WHERE name = 'MANUAL_Maint_User';
  v_u := SQL%ROWCOUNT;

  DELETE FROM ResourceCategory WHERE name = 'MANUAL_Maint_Pool_Class';
  v_rc := SQL%ROWCOUNT;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 0: Cleanup done. Journal=' || v_j || ', AA=' || v_aa || ', Capacity=' || v_c || ', Context=' || v_ctx ||
                       ', Instances=' || v_ri || ', AssetCap=' || v_ac || ', Asset=' || v_ra || ', Users=' || v_u || ', Category=' || v_rc);
END;
/

-- =============================================================================
-- Cell 1: Reference data
-- =============================================================================
BEGIN
  ResourceManagement_Data.AddResourceStatus('reserved', 'Held');
  ResourceManagement_Data.AddResourceStatus('confirmed', 'Confirmed');
  ResourceManagement_Data.AddResourceStatus('cancelled', 'Cancelled');
  ResourceManagement_Data.AddResourceStatus('checked-in', 'Checked In');
  ResourceManagement_Data.AddResourceStatus('boarded', 'Boarded');
  ResourceManagement_Data.AddResourceStatus('blocked', 'Blocked');
  ResourceManagement_Data.AddResourceStatus('completed', 'Completed');
EXCEPTION
  WHEN DUP_VAL_ON_INDEX THEN NULL;
END;
/

BEGIN
  ResourceManagement_Data.AddResourceInstanceStatus('available', 'Available');
  ResourceManagement_Data.AddResourceInstanceStatus('unavailable', 'Unavailable');
  ResourceManagement_Data.AddResourceInstanceStatus('in-use', 'In Use');
EXCEPTION
  WHEN DUP_VAL_ON_INDEX THEN NULL;
END;
/
COMMIT;

-- =============================================================================
-- Cell 2: Setup category, asset, instances, Flight A
-- =============================================================================
DECLARE
  v_asset_id NUMBER;
  v_category_id NUMBER;
  v_count NUMBER;
  v_i NUMBER;
  v_start_a DATE := TRUNC(SYSDATE) + 10 + 10/24;
  v_end_a   DATE := TRUNC(SYSDATE) + 10 + 12/24;
BEGIN
  SELECT COUNT(*) INTO v_count FROM ResourceCategory WHERE name = 'MANUAL_Maint_Pool_Class';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceCategory('MANUAL_Maint_Pool_Class', 'Pool category for maintenance overlap', 'pool');
  END IF;

  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_Maint_User';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddUser('MANUAL_Maint_User');
  END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Maint_Pool_Asset';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceAsset('MANUAL_Maint_Pool_Asset', NULL, 'active');
  END IF;

  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Maint_Pool_Asset' AND c.name = 'MANUAL_Maint_Pool_Class';

  SELECT COUNT(*) INTO v_count FROM AssetCapacity WHERE asset_id = v_asset_id AND category_id = v_category_id;
  IF v_count = 0 THEN
    ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_category_id, 10);
  END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceInstance WHERE asset_id = v_asset_id;
  IF v_count = 0 THEN
    FOR v_i IN 1..10 LOOP
      ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'M' || v_i, 'available');
    END LOOP;
  END IF;

  SELECT COUNT(*) INTO v_count FROM AllocationContext WHERE context_identifier = 'MANUAL_Maint_Flight_A';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddAllocationContext(
      p_asset_id => v_asset_id,
      p_context_identifier => 'MANUAL_Maint_Flight_A',
      p_start_date => v_start_a,
      p_end_date => v_end_a,
      p_metadata => '{"context_type":"normal"}'
    );
  END IF;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Setup complete.');
END;
/

-- =============================================================================
-- Cell 3: [SESSION A] MakeReservation by category (quantity=2) - BLOCKS
-- =============================================================================
-- Run this block in Session A. While it is blocked, run Cell 3b in Session B.
DECLARE
  v_user_id      NUMBER;
  v_group_leader NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_Maint_User';
  ResourceManagement.MakeReservation(
    p_context_identifier => 'MANUAL_Maint_Flight_A',
    p_user_id            => v_user_id,
    p_category_name      => 'MANUAL_Maint_Pool_Class',
    p_quantity           => 2,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_group_leader
  );
  DBMS_OUTPUT.PUT_LINE('Cell 3: MakeReservation returned. group_leader_journal_id=' || NVL(TO_CHAR(v_group_leader), 'NULL'));
END;
/

-- =============================================================================
-- Cell 3b: [SESSION B] Publish CONFIRM event for group reservation
-- =============================================================================
-- Run in a second session while Cell 3 is blocked.
DECLARE
  v_user_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_Maint_User';
  ResourceManagement.publish_group_reservation_event(
    p_context_identifier => 'MANUAL_Maint_Flight_A',
    p_user_id            => v_user_id,
    p_category_name      => 'MANUAL_Maint_Pool_Class',
    p_action             => 'CONFIRM'
  );
END;
/

-- =============================================================================
-- Cell 4: Assert no blocked before maintenance
-- =============================================================================
SELECT COUNT(*) AS blocked_before
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ac.id = ca.context_id
JOIN ResourceInstance ri ON ri.id = ca.resource_instance_id
WHERE ac.context_identifier = 'MANUAL_Maint_Flight_A'
  AND ri.instance_identifier IN ('M1', 'M2')
  AND ca.status = 'blocked';
-- Expected: 0

-- =============================================================================
-- Cell 5: Create maintenance context overlapping Flight A for M1/M2
-- =============================================================================
DECLARE
  v_asset_id NUMBER;
  v_m1 NUMBER;
  v_m2 NUMBER;
  v_start_m DATE := TRUNC(SYSDATE) + 10 + 11/24;
  v_end_m   DATE := TRUNC(SYSDATE) + 10 + 13/24;
BEGIN
  SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'MANUAL_Maint_Pool_Asset';
  SELECT ri.id INTO v_m1
  FROM ResourceInstance ri JOIN ResourceAsset ra ON ra.id = ri.asset_id
  WHERE ra.name = 'MANUAL_Maint_Pool_Asset' AND ri.instance_identifier = 'M1';
  SELECT ri.id INTO v_m2
  FROM ResourceInstance ri JOIN ResourceAsset ra ON ra.id = ri.asset_id
  WHERE ra.name = 'MANUAL_Maint_Pool_Asset' AND ri.instance_identifier = 'M8';

  ResourceManagement_Data.AddAllocationContext(
    p_asset_id => v_asset_id,
    p_context_identifier => 'MANUAL_Maint_Period_1',
    p_start_date => v_start_m,
    p_end_date => v_end_m,
    p_metadata => '{"context_type":"maintenance","resource_instance_ids":[' || v_m1 || ',' || v_m2 || ']}'
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 5: Maintenance context created.');
END;
/

-- =============================================================================
-- Cell 6: Assert retroactive blocked on Flight A for M1/M2
-- =============================================================================
SELECT ri.instance_identifier, ca.status, ca.user_id
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ac.id = ca.context_id
JOIN ResourceInstance ri ON ri.id = ca.resource_instance_id
WHERE ac.context_identifier = 'MANUAL_Maint_Flight_A'
  AND ri.instance_identifier IN ('M1', 'M8')
ORDER BY ri.instance_identifier;
-- Expected: M1/M8 status='blocked', user_id NULL

-- =============================================================================
-- Cell 7: Assert other instances not blocked in Flight A
-- =============================================================================
SELECT COUNT(*) AS blocked_other_instances
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ac.id = ca.context_id
JOIN ResourceInstance ri ON ri.id = ca.resource_instance_id
WHERE ac.context_identifier = 'MANUAL_Maint_Flight_A'
  AND ri.instance_identifier NOT IN ('M1', 'M8')
  AND ca.status = 'blocked';
-- Expected: 0

-- =============================================================================
-- Cell 8: Create overlapping Flight B -> expect -20302
-- =============================================================================
DECLARE
  v_asset_id NUMBER;
  v_start_b DATE := TRUNC(SYSDATE) + 10 + 11.5/24;
  v_end_b   DATE := TRUNC(SYSDATE) + 10 + 12.5/24;
BEGIN
  SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'MANUAL_Maint_Pool_Asset';
  ResourceManagement_Data.AddAllocationContext(
    p_asset_id => v_asset_id,
    p_context_identifier => 'MANUAL_Maint_Flight_B',
    p_start_date => v_start_b,
    p_end_date => v_end_b,
    p_metadata => '{"context_type":"normal"}'
  );
  DBMS_OUTPUT.PUT_LINE('Cell 8: Expected -20302 but context was created [FAIL]');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -20302 THEN
      DBMS_OUTPUT.PUT_LINE('Cell 8: Overlapping normal context rejected with -20302 [PASS]');
    ELSE
      DBMS_OUTPUT.PUT_LINE('Cell 8: Unexpected error ' || SQLCODE || ' - ' || SQLERRM || ' [FAIL]');
    END IF;
END;
/

-- =============================================================================
-- Cell 9: Create Flight C (no overlap with A, overlaps maintenance window)
-- =============================================================================
DECLARE
  v_asset_id NUMBER;
  v_start_c DATE := TRUNC(SYSDATE) + 10 + 12.5/24;
  v_end_c   DATE := TRUNC(SYSDATE) + 10 + 12.75/24;
BEGIN
  SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'MANUAL_Maint_Pool_Asset';
  ResourceManagement_Data.AddAllocationContext(
    p_asset_id => v_asset_id,
    p_context_identifier => 'MANUAL_Maint_Flight_C',
    p_start_date => v_start_c,
    p_end_date => v_end_c,
    p_metadata => '{"context_type":"normal"}'
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 9: Flight C created.');
END;
/

-- =============================================================================
-- Cell 10: Assert Flight C auto-blocked M1/M2
-- =============================================================================
SELECT ri.instance_identifier, ca.status
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ac.id = ca.context_id
JOIN ResourceInstance ri ON ri.id = ca.resource_instance_id
WHERE ac.context_identifier = 'MANUAL_Maint_Flight_C'
ORDER BY ri.instance_identifier;
-- Expected: M1/M2 blocked; other instances absent or non-blocked

-- =============================================================================
-- Cell 11: Assert available seats reduced
-- =============================================================================
SELECT ResourceManagement.GetAvailableSeatCount('MANUAL_Maint_Flight_C', 'MANUAL_Maint_Pool_Class') AS available_seats
FROM DUAL;
-- Expected: 8

-- =============================================================================
-- Cell 12: Teardown
-- =============================================================================
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (
    SELECT id FROM AllocationContext
    WHERE context_identifier IN (
      'MANUAL_Maint_Flight_A',
      'MANUAL_Maint_Flight_B',
      'MANUAL_Maint_Flight_C',
      'MANUAL_Maint_Period_1'
    )
  );

  DELETE FROM AllocationJournal
  WHERE context_id IN (
    SELECT id FROM AllocationContext
    WHERE context_identifier IN (
      'MANUAL_Maint_Flight_A',
      'MANUAL_Maint_Flight_B',
      'MANUAL_Maint_Flight_C',
      'MANUAL_Maint_Period_1'
    )
  );

  DELETE FROM Capacity
  WHERE context_id IN (
    SELECT id FROM AllocationContext
    WHERE context_identifier IN (
      'MANUAL_Maint_Flight_A',
      'MANUAL_Maint_Flight_B',
      'MANUAL_Maint_Flight_C',
      'MANUAL_Maint_Period_1'
    )
  );

  DELETE FROM AllocationContext
  WHERE context_identifier IN (
    'MANUAL_Maint_Flight_A',
    'MANUAL_Maint_Flight_B',
    'MANUAL_Maint_Flight_C',
    'MANUAL_Maint_Period_1'
  );

  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Maint_Pool_Asset');
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Maint_Pool_Asset');
  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Maint_Pool_Asset';
  DELETE FROM Users WHERE name = 'MANUAL_Maint_User';
  DELETE FROM ResourceCategory WHERE name = 'MANUAL_Maint_Pool_Class';
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 12: Teardown complete.');
END;
/
