-- =============================================================================
-- MANUAL_Compensation_Full.sql
-- =============================================================================
-- Comprehensive manual test for the restructured compensation logic.
-- Uses a BEFORE UPDATE trigger on Capacity to force IncrementCapacityCounter
-- to fail AFTER the autonomous journal entry has been committed. Verifies
-- that CompensateJournalEntry correctly reverts the journal + ActiveAllocation
-- state while the ROLLBACK TO SAVEPOINT handles capacity.
--
-- Prerequisite: run MANUAL_Compensation_TestHook.sql once, OR let Cell 3
-- install the test hook inline.
--
-- Test groups:
--   A) MakeReservation(1) with all-capacity-fail
--      → 1 reserved journal committed, capacity fails, compensation writes
--        'cancelled'. Assert: 2 journals, active_count=0, ActiveAllocation empty.
--
--   B) MakeReservation(3) with fail-on-2nd-capacity-update
--      → 2 reserved journals committed (1st capacity OK, 2nd fails),
--        ROLLBACK TO undoes ALL capacity, compensation cancels BOTH journals.
--        Assert: 4 journals (2 reserved + 2 cancelled), active_count=0.
--        NOTE: This tests the NEW bulk compensation where ALL committed entries
--        are reverted on any failure (atomic all-or-nothing).
--
--   C) ConfirmReservation with capacity fail
--      → Setup: 1 seat reserved + committed. Then force capacity fail.
--        ConfirmReservation writes 'confirmed' journal (autonomous), capacity
--        fails, compensation should write 'reserved' to revert.
--        Assert: 3 journals (reserved, confirmed, reserved), status=reserved.
--        KNOWN ISSUE: AddAllocationJournal's INSERT branch for 'reserved' may
--        hit DUP_VAL_ON_INDEX on ActiveAllocation (row exists from original
--        reservation). If this test fails, the ActiveAllocation logic needs
--        MERGE/UPSERT for compensation scenarios.
--
--   D) CheckInUser with capacity fail
--      → Setup: 1 seat reserved + confirmed + committed. Then force fail.
--        CheckInUser writes 'checked-in' journal, capacity fails, compensation
--        writes 'confirmed' to revert. Since 'confirmed' uses the UPDATE branch
--        in ActiveAllocation, this should succeed.
--        Assert: journal chain ends with 'confirmed', ActiveAllocation correct.
--
--   E) BlockResource with capacity fail
--      → Force fail. BlockResource writes 'blocked' journal, capacity fails,
--        compensation writes 'cancelled'. 'cancelled' uses DELETE branch in
--        ActiveAllocation, so this should succeed.
--        Assert: 2 journals (blocked, cancelled), active_count=0.
--
-- Cell index:
--    0  Cleanup (optional first) + drop test hook
--    1  Reference data + RESERVJRNL_CAPACITY view
--    2  Data setup (category, user, asset, 5 instances, context)
--    3  Install test hook (package + trigger)
--    4  Assert initial state
--    5  Test A: MakeReservation(1) all-fail
--    6  Assert A
--    7  Test B: reset + MakeReservation(3) fail-on-2nd
--    8  Assert B
--    9  Setup C: reset + MakeReservation(1) succeed
--   10  Test C: ConfirmReservation with fail
--   11  Assert C
--   12  Setup D: reset + MakeReservation(1) + Confirm succeed
--   13  Test D: CheckInUser with fail
--   14  Assert D
--   15  Setup E: reset
--   16  Test E: BlockResource with fail
--   17  Assert E
--   18  Teardown
--
-- Test identifier: context_identifier = 'MANUAL_CompFull'
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_Compensation_Full – comprehensive compensation tests ===');
  DBMS_OUTPUT.PUT_LINE('Tests A-E: forced capacity failures with journal compensation.');
  DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- Cell 0: Cleanup (optional – run first) + drop test hook
-- =============================================================================

DECLARE
  v_j NUMBER; v_aa NUMBER; v_c NUMBER; v_ctx NUMBER; v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CompFull');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CompFull');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_CompFull';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name = 'MANUAL_User_CompFull';
  v_u := SQL%ROWCOUNT;
  DELETE FROM ResourceCategory WHERE name = 'MANUAL_CompFull_Class';
  v_rc := SQL%ROWCOUNT;
  COMMIT;

  BEGIN EXECUTE IMMEDIATE 'DROP TRIGGER trg_capacity_force_fail';
  EXCEPTION WHEN OTHERS THEN IF SQLCODE != -4080 THEN RAISE; END IF; END;
  BEGIN EXECUTE IMMEDIATE 'DROP PACKAGE TEST_COMPENSATION_HOOK';
  EXCEPTION WHEN OTHERS THEN IF SQLCODE != -4043 THEN RAISE; END IF; END;
  COMMIT;

  DBMS_OUTPUT.PUT_LINE('Cell 0: Cleanup done. Journal=' || v_j || ' AA=' || v_aa ||
    ' Cap=' || v_c || ' Ctx=' || v_ctx || ' Inst=' || v_ri ||
    ' AssetCap=' || v_ac || ' Asset=' || v_ra || ' User=' || v_u || ' Cat=' || v_rc);
