-- =============================================================================
-- MANUAL_Lifecycle_AllTransitions.sql
-- =============================================================================
-- Manual, cell-style test: All major allocation state transitions with assertions.
-- One reservation is driven through: reserved → confirmed → checked-in → boarded,
-- with inverse transitions (UnconfirmReservation, CancelCheckIn, DeboardUser)
-- and final completion via ReverseJournalEntry(..., 'completed', ...).
--
-- Setup: Cell 1 = reference data; Cell 2 = Data Setup (CRUD: category, user,
-- asset, capacity, instances, context).
--
-- Run cells in order. In SQL Developer: select from "-- ===== Cell N:" to the
-- start of the next cell, then Execute.
--
-- Cell index:
--   0   Cleanup (optional first)
--   1   Reference data
--   2   Data Setup – category, user, asset, 10 instances, context
--   3   Assert: context + capacity init (active_count=0)
--   4   Act: MakeReservation(1, timeout) → Assert reserved, active_count=1, CurrentAllocations 1
--   5   Act: ConfirmReservation → Assert confirmed
--   6   Act: UnconfirmReservation → Assert reserved (inverse)
--   7   Act: ConfirmReservation → Assert confirmed
--   8   Act: CheckInUser → Assert checked-in
--   9   Act: CancelCheckIn → Assert confirmed (inverse)
--  10   Act: CheckInUser → Assert checked-in
--  11   Act: BoardUser → Assert boarded
--  12   Act: DeboardUser → Assert checked-in (inverse)
--  13   Act: BoardUser → Assert boarded
--  14   Act: ReverseJournalEntry(completed) → Assert completed, CurrentAllocations 0
--  15   Teardown
--
-- Test identifier: context_identifier = 'MANUAL_Lifecycle'
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_Lifecycle – All major allocation state transitions ===');
  DBMS_OUTPUT.PUT_LINE('reserved → confirmed → [unconfirm] → confirmed → checked-in → [cancel check-in] → checked-in → boarded → [deboard] → boarded → completed');
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
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Lifecycle');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Lifecycle');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Lifecycle');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_Lifecycle';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Lifecycle');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Lifecycle');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_Lifecycle';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name = 'MANUAL_User_Lifecycle';
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
-- Cell 2: Data Setup – category, user, asset, 10 instances, context
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

  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_Lifecycle';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddUser('MANUAL_User_Lifecycle');
  END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Asset_Lifecycle';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceAsset('MANUAL_Asset_Lifecycle', NULL, 'active');
  END IF;

  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Asset_Lifecycle' AND c.name = 'MANUAL_Business_Class';
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

  SELECT COUNT(*) INTO v_ctx_count FROM AllocationContext WHERE context_identifier = 'MANUAL_Lifecycle';
  IF v_ctx_count = 0 THEN
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Lifecycle';
    ResourceManagement_Data.AddAllocationContext(v_asset_id, 'MANUAL_Lifecycle', SYSDATE + 1, SYSDATE + 2);
  END IF;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data Setup complete.');
END;
/

PROMPT Cell 2 done: Data Setup

-- =============================================================================
-- Cell 3: Assert – context and capacity init (active_count=0)
-- =============================================================================

DECLARE
  v_ctx_count   NUMBER;
  v_cap_count   NUMBER;
  v_total_cap   NUMBER;
  v_active      NUMBER;
  v_ok          BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_ctx_count
  FROM AllocationContext
  WHERE context_identifier = 'MANUAL_Lifecycle';
  SELECT COUNT(*), MAX(c.total_capacity), MAX(c.active_count)
  INTO v_cap_count, v_total_cap, v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle';
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
-- Cell 4: Act – MakeReservation(1, timeout 15 min) → Assert confirmed/reserved or cancelled
-- =============================================================================

-- IMPORTANT: MakeReservation BLOCKS on the AQ event queue until Session B
-- publishes a CONFIRM (or CANCEL). Run Cell 4b in a SECOND SQL session while
-- this cell is blocked. On CONFIRM the journal is already 'confirmed' when
-- this cell returns, so the subsequent ConfirmReservation call (Cell 5)
-- becomes idempotent / a no-op.

