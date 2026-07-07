-- =============================================================================
-- MANUAL_CancelFlight.sql (#15)
-- =============================================================================
-- Manual, cell-style test: CancelFlight – mass cancellation of all reservations
-- on a context. Create 2 reservations, confirm both, then CancelFlight; assert
-- all resources of the asset blocked (not just allocated ones), active_count=10,
-- CurrentAllocations 10, GetAvailableSeatCount=0.
--
-- Setup: Cell 1 = reference data; Cell 2 = Data Setup (CRUD: category, user,
-- asset, capacity, instances, context). AddAllocationContext initializes capacity.
--
-- Run cells in order. In SQL Developer: select from "-- ===== Cell N:" to the
-- start of the next cell, then Execute.
--
-- Cell index:
--   0  Cleanup (optional first)
--   1  Reference data (ResourceStatus, ResourceInstanceStatus)
--   2  Data Setup – category, user, asset, capacity, instances, context
--   3  Assert: context + capacity init (active_count=0)
--   4  Act: MakeReservation(2 seats, timeout)
--   5  Act: ConfirmReservation for both journal_ids (so they stay active)
--   6  Assert: 2 current allocations, active_count=2, GetAvailableSeatCount=8
--   7  Act: CancelFlight(context_identifier, reason)
--   8  Assert: all resources of asset blocked, active_count=10, CurrentAllocations 10, GetAvailableSeatCount=0
--   9  Teardown
--
-- Test identifier: context_identifier = 'MANUAL_CancelFlight'
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_CancelFlight (#15) ===');
  DBMS_OUTPUT.PUT_LINE('2 reservations → confirm both → CancelFlight → all resources of asset blocked.');
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
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CancelFlight');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CancelFlight');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CancelFlight');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_CancelFlight';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CancelFlight');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CancelFlight');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_CancelFlight';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name = 'MANUAL_User_CancelFlight';
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

  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_CancelFlight';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddUser('MANUAL_User_CancelFlight');
  END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Asset_CancelFlight';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceAsset('MANUAL_Asset_CancelFlight', NULL, 'active');
  END IF;

  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Asset_CancelFlight' AND c.name = 'MANUAL_Business_Class';
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

  SELECT COUNT(*) INTO v_ctx_count FROM AllocationContext WHERE context_identifier = 'MANUAL_CancelFlight';
  IF v_ctx_count = 0 THEN
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CancelFlight';
    ResourceManagement_Data.AddAllocationContext(v_asset_id, 'MANUAL_CancelFlight', SYSDATE + 1, SYSDATE + 2);
  END IF;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data Setup complete (category, user, asset, capacity, instances, context).');
END;
/

PROMPT Cell 2 done: Data Setup

-- =============================================================================
-- Cell 3: Assert – context and capacity init (active_count=0)
-- =============================================================================

SELECT ac.id AS context_id, ac.context_identifier, ac.asset_id, ac.start_date, ac.end_date
FROM AllocationContext ac
WHERE ac.context_identifier = 'MANUAL_CancelFlight';

SELECT c.context_id, c.category_id, rc.name AS category_name,
       c.total_capacity, c.active_count
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_CancelFlight';

DECLARE
  v_ctx_count   NUMBER;
  v_cap_count   NUMBER;
  v_total_cap   NUMBER;
  v_active      NUMBER;
  v_ok          BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_ctx_count
  FROM AllocationContext
  WHERE context_identifier = 'MANUAL_CancelFlight';
  SELECT COUNT(*), MAX(c.total_capacity), MAX(c.active_count)
  INTO v_cap_count, v_total_cap, v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_CancelFlight';
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
-- Cell 4: Act – MakeReservation(2 seats, timeout 15 min) – BLOCKS
-- =============================================================================
-- Reserves 2 seats then BLOCKS on RESERVATION_EVENTS_Q until Session B
-- publishes CONFIRM via Cell 4b. On CONFIRM the procedure transitions all
-- group seats to 'confirmed' before returning, so Cell 5 (ConfirmReservation
-- loop) becomes a no-op.