END;
/

PROMPT Cell 0 done: Cleanup

-- =============================================================================
-- Cell 1: Reference data + RESERVJRNL_CAPACITY view
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

DECLARE
  v_obj_id NUMBER;
  v_sql    VARCHAR2(4000);
BEGIN
  SELECT object_id INTO v_obj_id
  FROM user_objects
  WHERE object_name = 'CAPACITY' AND object_type = 'TABLE';
  v_sql := 'CREATE OR REPLACE VIEW RESERVJRNL_CAPACITY AS SELECT * FROM SYS_RESERVJRNL_' || v_obj_id;
  EXECUTE IMMEDIATE v_sql;
  DBMS_OUTPUT.PUT_LINE('Created RESERVJRNL_CAPACITY for SYS_RESERVJRNL_' || v_obj_id);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Could not create RESERVJRNL_CAPACITY: ' || SQLERRM);
END;
/

PROMPT Cell 1 done: Reference data

-- =============================================================================
-- Cell 2: Data setup – category, user, asset (5 instances), context
-- =============================================================================

DECLARE
  v_count     NUMBER;
  v_asset_id  NUMBER;
  v_category_id NUMBER;
  v_cnt       NUMBER;
  v_ctx_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM ResourceCategory WHERE name = 'MANUAL_CompFull_Class';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceCategory('MANUAL_CompFull_Class', NULL, 'pool');
  END IF;

  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_CompFull';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddUser('MANUAL_User_CompFull');
  END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Asset_CompFull';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceAsset('MANUAL_Asset_CompFull', NULL, 'active');
  END IF;

  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Asset_CompFull' AND c.name = 'MANUAL_CompFull_Class';

  SELECT COUNT(*) INTO v_count FROM AssetCapacity WHERE asset_id = v_asset_id AND category_id = v_category_id;
  IF v_count = 0 THEN
    ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_category_id, 5);
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM ResourceInstance WHERE asset_id = v_asset_id;
  IF v_cnt = 0 THEN
    FOR i IN 1..5 LOOP
      ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'CF' || i, 'available');
    END LOOP;
  END IF;

  SELECT COUNT(*) INTO v_ctx_count FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull';
  IF v_ctx_count = 0 THEN
    ResourceManagement_Data.AddAllocationContext(v_asset_id, 'MANUAL_CompFull', SYSDATE + 1, SYSDATE + 2);
  END IF;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data setup complete (5 instances, capacity 5).');
END;
/

PROMPT Cell 2 done: Data setup

-- =============================================================================
-- Cell 3: Install test hook (package + trigger)
-- =============================================================================

CREATE OR REPLACE PACKAGE TEST_COMPENSATION_HOOK AS
  g_force_capacity_fail BOOLEAN := FALSE;
  g_fail_on_nth_update  NUMBER  := 0;
  g_update_count        NUMBER  := 0;
END TEST_COMPENSATION_HOOK;
/

CREATE OR REPLACE PACKAGE BODY TEST_COMPENSATION_HOOK AS
END TEST_COMPENSATION_HOOK;
/

BEGIN
  EXECUTE IMMEDIATE 'DROP TRIGGER trg_capacity_force_fail';
EXCEPTION
  WHEN OTHERS THEN IF SQLCODE != -4080 THEN RAISE; END IF;
END;
/

CREATE OR REPLACE TRIGGER trg_capacity_force_fail
  BEFORE UPDATE ON Capacity
  FOR EACH ROW
BEGIN
  IF TEST_COMPENSATION_HOOK.g_force_capacity_fail THEN
    RAISE_APPLICATION_ERROR(-20999, 'TEST_HOOK: Forced capacity failure (all)');
  END IF;
  IF TEST_COMPENSATION_HOOK.g_fail_on_nth_update > 0 THEN
    TEST_COMPENSATION_HOOK.g_update_count := TEST_COMPENSATION_HOOK.g_update_count + 1;
    IF TEST_COMPENSATION_HOOK.g_update_count >= TEST_COMPENSATION_HOOK.g_fail_on_nth_update THEN
      RAISE_APPLICATION_ERROR(-20999, 'TEST_HOOK: Forced failure on update #' || TEST_COMPENSATION_HOOK.g_update_count);
    END IF;
  END IF;
END;
/

PROMPT Cell 3 done: Test hook installed

-- =============================================================================
-- Cell 4: Assert initial state
-- =============================================================================

DECLARE
  v_cap     NUMBER;
  v_total   NUMBER;
  v_active  NUMBER;
  v_jcount  NUMBER;
  v_aacount NUMBER;
  v_ok      BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*), MAX(c.total_capacity), MAX(c.active_count)
  INTO v_cap, v_total, v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_CompFull';

  SELECT COUNT(*) INTO v_jcount
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_CompFull';

  SELECT COUNT(*) INTO v_aacount
  FROM ActiveAllocation aa
  JOIN AllocationContext ac ON aa.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_CompFull';

  IF v_cap != 1 OR v_total != 5 OR v_active != 0 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 4: cap=' || v_cap || ' total=' || v_total || ' active=' || v_active || ' [FAIL]');
  END IF;
  IF v_jcount != 0 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 4: journal_count=' || v_jcount || ' expected 0 [FAIL]');
  END IF;
  IF v_aacount != 0 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 4: active_alloc_count=' || v_aacount || ' expected 0 [FAIL]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 4: Initial state OK: cap=5, active=0, journals=0, AA=0 [PASS]');
  END IF;
