-- =============================================================================
-- MANUAL_MakeReservation_SpecificResource.sql
-- =============================================================================
-- Manual, cell-style test: MakeReservation (instance-based dispatcher) – reserve
-- one specific resource instance (e.g. seat M3), then optional ConfirmReservation (Cell 4.5).
--
-- Setup: Cell 1 = reference data; Cell 2 = Data Setup (CRUD: category, user,
-- asset, capacity, instances, context). AddAllocationContext initializes capacity.
--
-- Run cells in order. In SQL Developer: select from "-- ===== Cell N:" to the
-- start of the next cell, then Execute.
--
-- Cell index:
--   0     Cleanup (optional first)
--   1     Reference data (reserved, available) – ensure mock data loaded
--   2     Data Setup – category, user, asset, capacity, instances, context (CRUD)
--   3     Assert: context + capacity init (AllocationContext 1 row, Capacity 1 row, active_count=0)
--   4     Act: MakeReservation (one specific instance, e.g. seat M3, timeout 5 min)
--         Procedure waits for confirm/cancel event on RESERVATION_EVENTS_Q.
--   4.5   Optional: ConfirmReservation(journal_id) – only if still reserved
--   5     Assert: CurrentAllocations 1 row (reserved/confirmed) or 0 (cancelled)
--   6     Assert: Capacity.active_count = 1 or 0, CurrentAllocations 1 or 0
--   7     Assert: GetAvailableSeatCount = 9 or 10
--   8     Teardown
--
-- Test identifier: context_identifier = 'MANUAL_SpecificSeat'
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_SpecificSeat – MakeReservation (instance-based) ===');
  DBMS_OUTPUT.PUT_LINE('Reserve one specific instance (e.g. M3). Optional Cell 4.5: ConfirmReservation.');
  DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- Cell 0: Cleanup (optional – run first to remove leftover data from last run)
-- =============================================================================

-- Teardown order: ActiveAllocation → Journal → Capacity → Context → Instance → AssetCapacity → Asset → User → ResourceCategory
DECLARE
  v_j NUMBER; v_aa NUMBER; v_c NUMBER; v_ctx NUMBER; v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_SpecificSeat');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_SpecificSeat');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_SpecificSeat');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_SpecificSeat';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_SpecificSeat');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_SpecificSeat');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_SpecificSeat';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name = 'MANUAL_User_SpecificSeat';
  v_u := SQL%ROWCOUNT;
  DELETE FROM ResourceCategory WHERE name = 'MANUAL_Business_Class';
  v_rc := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 0: Cleanup done. Deleted: Journal=' || v_j || ', AA=' || v_aa || ', Capacity=' || v_c || ', Context=' || v_ctx ||
    ', Instances=' || v_ri || ', AssetCap=' || v_ac || ', Asset=' || v_ra || ', Users=' || v_u || ', Category=' || v_rc);
END;
/

PROMPT Cell 0 done: Cleanup (if any)

-- =============================================================================
-- Cell 1: Ensure reference data (ResourceStatus, ResourceInstanceStatus) – CRUD
-- =============================================================================
-- Skip if 4_insert_mock_data_extensive.sql or full setup was run.

BEGIN
  ResourceManagement_Data.AddResourceStatus('reserved', 'Held');
  ResourceManagement_Data.AddResourceStatus('confirmed', 'Confirmed');
  ResourceManagement_Data.AddResourceStatus('cancelled', 'Cancelled');
  ResourceManagement_Data.AddResourceStatus('checked-in', 'Checked In');
  ResourceManagement_Data.AddResourceStatus('boarded', 'Boarded');
  ResourceManagement_Data.AddResourceStatus('blocked', 'Blocked');
  ResourceManagement_Data.AddResourceStatus('completed', 'Completed');

  ResourceManagement_Data.AddResourceInstanceStatus('available', 'Available');
  ResourceManagement_Data.AddResourceInstanceStatus('unavailable', 'Unavailable');
  ResourceManagement_Data.AddResourceInstanceStatus('in-use', 'In Use');
  COMMIT;
EXCEPTION
  WHEN DUP_VAL_ON_INDEX THEN COMMIT;  -- already exist
END;
/

PROMPT Cell 1: Reference data (reserved, available) – ensure mock data loaded

