-- =============================================================================
-- MANUAL_MakeReservation_CapacityExhausted.sql
-- =============================================================================
-- Manual, cell-style test: MakeReservation – capacity exhausted.
-- Request more seats than available (capacity 2, request 3). Expect exception
-- -20001 "Not enough seats available"; no new journal rows, capacity unchanged.
--
-- Setup: Cell 1 = reference data; Cell 2 = Data Setup (CRUD: category, user,
-- asset, capacity 2, 2 instances, context). AddAllocationContext initializes capacity.
--
-- Run cells in order. In SQL Developer: select from "-- ===== Cell N:" to the
-- start of the next cell, then Execute.
--
-- Cell index:
--   0  Cleanup (optional first)
--   1  Reference data (ResourceStatus, ResourceInstanceStatus)
--   2  Data Setup – category, user, asset, capacity 2, 2 instances (M1, M2), context
--   3  Assert: context + capacity init (AllocationContext 1, Capacity 1, total_capacity=2, active_count=0)
--   4  Act: MakeReservation(3 seats) – expect exception -20001
--   5  Assert: no reserved journal rows, active_count=0, GetAvailableSeatCount=2
--   6  Teardown
--
-- Test identifier: context_identifier = 'MANUAL_CapacityExhausted'
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_CapacityExhausted – MakeReservation(3) on capacity 2 ===');
  DBMS_OUTPUT.PUT_LINE('Expect exception -20001 "Not enough seats available"; state unchanged.');
  DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- Cell 0: Cleanup (optional – run first to remove leftover data from last run)
-- =============================================================================

DECLARE
  v_j NUMBER; v_aa NUMBER; v_c NUMBER; v_ctx NUMBER; v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CapacityExhausted');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CapacityExhausted');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CapacityExhausted');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_CapacityExhausted';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CapacityExhausted');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CapacityExhausted');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_CapacityExhausted';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name = 'MANUAL_User_CapacityExhausted';
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
-- Cell 1: Reference data (ResourceStatus, ResourceInstanceStatus) – CRUD
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
-- Cell 2: Data Setup – category, user, asset, capacity 2, 2 instances, context
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

  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_CapacityExhausted';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddUser('MANUAL_User_CapacityExhausted');
  END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Asset_CapacityExhausted';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceAsset('MANUAL_Asset_CapacityExhausted', NULL, 'active');
  END IF;

  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Asset_CapacityExhausted' AND c.name = 'MANUAL_Business_Class';
  SELECT COUNT(*) INTO v_count FROM AssetCapacity WHERE asset_id = v_asset_id AND category_id = v_category_id;
  IF v_count = 0 THEN
    ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_category_id, 2);
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM ResourceInstance WHERE asset_id = v_asset_id;
  IF v_cnt = 0 THEN
    FOR v_i IN 1..2 LOOP
      ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'M' || v_i, 'available');
    END LOOP;
  END IF;

  SELECT COUNT(*) INTO v_ctx_count FROM AllocationContext WHERE context_identifier = 'MANUAL_CapacityExhausted';
  IF v_ctx_count = 0 THEN
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CapacityExhausted';
    ResourceManagement_Data.AddAllocationContext(v_asset_id, 'MANUAL_CapacityExhausted', SYSDATE + 1, SYSDATE + 2);
  END IF;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data Setup complete (capacity 2, 2 instances).');
END;
/

PROMPT Cell 2 done: Data Setup

-- =============================================================================
-- Cell 3: Assert – context and capacity init (total_capacity=2, active_count=0)
-- =============================================================================

SELECT ac.id AS context_id, ac.context_identifier, ac.asset_id, ac.start_date, ac.end_date
FROM AllocationContext ac
WHERE ac.context_identifier = 'MANUAL_CapacityExhausted';

SELECT c.id AS capacity_id, c.context_id, c.category_id, rc.name AS category_name,
       c.total_capacity, c.active_count
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_CapacityExhausted';

DECLARE
  v_ctx_count   NUMBER;
  v_cap_count   NUMBER;
  v_total_cap   NUMBER;
  v_active      NUMBER;
  v_ok          BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_ctx_count
  FROM AllocationContext
  WHERE context_identifier = 'MANUAL_CapacityExhausted';
  IF v_ctx_count != 1 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: AllocationContext: expected 1 row, actual ' || v_ctx_count || ' [FAIL]');
  END IF;

  SELECT COUNT(*), MAX(c.total_capacity), MAX(c.active_count)
  INTO v_cap_count, v_total_cap, v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_CapacityExhausted';
  IF v_cap_count != 1 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: Capacity: expected 1 row, actual ' || v_cap_count || ' [FAIL]');
  END IF;
  IF v_total_cap != 2 OR v_active != 0 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: Capacity: expected total_capacity=2, active_count=0; actual total_capacity=' ||
      v_total_cap || ', active_count=' || v_active || ' [FAIL]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 3: Context + capacity init OK: total_capacity=2, active_count=0 [PASS]');
  END IF;