END;
/

PROMPT Cell 4 done: Assert initial state

-- =============================================================================
-- Cell 5: Test A – MakeReservation(1) with force-all-capacity-fail
-- =============================================================================
-- Scenario: Every capacity UPDATE is forced to fail.
-- Expected: AddAllocationJournal commits 'reserved' (autonomous), then
-- IncrementCapacityCounter fails. Exception handler does:
--   ROLLBACK TO start_reservation (undoes capacity)
--   CompensateJournalEntry → AddAllocationJournal('cancelled') (autonomous)
-- Result: 2 journals (reserved, cancelled), capacity unchanged, AA empty.

DECLARE
  v_user_id   NUMBER;
  v_leader    NUMBER;
  v_sqlcode   NUMBER;
  v_sqlerrm   VARCHAR2(4000);
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_CompFull';

  TEST_COMPENSATION_HOOK.g_force_capacity_fail := TRUE;
  TEST_COMPENSATION_HOOK.g_fail_on_nth_update  := 0;
  TEST_COMPENSATION_HOOK.g_update_count        := 0;

  BEGIN
    -- The capacity-fail hook fires inside the reserve phase, BEFORE the AQ
    -- dequeue, so this call raises synchronously and never blocks.
    ResourceManagement.MakeReservation(
      p_context_identifier => 'MANUAL_CompFull',
      p_user_id            => v_user_id,
      p_category_name      => 'MANUAL_CompFull_Class',
      p_quantity           => 1,
      p_new_journal_id     => v_leader
    );
    DBMS_OUTPUT.PUT_LINE('Cell 5: MakeReservation(1) did NOT raise [FAIL]');
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlcode := SQLCODE;
      v_sqlerrm := SQLERRM;
      -- Diagnostic: journal count before ROLLBACK (autonomous commits are visible)
      DECLARE
        v_jcount   NUMBER;
        v_dlog_msg VARCHAR2(4000);
      BEGIN
        SELECT COUNT(*) INTO v_jcount FROM AllocationJournal aj
        JOIN AllocationContext ac ON aj.context_id = ac.id
        WHERE ac.context_identifier = 'MANUAL_CompFull';
        BEGIN
          SELECT message INTO v_dlog_msg FROM (
            SELECT message FROM DebugLog
            WHERE message LIKE '%COMPENSATION%'
            ORDER BY id DESC FETCH FIRST 1 ROW ONLY
          ) d;
        EXCEPTION WHEN NO_DATA_FOUND THEN v_dlog_msg := '(none)'; END;
        DBMS_OUTPUT.PUT_LINE('Cell 5 DEBUG: journals=' || v_jcount || ' expected=2 | last_compensation_log=' || SUBSTR(v_dlog_msg, 1, 120));
      END;
      ROLLBACK;
      IF v_sqlcode = -20999 THEN
        DBMS_OUTPUT.PUT_LINE('Cell 5: Exception -20999 (forced capacity fail) [PASS]');
      ELSE
        DBMS_OUTPUT.PUT_LINE('Cell 5: Unexpected error ' || v_sqlcode || ': ' || SUBSTR(v_sqlerrm, 1, 200) || ' [INFO]');
      END IF;
  END;

  TEST_COMPENSATION_HOOK.g_force_capacity_fail := FALSE;
END;
/

PROMPT Cell 5 done: Test A – MakeReservation(1) with forced fail

-- =============================================================================
-- Cell 6: Assert A – 2 journals (reserved + cancelled), active_count=0, AA empty
-- =============================================================================

SELECT aj.id, aj.status, aj.resource_instance_id, SUBSTR(aj.metadata, 1, 120) AS metadata_preview
FROM AllocationJournal aj
JOIN AllocationContext ac ON aj.context_id = ac.id
WHERE ac.context_identifier = 'MANUAL_CompFull'
ORDER BY aj.id;