DECLARE
  v_user_id     NUMBER;
  v_leader      NUMBER;
  v_status      VARCHAR2(20);
  v_active      NUMBER;
  v_ca_count    NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_Lifecycle';
  ResourceManagement.MakeReservation(
    p_context_identifier => 'MANUAL_Lifecycle',
    p_user_id            => v_user_id,
    p_category_name      => 'MANUAL_Business_Class',
    p_quantity           => 1,
    p_timeout_minutes    => 15,
    p_new_journal_id     => v_leader
  );

  SELECT COUNT(*) INTO v_ca_count
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle';

  IF v_ca_count > 0 THEN
    SELECT ca.status INTO v_status
    FROM CurrentAllocations ca
    JOIN AllocationContext ac ON ca.context_id = ac.id
    WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  ELSE
    v_status := 'cancelled';
  END IF;
  SELECT c.active_count INTO v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND rc.name = 'MANUAL_Business_Class';
  IF (v_status IN ('reserved', 'confirmed') AND v_active = 1 AND v_ca_count = 1) OR
     (v_status = 'cancelled' AND v_active = 0 AND v_ca_count = 0) THEN
    DBMS_OUTPUT.PUT_LINE('Cell 4: status=' || v_status || ', active_count=' || v_active || ', CurrentAllocations=' || v_ca_count || ' [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 4: status=' || v_status || ', active_count=' || v_active || ', CurrentAllocations=' || v_ca_count || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 4 done: Reserve → status confirmed/reserved or cancelled

-- =============================================================================
-- Cell 4b: [SESSION B] Publish CONFIRM to unblock Cell 4
-- =============================================================================
-- Run in a SECOND SQL session while Cell 4 is blocked.

-- DECLARE
--   v_user_id NUMBER;
-- BEGIN
--   SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_Lifecycle';
--   ResourceManagement.publish_group_reservation_event(
--     p_context_identifier => 'MANUAL_Lifecycle',
--     p_user_id            => v_user_id,
--     p_category_name      => 'MANUAL_Business_Class',
--     p_action             => 'CONFIRM'
--   );
-- END;
-- /

SELECT * FROM RESERVJRNL_CAPACITY;

-- =============================================================================
-- Cell 5: Act – ConfirmReservation → Assert confirmed
-- =============================================================================

DECLARE
  v_journal_id  NUMBER;
  v_status      VARCHAR2(20);
  v_ca_count    NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_ca_count
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle';

  IF v_ca_count = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Cell 5: No current allocation (cancelled). SKIP remaining lifecycle steps or rerun Cell 4.');
    RETURN;
  END IF;

  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;

  ResourceManagement.ConfirmReservation(v_journal_id);
  COMMIT;

  SELECT ca.status INTO v_status
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  IF v_status = 'confirmed' THEN
    DBMS_OUTPUT.PUT_LINE('Cell 5: ConfirmReservation → status=confirmed [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 5: status=' || v_status || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 5 done: Confirm → assert confirmed

-- =============================================================================
-- Cell 6: Act – UnconfirmReservation → Assert reserved (inverse)
-- =============================================================================

DECLARE
  v_journal_id  NUMBER;
  v_status      VARCHAR2(20);
BEGIN
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  ResourceManagement.UnconfirmReservation(v_journal_id);
  COMMIT;

  SELECT ca.status INTO v_status
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  IF v_status = 'reserved' THEN
    DBMS_OUTPUT.PUT_LINE('Cell 6: UnconfirmReservation → status=reserved [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 6: status=' || v_status || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 6 done: Unconfirm → assert reserved

-- =============================================================================
-- Cell 7: Act – ConfirmReservation → Assert confirmed
-- =============================================================================

DECLARE
  v_journal_id  NUMBER;
  v_status      VARCHAR2(20);
BEGIN
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  ResourceManagement.ConfirmReservation(v_journal_id);
  COMMIT;

  SELECT ca.status INTO v_status
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  IF v_status = 'confirmed' THEN
    DBMS_OUTPUT.PUT_LINE('Cell 7: ConfirmReservation → status=confirmed [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 7: status=' || v_status || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 7 done: Confirm again → assert confirmed

-- =============================================================================
-- Cell 8: Act – CheckInUser → Assert checked-in
-- =============================================================================

DECLARE
  v_journal_id  NUMBER;
  v_status      VARCHAR2(20);
BEGIN
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  ResourceManagement.CheckInUser(v_journal_id);
  COMMIT;

  SELECT ca.status INTO v_status
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  IF v_status = 'checked-in' THEN
    DBMS_OUTPUT.PUT_LINE('Cell 8: CheckInUser → status=checked-in [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 8: status=' || v_status || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 8 done: CheckIn → assert checked-in

-- =============================================================================
-- Cell 9: Act – CancelCheckIn → Assert confirmed (inverse)
-- =============================================================================

DECLARE
  v_journal_id  NUMBER;
  v_status      VARCHAR2(20);
BEGIN
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  ResourceManagement.CancelCheckIn(v_journal_id);
  COMMIT;

  SELECT ca.status INTO v_status
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  IF v_status = 'confirmed' THEN
    DBMS_OUTPUT.PUT_LINE('Cell 9: CancelCheckIn → status=confirmed [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 9: status=' || v_status || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 9 done: CancelCheckIn → assert confirmed

-- =============================================================================
-- Cell 10: Act – CheckInUser → Assert checked-in
-- =============================================================================

DECLARE
  v_journal_id  NUMBER;
  v_status      VARCHAR2(20);
BEGIN
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  ResourceManagement.CheckInUser(v_journal_id);
  COMMIT;

  SELECT ca.status INTO v_status
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  IF v_status = 'checked-in' THEN
    DBMS_OUTPUT.PUT_LINE('Cell 10: CheckInUser → status=checked-in [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 10: status=' || v_status || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 10 done: CheckIn again → assert checked-in

-- =============================================================================
-- Cell 11: Act – BoardUser → Assert boarded
-- =============================================================================

DECLARE
  v_journal_id  NUMBER;
  v_status      VARCHAR2(20);
BEGIN
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  ResourceManagement.BoardUser(v_journal_id);
  COMMIT;

  SELECT ca.status INTO v_status
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  IF v_status = 'boarded' THEN
    DBMS_OUTPUT.PUT_LINE('Cell 11: BoardUser → status=boarded [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 11: status=' || v_status || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 11 done: Board → assert boarded

-- =============================================================================
-- Cell 12: Act – DeboardUser → Assert checked-in (inverse)
-- =============================================================================

DECLARE
  v_journal_id  NUMBER;
  v_status      VARCHAR2(20);
BEGIN
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  ResourceManagement.DeboardUser(v_journal_id);
  COMMIT;

  SELECT ca.status INTO v_status
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  IF v_status = 'checked-in' THEN
    DBMS_OUTPUT.PUT_LINE('Cell 12: DeboardUser → status=checked-in [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 12: status=' || v_status || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 12 done: Deboard → assert checked-in

-- =============================================================================
-- Cell 13: Act – BoardUser → Assert boarded
-- =============================================================================

DECLARE
  v_journal_id  NUMBER;
  v_status      VARCHAR2(20);
BEGIN
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  ResourceManagement.BoardUser(v_journal_id);
  COMMIT;

  SELECT ca.status INTO v_status
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  IF v_status = 'boarded' THEN
    DBMS_OUTPUT.PUT_LINE('Cell 13: BoardUser → status=boarded [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 13: status=' || v_status || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 13 done: Board again → assert boarded

-- =============================================================================
-- Cell 14: Act – ReverseJournalEntry(completed) → Assert completed, CurrentAllocations 0
-- =============================================================================
-- NOTE: ReverseJournalEntry does NOT update capacity counters per implementation.
-- So active_count may remain 1; CurrentAllocations excludes 'completed' so row disappears.

DECLARE
  v_journal_id    NUMBER;
  v_new_journal_id NUMBER;
  v_ca_count      NUMBER;
  v_latest_status VARCHAR2(20);
BEGIN
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle' AND ROWNUM = 1;
  ResourceManagement.ReverseJournalEntry(v_journal_id, 'completed', 'Manual lifecycle test', v_new_journal_id);
  COMMIT;

  SELECT COUNT(*) INTO v_ca_count
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Lifecycle';
  SELECT status INTO v_latest_status
  FROM (
    SELECT status, ROW_NUMBER() OVER (ORDER BY entry_timestamp DESC) AS rn
    FROM AllocationJournal
    WHERE context_id = (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Lifecycle')
  )
  WHERE rn = 1;

  IF v_latest_status = 'completed' AND v_ca_count = 0 THEN
    DBMS_OUTPUT.PUT_LINE('Cell 14: ReverseJournalEntry(completed) → latest=completed, CurrentAllocations=0 [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 14: latest_status=' || v_latest_status || ', CurrentAllocations=' || v_ca_count || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 14 done: ReverseJournalEntry(completed) → assert completed, CurrentAllocations 0

-- =============================================================================
-- Cell 15: Teardown
-- =============================================================================

DELETE FROM ActiveAllocation
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Lifecycle');
DELETE FROM AllocationJournal
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Lifecycle');
DELETE FROM Capacity
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Lifecycle');
DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_Lifecycle';
DELETE FROM ResourceInstance
WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Lifecycle');
DELETE FROM AssetCapacity
WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Lifecycle');
DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_Lifecycle';
DELETE FROM Users WHERE name = 'MANUAL_User_Lifecycle';
DELETE FROM ResourceCategory WHERE name = 'MANUAL_Business_Class';
COMMIT;

BEGIN
  DBMS_OUTPUT.PUT_LINE('Cell 15: Teardown complete.');
END;
/
PROMPT Cell 15 done: Teardown complete