-- -----------------------------------------------------------------------------
-- Cell 1a: Create RESERVJRNL_CAPACITY view (optional)
-- -----------------------------------------------------------------------------
DECLARE
  v_obj_id NUMBER;
  v_sql    VARCHAR2(4000);
BEGIN
  SELECT object_id INTO v_obj_id
  FROM user_objects
  WHERE object_name = 'CAPACITY' AND object_type = 'TABLE';

  v_sql := 'CREATE OR REPLACE VIEW RESERVJRNL_CAPACITY AS ' ||
           'SELECT * FROM SYS_RESERVJRNL_' || v_obj_id;
  EXECUTE IMMEDIATE v_sql;
  DBMS_OUTPUT.PUT_LINE('Created view RESERVJRNL_CAPACITY for SYS_RESERVJRNL_' || v_obj_id);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Could not create RESERVJRNL_CAPACITY view: ' || SQLERRM);
END;
/

PROMPT Cell 1a done: RESERVJRNL_CAPACITY view

-- =============================================================================
-- Cell 2: Data Setup – category, user, asset, capacity, instances, context (CRUD)
-- =============================================================================
-- Combined setup: MANUAL_Business_Class category, test user, test asset, 10 seats,
-- 10 ResourceInstances (M1..M10), AllocationContext. AddAllocationContext initializes capacity.

DECLARE
  v_count        NUMBER;
  v_asset_id     NUMBER;
  v_category_id  NUMBER;
  v_cnt          NUMBER;
  v_ctx_count    NUMBER;
  v_i            NUMBER;
BEGIN
  -- Category (MANUAL_Business_Class)
  SELECT COUNT(*) INTO v_count FROM ResourceCategory WHERE name = 'MANUAL_Business_Class';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceCategory('MANUAL_Business_Class', NULL, 'pool');
  END IF;

  -- Test user
  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_SpecificSeat';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddUser('MANUAL_User_SpecificSeat');
  END IF;

  -- Test asset
  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Asset_SpecificSeat';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceAsset('MANUAL_Asset_SpecificSeat', NULL, 'active');
  END IF;

  -- AssetCapacity (10 seats MANUAL_Business_Class)
  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Asset_SpecificSeat' AND c.name = 'MANUAL_Business_Class';
  SELECT COUNT(*) INTO v_count FROM AssetCapacity WHERE asset_id = v_asset_id AND category_id = v_category_id;
  IF v_count = 0 THEN
    ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_category_id, 10);
  END IF;

  -- ResourceInstances (10: M1..M10)
  SELECT COUNT(*) INTO v_cnt FROM ResourceInstance WHERE asset_id = v_asset_id;
  IF v_cnt = 0 THEN
    FOR v_i IN 1..10 LOOP
      ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'M' || v_i, 'available');
    END LOOP;
  END IF;

  -- AllocationContext (capacity initialized by CRUD)
  SELECT COUNT(*) INTO v_ctx_count FROM AllocationContext WHERE context_identifier = 'MANUAL_SpecificSeat';
  IF v_ctx_count = 0 THEN
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'MANUAL_Asset_SpecificSeat';
    ResourceManagement_Data.AddAllocationContext(v_asset_id, 'MANUAL_SpecificSeat', SYSDATE + 1, SYSDATE + 2);
  END IF;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data Setup complete (category, user, asset, capacity, instances, context).');
END;
/
PROMPT Cell 2 done: Data Setup

-- =============================================================================
-- Cell 3: Assert – context and capacity init (AllocationContext + Capacity created)
-- =============================================================================

SELECT ac.id AS context_id, ac.context_identifier, ac.asset_id, ac.start_date, ac.end_date
FROM AllocationContext ac
WHERE ac.context_identifier = 'MANUAL_SpecificSeat';
-- Expected: 1 row

SELECT c.id AS capacity_id, c.context_id, c.category_id, rc.name AS category_name,
       c.total_capacity, c.active_count
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_SpecificSeat';
-- Expected: 1 row (MANUAL_Business_Class), total_capacity=10, active_count=0

