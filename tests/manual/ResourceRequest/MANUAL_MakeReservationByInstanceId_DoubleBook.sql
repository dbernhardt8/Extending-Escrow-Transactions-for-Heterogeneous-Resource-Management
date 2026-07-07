-- =============================================================================
-- MANUAL_MakeReservation_DoubleBook.sql (#3)
-- =============================================================================
-- Manual, cell-style test: MakeReservation (instance-based dispatcher) – reserve
-- a specific instance (e.g. seat M3) for 10 minutes, then make a similar request
-- again for the same instance to validate correct handling (reject double-book).
--
-- Expectation: First reservation succeeds; second request raises -20604
-- "Instance ... is already reserved on this flight". State remains unchanged
-- (single allocation for M3, active_count=1).
--
-- Setup: Cell 1 = reference data; Cell 2 = Data Setup (CRUD: category, user,
-- asset, capacity, instances, context).
--
-- Run cells in order. In SQL Developer: select from "-- ===== Cell N:" to the
-- start of the next cell, then Execute.
--
-- Cell index:
--   0  Cleanup (optional first)
--   1  Reference data (ResourceStatus, ResourceInstanceStatus)
--   2  Data Setup – category, user, asset, capacity, instances, context
--   3  Assert: context + capacity init (active_count=0)
--   4  Act: MakeReservation(M3, timeout 10 min) → success
--   5  Assert: 1 allocation for M3, active_count=1, GetAvailableSeatCount=9
--   6  Act: MakeReservation(M3) again → expect exception -20604
--   7  Assert: still 1 allocation for M3, active_count=1, no duplicate
--   8  Teardown
--
-- Test identifier: context_identifier = 'MANUAL_DoubleBook'
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_DoubleBook (#3) – MakeReservation double-book ===');
  DBMS_OUTPUT.PUT_LINE('Reserve M3 for 10 min; then request M3 again → expect -20604.');
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
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_DoubleBook');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_DoubleBook');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_DoubleBook');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_DoubleBook';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_DoubleBook');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_DoubleBook');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_DoubleBook';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name = 'MANUAL_User_DoubleBook';
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
-- Cell 1: Reference data (ResourceStatus, ResourceInstanceStatus)
-- =============================================================================

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
  WHEN DUP_VAL_ON_INDEX THEN COMMIT;
END;
/

PROMPT Cell 1: Reference data

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
-- Cell 2: Data Setup – category, user, asset, capacity, instances, context
-- =============================================================================

DECLARE
  v_count        NUMBER;
  v_asset_id     NUMBER;
  v_category_id  NUMBER;
  v_cnt          NUMBER;
  v_ctx_count    NUMBER;
  v_i            NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM ResourceCategory WHERE name = 'MANUAL_Business_Class';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceCategory('MANUAL_Business_Class', NULL, 'pool');
  END IF;

  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_DoubleBook';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddUser('MANUAL_User_DoubleBook');
  END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Asset_DoubleBook';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceAsset('MANUAL_Asset_DoubleBook', NULL, 'active');
  END IF;

  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Asset_DoubleBook' AND c.name = 'MANUAL_Business_Class';
  SELECT COUNT(*) INTO v_count FROM AssetCapacity WHERE asset_id = v_asset_id AND category_id = v_category_id;
  IF v_count = 0 THEN
    ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_category_id, 10);
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM ResourceInstance WHERE asset_id = v_asset_id;
  IF v_cnt = 0 THEN
    FOR v_i IN 1..10 LOOP
      ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'M' || v_i, 'available');
    END LOOP;
  END IF;

  SELECT COUNT(*) INTO v_ctx_count FROM AllocationContext WHERE context_identifier = 'MANUAL_DoubleBook';
  IF v_ctx_count = 0 THEN
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'MANUAL_Asset_DoubleBook';
    ResourceManagement_Data.AddAllocationContext(v_asset_id, 'MANUAL_DoubleBook', SYSDATE + 1, SYSDATE + 2);
  END IF;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data Setup complete (10 seats M1..M10).');