DECLARE
  v_user_id NUMBER;
  v_leader  NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_CancelFlight';
  ResourceManagement.MakeReservation(
    p_context_identifier => 'MANUAL_CancelFlight',
    p_user_id            => v_user_id,
    p_category_name      => 'MANUAL_Business_Class',
    p_quantity           => 2,
    p_timeout_minutes    => 15,
    p_new_journal_id     => v_leader
  );
  DBMS_OUTPUT.PUT_LINE('Cell 4: MakeReservation(2) returned. group_leader_journal_id = ' || NVL(TO_CHAR(v_leader), 'NULL'));
END;
/

PROMPT Cell 4 done: MakeReservation(2)

-- =============================================================================
-- Cell 4b: [SESSION B] Publish CONFIRM to unblock Cell 4
-- =============================================================================
-- Run in a SECOND SQL session while Cell 4 is blocked.

-- DECLARE
--   v_user_id NUMBER;
-- BEGIN
--   SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_CancelFlight';
--   ResourceManagement.publish_group_reservation_event(
--     p_context_identifier => 'MANUAL_CancelFlight',
--     p_user_id            => v_user_id,
--     p_category_name      => 'MANUAL_Business_Class',
--     p_action             => 'CONFIRM'
--   );
-- END;
-- /

SELECT * FROM RESERVJRNL_CAPACITY;

-- =============================================================================
-- Cell 5: Act – ConfirmReservation for both journal_ids (so they stay active)
-- =============================================================================

DECLARE
  v_count      NUMBER := 0;
  v_reserved   NUMBER := 0;
BEGIN
  SELECT COUNT(*) INTO v_reserved
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_CancelFlight'
    AND ca.status = 'reserved';

  IF v_reserved = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Cell 5: No reserved allocations (cancelled). SKIP confirm step or rerun Cell 4.');
    RETURN;
  END IF;

  FOR r IN (
    SELECT ca.journal_id
    FROM CurrentAllocations ca
    JOIN AllocationContext ac ON ca.context_id = ac.id
    WHERE ac.context_identifier = 'MANUAL_CancelFlight'
      AND ca.status = 'reserved'
    ORDER BY ca.journal_id
  ) LOOP
    ResourceManagement.ConfirmReservation(r.journal_id);
    v_count := v_count + 1;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 5: ConfirmReservation done for ' || v_count || ' journal(s).');
END;
/

PROMPT Cell 5 done: ConfirmReservation (both)

-- =============================================================================
-- Cell 6: Assert – 2 current allocations (confirmed) or 0 (cancelled)
-- =============================================================================

SELECT ca.journal_id, ca.context_id, ca.status
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
WHERE ac.context_identifier = 'MANUAL_CancelFlight'
ORDER BY ca.journal_id;

SELECT c.active_count, c.total_capacity
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_CancelFlight' AND rc.name = 'MANUAL_Business_Class';

SELECT ResourceManagement.GetAvailableSeatCount('MANUAL_CancelFlight', 'MANUAL_Business_Class') AS available_seats FROM DUAL;

DECLARE
  v_ca_count NUMBER;
  v_active   NUMBER;
  v_avail    NUMBER;
  v_ok       BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_ca_count
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_CancelFlight';
  SELECT c.active_count INTO v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE ac.context_identifier = 'MANUAL_CancelFlight' AND rc.name = 'MANUAL_Business_Class';
  v_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_CancelFlight', 'MANUAL_Business_Class');

  IF NOT ((v_ca_count = 2 AND v_active = 2 AND v_avail = 8) OR
          (v_ca_count = 0 AND v_active = 0 AND v_avail = 10)) THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 6: Expected (2,2,8) or (0,0,10); actual ca=' || v_ca_count ||
      ', active=' || v_active || ', avail=' || v_avail || ' [FAIL]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 6: CurrentAllocations/Capacity consistent with confirm/cancel [PASS]');
  END IF;
END;
/

PROMPT Cell 6 done: Assert before CancelFlight

-- =============================================================================
-- Cell 7: Act – CancelFlight(context_identifier, reason)
-- =============================================================================
-- CancelFlight blocks ALL resources of the asset (all 10 seats), not just the
-- 2 that were allocated. Timeouts are cancelled for user reservations; then
-- BlockResource is called for every ResourceInstance of the context's asset.