DECLARE
  v_jcount    NUMBER;
  v_reserved  NUMBER;
  v_cancelled NUMBER;
  v_comp      NUMBER;
  v_active    NUMBER;
  v_aacount   NUMBER;
  v_ca_count  NUMBER;
  v_ok        BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_jcount FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';
  SELECT COUNT(*) INTO v_reserved FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull' AND aj.status = 'reserved';
  SELECT COUNT(*) INTO v_cancelled FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull' AND aj.status = 'cancelled';
  SELECT COUNT(*) INTO v_comp FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull'
    AND aj.metadata IS NOT NULL AND aj.metadata LIKE '%compensation_reason%';
  SELECT c.active_count INTO v_active FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';
  SELECT COUNT(*) INTO v_aacount FROM ActiveAllocation aa
  JOIN AllocationContext ac ON aa.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';
  SELECT COUNT(*) INTO v_ca_count FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';

  IF v_jcount != 2 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 6: journal_count=' || v_jcount || ' expected 2 [FAIL]'); END IF;
  IF v_reserved != 1 OR v_cancelled != 1 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 6: reserved=' || v_reserved || ' cancelled=' || v_cancelled || ' expected 1,1 [FAIL]'); END IF;
  IF v_comp != 1 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 6: compensation_reason entries=' || v_comp || ' expected 1 [FAIL]'); END IF;
  IF v_active != 0 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 6: active_count=' || v_active || ' expected 0 [FAIL]'); END IF;
  IF v_aacount != 0 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 6: ActiveAllocation rows=' || v_aacount || ' expected 0 [FAIL]'); END IF;
  IF v_ca_count != 0 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 6: CurrentAllocations=' || v_ca_count || ' expected 0 [FAIL]'); END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 6: Test A PASS – 2 journals (reserved+cancelled), active=0, AA=0, CA=0');
  END IF;
END;
/

PROMPT Cell 6 done: Assert A

-- =============================================================================
-- Cell 7: Test B – reset + MakeReservation(3) with fail-on-2nd capacity update
-- =============================================================================
-- Reset: clean journals + ActiveAllocation from Test A.
-- Scenario: 1st seat capacity succeeds, 2nd seat capacity fails.
-- NEW BEHAVIOR: ROLLBACK TO start_reservation undoes ALL capacity (both seats),
-- then CompensateJournalEntry cancels BOTH committed journals.
-- This is all-or-nothing: if any seat fails, the entire reservation is reverted.

DECLARE
  v_user_id   NUMBER;
  v_leader    NUMBER;
  v_sqlcode   NUMBER;
  v_sqlerrm   VARCHAR2(4000);
BEGIN
  -- Reset from Test A
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  COMMIT;

  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_CompFull';

  TEST_COMPENSATION_HOOK.g_force_capacity_fail := FALSE;
  TEST_COMPENSATION_HOOK.g_fail_on_nth_update  := 2;  -- fail on 2nd capacity update
  TEST_COMPENSATION_HOOK.g_update_count        := 0;

  BEGIN
    -- Hook fails on the 2nd capacity update during reservation phase, before
    -- the AQ dequeue, so this call raises synchronously and never blocks.
    ResourceManagement.MakeReservation(
      p_context_identifier => 'MANUAL_CompFull',
      p_user_id            => v_user_id,
      p_category_name      => 'MANUAL_CompFull_Class',
      p_quantity           => 3,
      p_new_journal_id     => v_leader
    );
    DBMS_OUTPUT.PUT_LINE('Cell 7: MakeReservation(3) did NOT raise [FAIL]');
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlcode := SQLCODE;
      v_sqlerrm := SQLERRM;
      ROLLBACK;
      IF v_sqlcode = -20999 THEN
        DBMS_OUTPUT.PUT_LINE('Cell 7: Exception -20999 (fail on 2nd update) [PASS]');
      ELSE
        DBMS_OUTPUT.PUT_LINE('Cell 7: Error ' || v_sqlcode || ': ' || SUBSTR(v_sqlerrm, 1, 200) || ' [INFO]');
      END IF;
  END;

  TEST_COMPENSATION_HOOK.g_fail_on_nth_update := 0;
END;
/

PROMPT Cell 7 done: Test B – MakeReservation(3) fail on 2nd

-- =============================================================================
-- Cell 8: Assert B – 4 journals (2 reserved + 2 cancelled), active_count=0
-- =============================================================================
-- Both seat 1 and seat 2 journals are compensated. Seat 3 was never created
-- because the loop broke at i=2's capacity failure.

SELECT aj.id, aj.status, aj.resource_instance_id, SUBSTR(aj.metadata, 1, 120) AS metadata_preview
FROM AllocationJournal aj
JOIN AllocationContext ac ON aj.context_id = ac.id
WHERE ac.context_identifier = 'MANUAL_CompFull'
ORDER BY aj.id;

DECLARE
  v_jcount    NUMBER;
  v_reserved  NUMBER;
  v_cancelled NUMBER;
  v_comp      NUMBER;
  v_active    NUMBER;
  v_aacount   NUMBER;
  v_ok        BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_jcount FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';
  SELECT COUNT(*) INTO v_reserved FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull' AND aj.status = 'reserved';
  SELECT COUNT(*) INTO v_cancelled FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull' AND aj.status = 'cancelled';
  SELECT COUNT(*) INTO v_comp FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull'
    AND aj.metadata IS NOT NULL AND aj.metadata LIKE '%compensation_reason%';
  SELECT c.active_count INTO v_active FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';
  SELECT COUNT(*) INTO v_aacount FROM ActiveAllocation aa
  JOIN AllocationContext ac ON aa.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';

  IF v_jcount != 4 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 8: journal_count=' || v_jcount || ' expected 4 [FAIL]'); END IF;
  IF v_reserved != 2 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 8: reserved=' || v_reserved || ' expected 2 [FAIL]'); END IF;
  IF v_cancelled != 2 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 8: cancelled=' || v_cancelled || ' expected 2 [FAIL]'); END IF;
  IF v_comp != 2 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 8: compensation entries=' || v_comp || ' expected 2 [FAIL]'); END IF;
  IF v_active != 0 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 8: active_count=' || v_active || ' expected 0 [FAIL]'); END IF;
  IF v_aacount != 0 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 8: ActiveAllocation rows=' || v_aacount || ' expected 0 [FAIL]'); END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 8: Test B PASS – 4 journals (2 reserved + 2 cancelled), active=0, AA=0');
  END IF;