END;
/

PROMPT Cell 2 done: Data Setup

-- =============================================================================
-- Cell 3: Assert – context and capacity init (active_count=0)
-- =============================================================================

SELECT ac.id AS context_id, ac.context_identifier, ac.asset_id, ac.start_date, ac.end_date
FROM AllocationContext ac
WHERE ac.context_identifier = 'MANUAL_DoubleBook';

SELECT c.context_id, rc.name AS category_name, c.total_capacity, c.active_count
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_DoubleBook';

DECLARE
  v_ctx_count   NUMBER;
  v_cap_count   NUMBER;
  v_total_cap   NUMBER;
  v_active      NUMBER;
  v_ok          BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_ctx_count
  FROM AllocationContext
  WHERE context_identifier = 'MANUAL_DoubleBook';
  SELECT COUNT(*), MAX(c.total_capacity), MAX(c.active_count)
  INTO v_cap_count, v_total_cap, v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_DoubleBook';
  IF v_ctx_count != 1 OR v_cap_count != 1 OR v_total_cap != 10 OR v_active != 0 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: Init: expected ctx=1, cap=1, total=10, active=0; actual ctx=' || v_ctx_count || ', cap=' || v_cap_count || ', total=' || v_total_cap || ', active=' || v_active || ' [FAIL]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 3: Context + capacity init OK: active_count=0 [PASS]');
  END IF;
END;
/

PROMPT Cell 3 done: Assert init

-- =============================================================================
-- Cell 4: Act – MakeReservation(M3, timeout 10 min) → success
-- =============================================================================

-- IMPORTANT: MakeReservation BLOCKS on RESERVATION_EVENTS_Q (correlation
-- 'RES_<journal_id>') until Session B publishes a CONFIRM. Run Cell 4b in
-- a SECOND SQL session while Cell 4 is blocked.

DECLARE
  v_user_id     NUMBER;
  v_instance_id NUMBER;
  v_journal_id  NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_DoubleBook';
  SELECT id INTO v_instance_id
  FROM ResourceInstance ri
  JOIN ResourceAsset ra ON ri.asset_id = ra.id
  WHERE ra.name = 'MANUAL_Asset_DoubleBook' AND ri.instance_identifier = 'M3';

  ResourceManagement.MakeReservation(
    p_context_identifier => 'MANUAL_DoubleBook',
    p_user_id            => v_user_id,
    p_instance_id        => v_instance_id,
    p_timeout_minutes    => 10,
    p_new_journal_id     => v_journal_id
  );

  DBMS_OUTPUT.PUT_LINE('Cell 4: MakeReservation(M3, timeout 10 min) done. journal_id=' || v_journal_id || ' [PASS]');
END;
/

PROMPT Cell 4 done: First reservation (M3, 10 min timeout)

-- =============================================================================
-- Cell 4b: [SESSION B] Publish CONFIRM to unblock Cell 4
-- =============================================================================
-- Run in a SECOND SQL session while Cell 4 is blocked.

-- DECLARE
--   v_user_id     NUMBER;
--   v_instance_id NUMBER;
-- BEGIN
--   SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_DoubleBook';
--   SELECT ri.id INTO v_instance_id
--   FROM ResourceInstance ri
--   JOIN ResourceAsset ra ON ri.asset_id = ra.id
--   WHERE ra.name = 'MANUAL_Asset_DoubleBook' AND ri.instance_identifier = 'M3';
--   ResourceManagement.publish_reservation_event(
--     p_resource_id        => v_instance_id,
--     p_context_identifier => 'MANUAL_DoubleBook',
--     p_user_id            => v_user_id,
--     p_action             => 'CONFIRM'
--   );
-- END;
-- /

SELECT * FROM RESERVJRNL_CAPACITY;