BEGIN
  ResourceManagement.CancelFlight(
    p_context_identifier => 'MANUAL_CancelFlight',
    p_reason              => 'Manual test: mass cancellation'
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 7: CancelFlight done (all resources of asset blocked). COMMIT issued.');
END;
/

PROMPT Cell 7 done: CancelFlight (blocks all resources of asset)

-- =============================================================================
-- Cell 8: Assert – all resources of asset blocked, active_count=10, CurrentAllocations 10, GetAvailableSeatCount=0
-- =============================================================================

SELECT ca.journal_id, ca.resource_instance_id, ca.status
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
WHERE ac.context_identifier = 'MANUAL_CancelFlight'
ORDER BY ca.journal_id;
-- Expected: 10 rows (all seats), status = 'blocked'

SELECT c.active_count, c.total_capacity
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_CancelFlight' AND rc.name = 'MANUAL_Business_Class';
-- Expected: active_count = 10, total_capacity = 10 (all resources blocked)

SELECT COUNT(*) AS current_alloc_count
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
WHERE ac.context_identifier = 'MANUAL_CancelFlight';
-- Expected: 10 (all resources of asset blocked)

SELECT ResourceManagement.GetAvailableSeatCount('MANUAL_CancelFlight', 'MANUAL_Business_Class') AS available_seats FROM DUAL;
-- Expected: 0 (all resources blocked, none available)

DECLARE
  v_ctx_id     NUMBER;
  v_active     NUMBER;
  v_ca_count   NUMBER;
  v_avail      NUMBER;
  v_ok         BOOLEAN := TRUE;
  v_blocked    NUMBER := 0;
  v_total_cap  NUMBER;
BEGIN
  SELECT id INTO v_ctx_id FROM AllocationContext WHERE context_identifier = 'MANUAL_CancelFlight';

  SELECT COUNT(*), COUNT(CASE WHEN status = 'blocked' THEN 1 END)
  INTO v_ca_count, v_blocked
  FROM CurrentAllocations
  WHERE context_id = v_ctx_id;

  SELECT c.active_count, c.total_capacity INTO v_active, v_total_cap
  FROM Capacity c
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE c.context_id = v_ctx_id AND rc.name = 'MANUAL_Business_Class';
  v_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_CancelFlight', 'MANUAL_Business_Class');

  IF v_blocked != v_total_cap THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 8: CurrentAllocations blocked count = ' || v_blocked || ' [FAIL – expect ' || v_total_cap || ']');
  END IF;
  IF v_active != v_total_cap THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 8: active_count = ' || v_active || ' [FAIL – expect ' || v_total_cap || ']');
  END IF;
  IF v_ca_count != v_total_cap THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 8: CurrentAllocations count = ' || v_ca_count || ' [FAIL – expect ' || v_total_cap || ']');
  END IF;
  IF v_avail != 0 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 8: GetAvailableSeatCount = ' || v_avail || ' [FAIL – expect 0]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 8: All resources blocked, active_count=' || v_total_cap || ', CurrentAllocations=' || v_total_cap || ', available=0 [PASS]');
  END IF;
END;
/

PROMPT Cell 8 done: Assert after CancelFlight (all resources blocked, available=0)

-- =============================================================================
-- Cell 9: Teardown
-- =============================================================================

DECLARE
  v_j NUMBER; v_aa NUMBER; v_c NUMBER; v_ctx NUMBER; v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CancelFlight');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CancelFlight');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CancelFlight');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_CancelFlight';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CancelFlight');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CancelFlight');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_CancelFlight';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name = 'MANUAL_User_CancelFlight';
  v_u := SQL%ROWCOUNT;
  DELETE FROM ResourceCategory WHERE name = 'MANUAL_Business_Class';
  v_rc := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Teardown: J=' || v_j || ' AA=' || v_aa || ' Cap=' || v_c ||
    ' Ctx=' || v_ctx || ' RI=' || v_ri || ' AC=' || v_ac || ' RA=' || v_ra ||
    ' U=' || v_u || ' RC=' || v_rc);
END;
/
PROMPT Cell 9 done: Teardown complete