END;
/

PROMPT Cell 8 done: Assert B

-- =============================================================================
-- Cell 9: Setup C – reset + ReserveByCategory(1) succeed (hook disabled)
-- =============================================================================
-- Prepares a single active allocation for the ConfirmReservation failure test.
--
-- IMPORTANT: With the new AQ-driven flow, ReserveByCategory BLOCKS on the
-- event queue until a publish_group_reservation_event arrives. To run this
-- cell, open a SECOND SQL session and run Cell 9b BEFORE / DURING this cell
-- (publish_group_reservation_event will enqueue the message; Cell 9 will
-- dequeue it and unblock).
--
-- After Cell 9 unblocks via CONFIRM, the seat journal is 'confirmed' rather
-- than 'reserved'. Test C still exercises the ConfirmReservation
-- compensation path -- on a 'confirmed' input the procedure either no-ops
-- or compensates as documented.

DECLARE
  v_user_id NUMBER;
  v_ids     SYS.ODCINUMBERLIST;
BEGIN
  -- Reset from Test B
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  UPDATE Capacity SET active_count = 0
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  COMMIT;

  TEST_COMPENSATION_HOOK.g_force_capacity_fail := FALSE;
  TEST_COMPENSATION_HOOK.g_fail_on_nth_update  := 0;
  TEST_COMPENSATION_HOOK.g_update_count        := 0;

  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_CompFull';
  ResourceManagement.ReserveByCategory(
    p_context_identifier => 'MANUAL_CompFull',
    p_category_name      => 'MANUAL_CompFull_Class',
    p_user_id            => v_user_id,
    p_quantity           => 1,
    p_timeout_minutes    => 5,
    p_new_journal_ids    => v_ids
  );

  DBMS_OUTPUT.PUT_LINE('Cell 9: Setup C done. 1 seat reserved+confirmed (journal_id=' || v_ids(1) || '), active_count=1.');
END;
/

PROMPT Cell 9 done: Setup C

-- =============================================================================
-- Cell 9b: [SESSION B] Publish CONFIRM to unblock Cell 9 / Cell 12
-- =============================================================================
-- Run in a SECOND SQL session while Cell 9 (or Cell 12) is blocked.

-- DECLARE
--   v_user_id NUMBER;
-- BEGIN
--   SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_CompFull';
--   ResourceManagement.publish_group_reservation_event(
--     p_context_identifier => 'MANUAL_CompFull',
--     p_user_id            => v_user_id,
--     p_category_name      => 'MANUAL_CompFull_Class',
--     p_action             => 'CONFIRM'
--   );
-- END;
-- /

-- =============================================================================
-- Cell 10: Test C – ConfirmReservation with force-all-capacity-fail
-- =============================================================================
-- The reservation from Cell 9 is in 'reserved' status. ConfirmReservation will:
--   1. AddAllocationJournal('confirmed') → autonomous commit (journal + UPDATE ActiveAllocation)
--   2. IncrementCapacityCounter(delta=0) → trigger fires → RAISES
--   3. Exception handler: ROLLBACK TO before_confirm, CompensateJournalEntry('reserved')
--
-- KNOWN ISSUE: CompensateJournalEntry calls AddAllocationJournal('reserved').
-- The 'reserved' status maps to the INSERT branch in ActiveAllocation logic.
-- Since the row already exists (from the original reservation), this INSERT
-- will hit DUP_VAL_ON_INDEX. CompensateJournalEntry silently catches the error.
-- If this happens, the journal will show 'confirmed' as latest status with no
-- compensation entry. This is a bug to fix in AddAllocationJournal.

DECLARE
  v_journal_id NUMBER;
  v_sqlcode    NUMBER;
  v_sqlerrm    VARCHAR2(4000);