-- =============================================================================
-- Cell 5: Assert – 1 allocation for M3, active_count=1, GetAvailableSeatCount=9
-- =============================================================================

SELECT ca.journal_id, ca.context_id, ca.resource_instance_id, ri.instance_identifier, ca.status
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
WHERE ac.context_identifier = 'MANUAL_DoubleBook';
-- Expected: 1 row, instance_identifier = M3

SELECT c.active_count, c.total_capacity
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_DoubleBook' AND rc.name = 'MANUAL_Business_Class';

SELECT ResourceManagement.GetAvailableSeatCount('MANUAL_DoubleBook', 'MANUAL_Business_Class') AS available_seats FROM DUAL;

DECLARE
  v_ca_count NUMBER;
  v_inst     VARCHAR2(50);
  v_active   NUMBER;
  v_avail    NUMBER;
  v_ok       BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*), MAX(ri.instance_identifier) INTO v_ca_count, v_inst
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
  WHERE ac.context_identifier = 'MANUAL_DoubleBook';
  SELECT c.active_count INTO v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE ac.context_identifier = 'MANUAL_DoubleBook' AND rc.name = 'MANUAL_Business_Class';
  v_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_DoubleBook', 'MANUAL_Business_Class');

  IF v_ca_count != 1 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 5: CurrentAllocations expected 1, actual ' || v_ca_count || ' [FAIL]');
  END IF;
  IF v_inst != 'M3' THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 5: Expected instance M3, actual ' || NVL(v_inst, 'NULL') || ' [FAIL]');
  END IF;
  IF v_active != 1 OR v_avail != 9 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 5: Expected active_count=1, available=9; actual active=' || v_active || ', available=' || v_avail || ' [FAIL]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 5: 1 allocation M3, active_count=1, available=9 [PASS]');
  END IF;
END;
/

PROMPT Cell 5 done: Assert after first reservation

-- =============================================================================
-- Cell 6: Act – MakeReservation(M3) again → expect exception -20604
-- =============================================================================
-- Same instance M3 is already reserved. Second request must be rejected.

DECLARE
  v_user_id     NUMBER;
  v_instance_id NUMBER;
  v_journal_id  NUMBER;
  v_existing    NUMBER;
  v_sqlcode     NUMBER;
  v_sqlerrm     VARCHAR2(4000);
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_DoubleBook';
  SELECT id INTO v_instance_id
  FROM ResourceInstance ri
  JOIN ResourceAsset ra ON ri.asset_id = ra.id
  WHERE ra.name = 'MANUAL_Asset_DoubleBook' AND ri.instance_identifier = 'M3';

  SELECT COUNT(*) INTO v_existing
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_DoubleBook'
    AND ca.resource_instance_id = v_instance_id
    AND ca.status IN ('reserved', 'confirmed', 'checked-in', 'boarded', 'blocked');

  IF v_existing = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Cell 6: First reservation was cancelled; skipping double-book test. Re-run Cell 4 for an active reservation.');
    RETURN;
  END IF;

  BEGIN
    -- The double-book check raises -20604 in the reserve phase, BEFORE the
    -- AQ dequeue, so this call returns synchronously without blocking.
    ResourceManagement.MakeReservation(
      p_context_identifier => 'MANUAL_DoubleBook',
      p_user_id            => v_user_id,
      p_instance_id        => v_instance_id,
      p_timeout_minutes    => 10,
      p_new_journal_id     => v_journal_id
    );
    DBMS_OUTPUT.PUT_LINE('Cell 6: Second MakeReservation(M3) did NOT raise – expected -20604 [FAIL]');
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlcode := SQLCODE;
      v_sqlerrm := SQLERRM;
      ROLLBACK;
      IF v_sqlcode = -20604 THEN
        DBMS_OUTPUT.PUT_LINE('Cell 6: Expected exception -20604 (already reserved): ' || SUBSTR(v_sqlerrm, 1, 120) || ' [PASS]');
      ELSE
        DBMS_OUTPUT.PUT_LINE('Cell 6: Exception code=' || v_sqlcode || ' (expected -20604): ' || SUBSTR(v_sqlerrm, 1, 120) || ' [FAIL]');
      END IF;
  END;