DECLARE
  v_ctx_count   NUMBER;
  v_cap_count   NUMBER;
  v_total_cap   NUMBER;
  v_active      NUMBER;
  v_ok          BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_ctx_count
  FROM AllocationContext
  WHERE context_identifier = 'MANUAL_SpecificSeat';
  IF v_ctx_count != 1 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: AllocationContext: expected 1 row, actual ' || v_ctx_count || ' [FAIL]');
  END IF;

  SELECT COUNT(*), MAX(c.total_capacity), MAX(c.active_count)
  INTO v_cap_count, v_total_cap, v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_SpecificSeat';
  IF v_cap_count != 1 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: Capacity: expected 1 row, actual ' || v_cap_count || ' [FAIL]');
  END IF;
  IF v_total_cap != 10 OR v_active != 0 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: Capacity: expected total_capacity=10, active_count=0; actual total_capacity=' ||
      v_total_cap || ', active_count=' || v_active || ' [FAIL]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 3: Context + capacity init OK: AllocationContext=1, Capacity=1 (total_capacity=10, active_count=0) [PASS]');
  END IF;
END;
/

PROMPT Cell 3 done: Assert context and capacity init

-- =============================================================================
-- Cell 4: Act – MakeReservation (one specific instance, e.g. seat M3)
-- =============================================================================
-- Reserves the instance with instance_identifier = 'M3'. Store journal_id for optional Cell 4.5.

-- IMPORTANT: MakeReservation BLOCKS on RESERVATION_EVENTS_Q (correlation
-- 'RES_<journal_id>') until Session B publishes a CONFIRM. Run Cell 4b
-- (below) in a SECOND SQL session while this cell is blocked.

DECLARE
  v_user_id     NUMBER;
  v_instance_id NUMBER;
  v_journal_id  NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_SpecificSeat';
  SELECT id INTO v_instance_id
  FROM ResourceInstance ri
  JOIN ResourceAsset ra ON ri.asset_id = ra.id
  WHERE ra.name = 'MANUAL_Asset_SpecificSeat' AND ri.instance_identifier = 'M3';

  ResourceManagement.MakeReservation(
    p_context_identifier => 'MANUAL_SpecificSeat',
    p_user_id            => v_user_id,
    p_instance_id        => v_instance_id,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_journal_id
  );

  DBMS_OUTPUT.PUT_LINE('Cell 4: MakeReservation done. Instance M3 (id=' || v_instance_id || '), journal_id=' || v_journal_id);
END;
/

PROMPT Cell 4 done: MakeReservation (instance M3)

-- =============================================================================
-- Cell 4b: [SESSION B] Publish CONFIRM to unblock Cell 4
-- =============================================================================
-- DECLARE
--   v_user_id     NUMBER;
--   v_instance_id NUMBER;
-- BEGIN
--   SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_SpecificSeat';
--   SELECT ri.id INTO v_instance_id
--   FROM ResourceInstance ri
--   JOIN ResourceAsset ra ON ri.asset_id = ra.id
--   WHERE ra.name = 'MANUAL_Asset_SpecificSeat' AND ri.instance_identifier = 'M3';
--   ResourceManagement.publish_reservation_event(
--     p_resource_id        => v_instance_id,
--     p_context_identifier => 'MANUAL_SpecificSeat',
--     p_user_id            => v_user_id,
--     p_action             => 'CONFIRM'
--   );
-- END;
-- /

SELECT * FROM RESERVJRNL_CAPACITY;

-- =============================================================================
-- Cell 4.5: Optional – ConfirmReservation(journal_id)
-- =============================================================================
-- Run this cell to confirm the reservation (status: reserved → confirmed).
-- If you skip it, assertions in Cell 5/6 expect status 'reserved'; if you run it, expect 'confirmed'.

DECLARE
  v_journal_id NUMBER;