BEGIN
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_CompFull' AND ROWNUM = 1;

  TEST_COMPENSATION_HOOK.g_force_capacity_fail := TRUE;

  BEGIN
    ResourceManagement.ConfirmReservation(v_journal_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Cell 10: ConfirmReservation did NOT raise [FAIL]');
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlcode := SQLCODE;
      v_sqlerrm := SQLERRM;
      ROLLBACK;
      DBMS_OUTPUT.PUT_LINE('Cell 10: Exception ' || v_sqlcode || ': ' || SUBSTR(v_sqlerrm, 1, 200));
      IF v_sqlcode = -20999 THEN
        DBMS_OUTPUT.PUT_LINE('Cell 10: Correct exception raised [PASS]');
      END IF;
  END;

  TEST_COMPENSATION_HOOK.g_force_capacity_fail := FALSE;
END;
/

PROMPT Cell 10 done: Test C – ConfirmReservation with forced fail

-- =============================================================================
-- Cell 11: Assert C – journal chain + ActiveAllocation consistency
-- =============================================================================
-- EXPECTED (if compensation succeeds):
--   3 journals: reserved, confirmed, reserved (compensation)
--   CurrentAllocations latest status = reserved
--   active_count = 1 (unchanged: confirm uses delta=0, rollback undoes it)
--   ActiveAllocation.journal_id = compensation journal id
--
-- EXPECTED (if compensation fails due to ActiveAllocation DUP_VAL_ON_INDEX bug):
--   2 journals: reserved, confirmed (compensation entry was NOT created)
--   CurrentAllocations latest status = confirmed
--   active_count = 1 (unchanged)
--   ActiveAllocation.journal_id = confirmed journal id (updated by the autonomous tx)
--
-- Both outcomes are documented. The assert checks for the correct behavior.
-- If it fails, the FAIL messages indicate the ActiveAllocation bug.

SELECT aj.id, aj.status, aj.resource_instance_id, SUBSTR(aj.metadata, 1, 120) AS metadata_preview
FROM AllocationJournal aj
JOIN AllocationContext ac ON aj.context_id = ac.id
WHERE ac.context_identifier = 'MANUAL_CompFull'
ORDER BY aj.id;

SELECT aa.context_id, aa.resource_instance_id, aa.journal_id
FROM ActiveAllocation aa
JOIN AllocationContext ac ON aa.context_id = ac.id
WHERE ac.context_identifier = 'MANUAL_CompFull';

DECLARE
  v_jcount       NUMBER;
  v_latest_status VARCHAR2(20);
  v_active       NUMBER;
  v_aacount      NUMBER;
  v_comp         NUMBER;
  v_ok           BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_jcount FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';
  SELECT COUNT(*) INTO v_comp FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull'
    AND aj.metadata IS NOT NULL AND aj.metadata LIKE '%compensation_reason%';
  SELECT ca.status INTO v_latest_status FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_CompFull' AND ROWNUM = 1;
  SELECT c.active_count INTO v_active FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';
  SELECT COUNT(*) INTO v_aacount FROM ActiveAllocation aa
  JOIN AllocationContext ac ON aa.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';

  IF v_jcount != 3 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 11: journal_count=' || v_jcount || ' expected 3 [FAIL]');
    DBMS_OUTPUT.PUT_LINE('  → If 2: compensation entry was NOT created (ActiveAllocation DUP_VAL_ON_INDEX bug)');
  END IF;
  IF v_comp != 1 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 11: compensation entries=' || v_comp || ' expected 1 [FAIL]');
  END IF;
  IF v_latest_status != 'reserved' THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 11: latest_status=' || v_latest_status || ' expected reserved [FAIL]');
    DBMS_OUTPUT.PUT_LINE('  → If confirmed: compensation did not revert status (bug)');
  END IF;
  IF v_active != 1 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 11: active_count=' || v_active || ' expected 1 [FAIL]'); END IF;
  IF v_aacount != 1 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 11: ActiveAllocation rows=' || v_aacount || ' expected 1 [FAIL]'); END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 11: Test C PASS – confirm reverted to reserved, active=1, AA=1');
  END IF;
END;
/

PROMPT Cell 11 done: Assert C

-- =============================================================================
-- Cell 12: Setup D – reset + MakeReservation(1) + ConfirmReservation (succeed)
-- =============================================================================
-- Prepares a confirmed reservation for the CheckInUser failure test.

DECLARE
  v_user_id    NUMBER;
  v_ids        SYS.ODCINUMBERLIST;
BEGIN
  -- Reset from Test C
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  UPDATE Capacity SET active_count = 0
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  COMMIT;

  TEST_COMPENSATION_HOOK.g_force_capacity_fail := FALSE;
  TEST_COMPENSATION_HOOK.g_fail_on_nth_update  := 0;
  TEST_COMPENSATION_HOOK.g_update_count        := 0;

  -- ReserveByCategory blocks until Cell 9b publishes CONFIRM in Session B,
  -- which transitions the seat all the way to 'confirmed' inside the proc.
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_CompFull';
  ResourceManagement.ReserveByCategory(
    p_context_identifier => 'MANUAL_CompFull',
    p_category_name      => 'MANUAL_CompFull_Class',
    p_user_id            => v_user_id,
    p_quantity           => 1,
    p_timeout_minutes    => 5,
    p_new_journal_ids    => v_ids
  );

  DBMS_OUTPUT.PUT_LINE('Cell 12: Setup D done. 1 seat confirmed, active_count=1.');
END;
/

PROMPT Cell 12 done: Setup D