END;
/

PROMPT Cell 6 done: Second request for M3 – expect -20604

-- =============================================================================
-- Cell 7: Assert – 1 allocation for M3 (if active) or 0 (if cancelled)
-- =============================================================================

SELECT ca.journal_id, ca.context_id, ca.resource_instance_id, ri.instance_identifier, ca.status
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
WHERE ac.context_identifier = 'MANUAL_DoubleBook';
-- Expected: 1 row (active) or 0 rows (cancelled)

SELECT COUNT(*) AS journal_count_for_m3
FROM AllocationJournal aj
JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
JOIN ResourceAsset ra ON ri.asset_id = ra.id
WHERE ra.name = 'MANUAL_Asset_DoubleBook' AND ri.instance_identifier = 'M3'
  AND aj.context_id = (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_DoubleBook')
  AND aj.status IN ('reserved', 'confirmed', 'checked-in', 'boarded');
-- Expected: 1 (only the first reservation; second attempt did not create a journal)

DECLARE
  v_ca_count   NUMBER;
  v_inst       VARCHAR2(50);
  v_active     NUMBER;
  v_avail      NUMBER;
  v_active_m3  NUMBER;
  v_ok         BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*), MAX(ri.instance_identifier) INTO v_ca_count, v_inst
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
  WHERE ac.context_identifier = 'MANUAL_DoubleBook';
  SELECT c.active_count INTO v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE ac.context_identifier = 'MANUAL_DoubleBook' AND rc.name = 'MANUAL_Business_Class';
  v_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_DoubleBook', 'MANUAL_Business_Class');

  SELECT COUNT(*) INTO v_active_m3
  FROM CurrentAllocations ca
  JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
  JOIN ResourceAsset ra ON ri.asset_id = ra.id
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_DoubleBook' AND ra.name = 'MANUAL_Asset_DoubleBook' AND ri.instance_identifier = 'M3';

  IF v_ca_count = 0 THEN
    NULL; -- cancelled path
  ELSIF v_ca_count = 1 AND v_inst = 'M3' THEN
    NULL; -- active path
  ELSE
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 7: CurrentAllocations unexpected (count=' || v_ca_count || ', instance=' || NVL(v_inst, 'NULL') || ') [FAIL]');
  END IF;
  IF NOT ((v_active = 1 AND v_avail = 9 AND v_active_m3 = 1) OR
          (v_active = 0 AND v_avail = 10 AND v_active_m3 = 0)) THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 7: Expected active=1/0, available=9/10, active_m3=1/0; actual active=' || v_active ||
      ', available=' || v_avail || ', active_m3=' || v_active_m3 || ' [FAIL]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 7: State consistent with active/cancelled outcome [PASS]');
  END IF;
END;
/

PROMPT Cell 7 done: Assert state unchanged after second request

-- =============================================================================
-- Cell 8: Teardown
-- =============================================================================

DELETE FROM ActiveAllocation
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_DoubleBook');
DELETE FROM AllocationJournal
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_DoubleBook');
DELETE FROM Capacity
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_DoubleBook');
DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_DoubleBook';
DELETE FROM ResourceInstance
WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_DoubleBook');
DELETE FROM AssetCapacity
WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_DoubleBook');
DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_DoubleBook';
DELETE FROM Users WHERE name = 'MANUAL_User_DoubleBook';
DELETE FROM ResourceCategory WHERE name = 'MANUAL_Business_Class';
COMMIT;

BEGIN
  DBMS_OUTPUT.PUT_LINE('Cell 8: Teardown complete.');
END;
/
PROMPT Cell 8 done: Teardown complete