BEGIN
  SELECT id INTO v_journal_id
  FROM (
    SELECT id, ROW_NUMBER() OVER (ORDER BY entry_timestamp DESC) AS rn
    FROM AllocationJournal
    WHERE context_id = (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_SpecificSeat')
  )
  WHERE rn = 1;
  ResourceManagement.ConfirmReservation(v_journal_id);
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 4.5: ConfirmReservation(journal_id=' || v_journal_id || ') done. Status is now confirmed.');
END;
/

PROMPT Cell 4.5 done: ConfirmReservation (optional)

-- =============================================================================
-- Cell 5: Assert – CurrentAllocations 1 row (reserved/confirmed) or 0 (cancelled), instance M3
-- =============================================================================
-- CurrentAllocations shows latest per (instance, context). Works with or without Cell 4.5.

SELECT ca.journal_id, ca.context_id, ca.resource_instance_id, ri.instance_identifier, ca.status
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
WHERE ac.context_identifier = 'MANUAL_SpecificSeat';
-- Expected: 1 row (reserved/confirmed) or 0 rows (cancelled)

DECLARE
  v_ca_count NUMBER;
  v_status   VARCHAR2(20);
  v_inst     VARCHAR2(50);
BEGIN
  SELECT COUNT(*), MAX(ca.status), MAX(ri.instance_identifier)
  INTO v_ca_count, v_status, v_inst
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
  WHERE ac.context_identifier = 'MANUAL_SpecificSeat';
  IF v_ca_count = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Cell 5: CurrentAllocations 0 rows (cancelled) [PASS]');
  ELSIF v_ca_count = 1 AND v_inst = 'M3' AND v_status IN ('reserved', 'confirmed') THEN
    DBMS_OUTPUT.PUT_LINE('Cell 5: 1 current allocation, instance M3, status=' || v_status || ' [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 5: CurrentAllocations count/status unexpected (count=' || v_ca_count ||
      ', inst=' || NVL(v_inst, 'NULL') || ', status=' || NVL(v_status, 'NULL') || ') [FAIL]');
  END IF;
END;
/

PROMPT Cell 5: Check – CurrentAllocations 1 row or 0 rows

-- =============================================================================
-- Cell 6: Assert – Capacity.active_count = 1 or 0, CurrentAllocations 1 or 0
-- =============================================================================

SELECT c.context_id, c.category_id, rc.name AS category_name,
       c.total_capacity, c.active_count
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_SpecificSeat';
-- Expected: active_count = 1 (confirmed/reserved) or 0 (cancelled), total_capacity = 10

SELECT ca.journal_id, ca.context_id, ca.resource_instance_id, ri.instance_identifier, ca.status
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
WHERE ac.context_identifier = 'MANUAL_SpecificSeat';
-- Expected: 1 row (instance M3) or 0 rows (cancelled)

DECLARE
  v_active   NUMBER;
  v_total    NUMBER;
  v_ca_count NUMBER;
BEGIN
  SELECT c.active_count, c.total_capacity INTO v_active, v_total
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE ac.context_identifier = 'MANUAL_SpecificSeat' AND rc.name = 'MANUAL_Business_Class';
  SELECT COUNT(*) INTO v_ca_count
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_SpecificSeat';

  IF (v_active = 1 AND v_total = 10 AND v_ca_count = 1) OR
     (v_active = 0 AND v_total = 10 AND v_ca_count = 0) THEN
    DBMS_OUTPUT.PUT_LINE('Cell 6: Capacity and CurrentAllocations consistent [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 6: Capacity active_count=' || v_active || ', total_capacity=' || v_total ||
      ', CurrentAllocations=' || v_ca_count || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 6: Check Capacity and CurrentAllocations (1 or 0 rows)

-- =============================================================================
-- Cell 7: Assert – GetAvailableSeatCount = 9 or 10
-- =============================================================================

SELECT ResourceManagement.GetAvailableSeatCount('MANUAL_SpecificSeat', 'MANUAL_Business_Class') AS available_seats
FROM DUAL;
-- Expected: 9 (confirmed/reserved) or 10 (cancelled)

DECLARE
  v_avail NUMBER;
BEGIN
  v_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_SpecificSeat', 'MANUAL_Business_Class');
  DBMS_OUTPUT.PUT_LINE('Cell 7: GetAvailableSeatCount = ' || v_avail ||
    CASE WHEN v_avail IN (9, 10) THEN ' [PASS]' ELSE ' [FAIL]' END);
END;
/

PROMPT Cell 7: Check GetAvailableSeatCount (expect 9 or 10)

-- =============================================================================
-- Cell 8: Teardown – delete test data (FK order)
-- =============================================================================

DELETE FROM ActiveAllocation
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_SpecificSeat');
DELETE FROM AllocationJournal
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_SpecificSeat');
DELETE FROM Capacity
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_SpecificSeat');
DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_SpecificSeat';
DELETE FROM ResourceInstance
WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_SpecificSeat');
DELETE FROM AssetCapacity
WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_SpecificSeat');
DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_SpecificSeat';
DELETE FROM Users WHERE name = 'MANUAL_User_SpecificSeat';
DELETE FROM ResourceCategory WHERE name = 'MANUAL_Business_Class';
COMMIT;

BEGIN
  DBMS_OUTPUT.PUT_LINE('Cell 8: Teardown complete.');
END;
/
PROMPT Cell 8 done: Teardown complete