-- =============================================================================
-- Cell 13: Test D – CheckInUser with force-all-capacity-fail
-- =============================================================================
-- The reservation is in 'confirmed' status. CheckInUser will:
--   1. AddAllocationJournal('checked-in') → autonomous commit + UPDATE ActiveAllocation
--   2. IncrementCapacityCounter(delta=0) → RAISES
--   3. ROLLBACK TO before_checkin, CompensateJournalEntry('confirmed')
--
-- Since 'confirmed' maps to the UPDATE branch in ActiveAllocation (not initial),
-- the compensation should succeed: journal reverts to 'confirmed', AA updated.

DECLARE
  v_journal_id NUMBER;
  v_sqlcode    NUMBER;
  v_sqlerrm    VARCHAR2(4000);
BEGIN
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_CompFull' AND ROWNUM = 1;

  TEST_COMPENSATION_HOOK.g_force_capacity_fail := TRUE;

  BEGIN
    ResourceManagement.CheckInUser(v_journal_id);
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Cell 13: CheckInUser did NOT raise [FAIL]');
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlcode := SQLCODE;
      v_sqlerrm := SQLERRM;
      ROLLBACK;
      IF v_sqlcode = -20999 THEN
        DBMS_OUTPUT.PUT_LINE('Cell 13: Exception -20999 (forced capacity fail) [PASS]');
      ELSE
        DBMS_OUTPUT.PUT_LINE('Cell 13: Error ' || v_sqlcode || ': ' || SUBSTR(v_sqlerrm, 1, 200) || ' [INFO]');
      END IF;
  END;

  TEST_COMPENSATION_HOOK.g_force_capacity_fail := FALSE;
END;
/

PROMPT Cell 13 done: Test D – CheckInUser with forced fail

-- =============================================================================
-- Cell 14: Assert D – journal reverts to confirmed, ActiveAllocation correct
-- =============================================================================
-- Expected: 4 journals (reserved, confirmed, checked-in, confirmed-compensation)
-- Latest status = confirmed, active_count = 1, AA = 1 row

SELECT aj.id, aj.status, aj.resource_instance_id, SUBSTR(aj.metadata, 1, 120) AS metadata_preview
FROM AllocationJournal aj
JOIN AllocationContext ac ON aj.context_id = ac.id
WHERE ac.context_identifier = 'MANUAL_CompFull'
ORDER BY aj.id;

DECLARE
  v_jcount       NUMBER;
  v_latest_status VARCHAR2(20);
  v_active       NUMBER;
  v_aacount      NUMBER;
  v_comp         NUMBER;
  v_ok           BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_jcount FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';
  SELECT COUNT(*) INTO v_comp FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull'
    AND aj.metadata IS NOT NULL AND aj.metadata LIKE '%compensation_reason%';
  SELECT ca.status INTO v_latest_status FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_CompFull' AND ROWNUM = 1;
  SELECT c.active_count INTO v_active FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';
  SELECT COUNT(*) INTO v_aacount FROM ActiveAllocation aa
  JOIN AllocationContext ac ON aa.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';

  IF v_jcount != 4 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 14: journal_count=' || v_jcount || ' expected 4 [FAIL]'); END IF;
  IF v_comp != 1 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 14: compensation entries=' || v_comp || ' expected 1 [FAIL]'); END IF;
  IF v_latest_status != 'confirmed' THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 14: latest_status=' || v_latest_status || ' expected confirmed [FAIL]'); END IF;
  IF v_active != 1 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 14: active_count=' || v_active || ' expected 1 [FAIL]'); END IF;
  IF v_aacount != 1 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 14: ActiveAllocation rows=' || v_aacount || ' expected 1 [FAIL]'); END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 14: Test D PASS – checked-in reverted to confirmed, active=1, AA=1');
  END IF;
END;
/

PROMPT Cell 14 done: Assert D

-- =============================================================================
-- Cell 15: Setup E – reset for BlockResource test
-- =============================================================================

BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  UPDATE Capacity SET active_count = 0
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  COMMIT;

  TEST_COMPENSATION_HOOK.g_force_capacity_fail := FALSE;
  TEST_COMPENSATION_HOOK.g_fail_on_nth_update  := 0;
  TEST_COMPENSATION_HOOK.g_update_count        := 0;

  DBMS_OUTPUT.PUT_LINE('Cell 15: Reset done for Test E.');
END;
/

PROMPT Cell 15 done: Setup E

-- =============================================================================
-- Cell 16: Test E – BlockResource with force-all-capacity-fail
-- =============================================================================
-- BlockResource creates a 'blocked' journal entry (autonomous), then capacity
-- update fails. Compensation writes 'cancelled' (terminal → DELETE from AA).
-- Since 'cancelled' deletes the ActiveAllocation row, compensation succeeds.

DECLARE
  v_instance_id  NUMBER;
  v_journal_id   NUMBER;
  v_sqlcode      NUMBER;
  v_sqlerrm      VARCHAR2(4000);