END;
/

PROMPT Cell 3 done: Assert context and capacity init

-- =============================================================================
-- Cell 4: Act – MakeReservation(3) – expect exception -20001
-- =============================================================================

DECLARE
  v_user_id     NUMBER;
  v_leader      NUMBER;
  v_exception   BOOLEAN := FALSE;
  v_sqlcode     NUMBER;
  v_sqlerrm     VARCHAR2(4000);
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_CapacityExhausted';

  BEGIN
    -- Capacity check raises -20001 in the reserve phase, BEFORE the AQ
    -- dequeue, so this call returns synchronously without blocking.
    ResourceManagement.MakeReservation(
      p_context_identifier => 'MANUAL_CapacityExhausted',
      p_user_id            => v_user_id,
      p_category_name      => 'MANUAL_Business_Class',
      p_quantity           => 3,
      p_timeout_minutes    => 5,
      p_new_journal_id     => v_leader
    );
    DBMS_OUTPUT.PUT_LINE('Cell 4: MakeReservation(3) did NOT raise – expected exception [FAIL]');
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlcode := SQLCODE;
      v_sqlerrm := SQLERRM;
      v_exception := TRUE;
      ROLLBACK;
      IF v_sqlcode = -20001 THEN
        DBMS_OUTPUT.PUT_LINE('Cell 4: Expected exception -20001 raised: ' || SUBSTR(v_sqlerrm, 1, 200) || ' [PASS]');
      ELSE
        DBMS_OUTPUT.PUT_LINE('Cell 4: Exception raised but code=' || v_sqlcode || ' (expected -20001): ' || SUBSTR(v_sqlerrm, 1, 200) || ' [FAIL]');
      END IF;
  END;
END;
/

PROMPT Cell 4 done: MakeReservation(3) – expect -20001

SELECT * FROM RESERVJRNL_CAPACITY;

-- =============================================================================
-- Cell 5: Assert – no reserved journal rows, active_count=0, GetAvailableSeatCount=2
-- =============================================================================

SELECT COUNT(*) AS reserved_count
FROM AllocationJournal
WHERE context_id = (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CapacityExhausted')
  AND status = 'reserved';

SELECT c.total_capacity, c.active_count
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_CapacityExhausted' AND rc.name = 'MANUAL_Business_Class';

SELECT ResourceManagement.GetAvailableSeatCount('MANUAL_CapacityExhausted', 'MANUAL_Business_Class') AS available_seats FROM DUAL;

DECLARE
  v_reserved   NUMBER;
  v_active     NUMBER;
  v_total     NUMBER;
  v_avail     NUMBER;
  v_ok        BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_reserved
  FROM AllocationJournal
  WHERE context_id = (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CapacityExhausted')
    AND status = 'reserved';
  SELECT c.active_count, c.total_capacity INTO v_active, v_total
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE ac.context_identifier = 'MANUAL_CapacityExhausted' AND rc.name = 'MANUAL_Business_Class';
  v_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_CapacityExhausted', 'MANUAL_Business_Class');

  IF v_reserved != 0 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 5: Reserved journal count: expected 0, actual ' || v_reserved || ' [FAIL]');
  END IF;
  IF v_active != 0 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 5: active_count: expected 0, actual ' || v_active || ' [FAIL]');
  END IF;
  IF v_avail != 2 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 5: GetAvailableSeatCount: expected 2, actual ' || v_avail || ' [FAIL]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 5: State unchanged: reserved=0, active_count=0, available=2 [PASS]');
  END IF;
END;
/

PROMPT Cell 5 done: Assert state unchanged

-- =============================================================================
-- Cell 6: Teardown
-- =============================================================================

DELETE FROM ActiveAllocation
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CapacityExhausted');
DELETE FROM AllocationJournal
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CapacityExhausted');
DELETE FROM Capacity
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CapacityExhausted');
DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_CapacityExhausted';
DELETE FROM ResourceInstance
WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CapacityExhausted');
DELETE FROM AssetCapacity
WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CapacityExhausted');
DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_CapacityExhausted';
DELETE FROM Users WHERE name = 'MANUAL_User_CapacityExhausted';
DELETE FROM ResourceCategory WHERE name = 'MANUAL_Business_Class';
COMMIT;

BEGIN
  DBMS_OUTPUT.PUT_LINE('Cell 6: Teardown complete.');
END;
/
PROMPT Cell 6 done: Teardown complete