BEGIN
  SELECT ri.id INTO v_instance_id
  FROM ResourceInstance ri
  JOIN ResourceAsset ra ON ri.asset_id = ra.id
  WHERE ra.name = 'MANUAL_Asset_CompFull' AND ROWNUM = 1;

  TEST_COMPENSATION_HOOK.g_force_capacity_fail := TRUE;

  BEGIN
    ResourceManagement.BlockResource(
      p_context_identifier   => 'MANUAL_CompFull',
      p_resource_instance_id => v_instance_id,
      p_reason               => 'Test E: forced block failure',
      p_metadata             => NULL,
      p_new_journal_id       => v_journal_id
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Cell 16: BlockResource did NOT raise [FAIL]');
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlcode := SQLCODE;
      v_sqlerrm := SQLERRM;
      ROLLBACK;
      IF v_sqlcode = -20999 THEN
        DBMS_OUTPUT.PUT_LINE('Cell 16: Exception -20999 (forced capacity fail) [PASS]');
      ELSE
        DBMS_OUTPUT.PUT_LINE('Cell 16: Error ' || v_sqlcode || ': ' || SUBSTR(v_sqlerrm, 1, 200) || ' [INFO]');
      END IF;
  END;

  TEST_COMPENSATION_HOOK.g_force_capacity_fail := FALSE;
END;
/

PROMPT Cell 16 done: Test E – BlockResource with forced fail

-- =============================================================================
-- Cell 17: Assert E – 2 journals (blocked + cancelled), active_count=0, AA=0
-- =============================================================================

SELECT aj.id, aj.status, aj.resource_instance_id, SUBSTR(aj.metadata, 1, 120) AS metadata_preview
FROM AllocationJournal aj
JOIN AllocationContext ac ON aj.context_id = ac.id
WHERE ac.context_identifier = 'MANUAL_CompFull'
ORDER BY aj.id;

DECLARE
  v_jcount    NUMBER;
  v_blocked   NUMBER;
  v_cancelled NUMBER;
  v_comp      NUMBER;
  v_active    NUMBER;
  v_aacount   NUMBER;
  v_ok        BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_jcount FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';
  SELECT COUNT(*) INTO v_blocked FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull' AND aj.status = 'blocked';
  SELECT COUNT(*) INTO v_cancelled FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull' AND aj.status = 'cancelled';
  SELECT COUNT(*) INTO v_comp FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull'
    AND aj.metadata IS NOT NULL AND aj.metadata LIKE '%compensation_reason%';
  SELECT c.active_count INTO v_active FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';
  SELECT COUNT(*) INTO v_aacount FROM ActiveAllocation aa
  JOIN AllocationContext ac ON aa.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_CompFull';

  IF v_jcount != 2 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 17: journal_count=' || v_jcount || ' expected 2 [FAIL]'); END IF;
  IF v_blocked != 1 OR v_cancelled != 1 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 17: blocked=' || v_blocked || ' cancelled=' || v_cancelled || ' expected 1,1 [FAIL]'); END IF;
  IF v_comp != 1 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 17: compensation entries=' || v_comp || ' expected 1 [FAIL]'); END IF;
  IF v_active != 0 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 17: active_count=' || v_active || ' expected 0 [FAIL]'); END IF;
  IF v_aacount != 0 THEN v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 17: ActiveAllocation rows=' || v_aacount || ' expected 0 [FAIL]'); END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 17: Test E PASS – blocked + cancelled, active=0, AA=0');
  END IF;
END;
/

PROMPT Cell 17 done: Assert E

-- =============================================================================
-- Cell 18: Teardown – drop trigger/package, delete all test data
-- =============================================================================

DECLARE
  v_j NUMBER; v_aa NUMBER; v_c NUMBER; v_ctx NUMBER; v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_CompFull';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CompFull');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_CompFull');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_CompFull';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name = 'MANUAL_User_CompFull';
  v_u := SQL%ROWCOUNT;
  DELETE FROM ResourceCategory WHERE name = 'MANUAL_CompFull_Class';
  v_rc := SQL%ROWCOUNT;
  COMMIT;

  BEGIN EXECUTE IMMEDIATE 'DROP TRIGGER trg_capacity_force_fail';
  EXCEPTION WHEN OTHERS THEN IF SQLCODE != -4080 THEN RAISE; END IF; END;
  BEGIN EXECUTE IMMEDIATE 'DROP PACKAGE TEST_COMPENSATION_HOOK';
  EXCEPTION WHEN OTHERS THEN IF SQLCODE != -4043 THEN RAISE; END IF; END;
  COMMIT;

  DBMS_OUTPUT.PUT_LINE('Cell 18: Teardown complete. Journal=' || v_j || ' AA=' || v_aa ||
    ' Cap=' || v_c || ' Ctx=' || v_ctx || ' Inst=' || v_ri ||
    ' AssetCap=' || v_ac || ' Asset=' || v_ra || ' User=' || v_u || ' Cat=' || v_rc);
END;
/

PROMPT Cell 18 done: Teardown
PROMPT
PROMPT =============================================================================
PROMPT   MANUAL_Compensation_Full complete.
PROMPT   Tests A,B: MakeReservation compensation (single + bulk)
PROMPT   Test C:    ConfirmReservation transition compensation (known edge case)
PROMPT   Test D:    CheckInUser transition compensation
PROMPT   Test E:    BlockResource compensation
PROMPT =============================================================================
