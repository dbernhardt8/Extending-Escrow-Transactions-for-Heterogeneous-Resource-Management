-- =============================================================================
-- MANUAL_Concurrent_ActiveAllocation.sql
-- =============================================================================
-- Multi-session manual test for ActiveAllocation consistency guards.
--
-- WHAT THIS TESTS:
-- AddAllocationJournal now validates SQL%ROWCOUNT after UPDATE and DELETE
-- on ActiveAllocation. This prevents:
--   -20911: Status transition (confirm/checkin/board) when the allocation
--           was concurrently cancelled (UPDATE affected 0 rows)
--   -20912: Double-cancel or double-complete (DELETE affected 0 rows)
--
-- These guards ensure that AllocationJournal and ActiveAllocation stay
-- consistent even under concurrent modifications. Without them:
--   - A concurrent cancel+confirm race could leave an "orphaned" journal
--     entry (visible in CurrentAllocations but not tracked in ActiveAllocation)
--   - A double-cancel could produce two cancellation journal entries and
--     decrement capacity twice
--
-- TESTS:
--   Test 1: Concurrent Confirm + Cancel (same reservation)
--           → Demonstrates -20911 when cancel wins the race
--   Test 2: Concurrent Double-Cancel (same reservation)
--           → Demonstrates -20912 when second cancel finds row gone
--   Test 3: Concurrent Confirm + Confirm (same reservation)
--           → Documents TOCTOU window (harmless but documented)
--
-- PREREQUISITES:
-- 1. Two SQL sessions connected to the same database schema
-- 2. Reference data loaded (ResourceStatus, ResourceInstanceStatus)
-- 3. Packages compiled with the row-count validation in AddAllocationJournal
-- 4. DO NOT have any uncommitted transactions in either session
--
-- 5. PACKAGE COMMITS: The procedures used in the session blocks
--    (ConfirmReservation, CancelReservation) must NOT commit the calling
--    session's transaction. If your build commits in those procedures
--    (2.2_database_body.pkb), comment out or remove those COMMITs before
--    running this test so you can commit manually in each terminal.
--    Restore the package after testing.
--
-- NOTATION:
-- [SETUP]      = Run in either session (only one person runs it)
-- [SESSION 1]  = Run in session 1 only
-- [SESSION 2]  = Run in session 2 only
-- [ASSERT]     = Run in either session to verify results
-- [CLEANUP]    = Run in either session
--
-- COMMIT CONTROL (correct handling of separate sessions):
-- -------------------------------------------------------
-- The test blocks that run in Session 1 / Session 2 do NOT contain COMMIT.
-- You must issue COMMIT manually in each terminal when you want that
-- session's transaction to commit.
--
-- The package must not commit the calling session (see PREREQUISITES).
--
-- Why: To observe correct cross-session behavior (blocking, conflicts,
-- -20911/-20912), each session's transaction must be committed only when
-- you choose. For example:
--   1. Run the Session 1 block in terminal 1 (no commit yet).
--   2. Run the Session 2 block in terminal 2 (no commit yet).
--   3. In terminal 1: COMMIT;   -- Session 1's changes become visible.
--   4. In terminal 2: COMMIT;   -- or Session 2 may get -20911/-20912 on commit path.
-- You can also commit in the opposite order, or commit one and rollback the
-- other, to explore different race outcomes.
--
-- Setup steps (Step 0, Step 1, per-test "Create a reservation" blocks) and
-- TEARDOWN keep their COMMIT so that shared state is visible to both sessions.
--
-- IMPORTANT: Follow the steps IN ORDER. The timing matters.
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

-- =============================================================================
-- STEP 0: [SETUP] Cleanup any previous test data
-- =============================================================================

DECLARE
  v_j NUMBER; v_aa NUMBER; v_c NUMBER; v_ctx NUMBER;
  v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'AA_Asset');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'AA_Asset');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'AA_Asset';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name IN ('AA_User1');
  v_u := SQL%ROWCOUNT;
  DELETE FROM ResourceCategory WHERE name = 'AA_Class';
  v_rc := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 0: Cleanup. J=' || v_j || ' AA=' || v_aa || ' Cap=' || v_c ||
    ' Ctx=' || v_ctx || ' RI=' || v_ri || ' AC=' || v_ac || ' RA=' || v_ra ||
    ' U=' || v_u || ' RC=' || v_rc);
END;
/

-- =============================================================================
-- STEP 1: [SETUP] Create test data
-- =============================================================================
-- Asset with 1 instance. Each test creates a reservation, then two sessions
-- race to modify it.

DECLARE
  v_asset_id    NUMBER;
  v_category_id NUMBER;
BEGIN
  -- Reference data (idempotent)
  BEGIN ResourceManagement_Data.AddResourceStatus('reserved', 'Held');
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('confirmed', 'Confirmed');
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('cancelled', 'Cancelled');
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceInstanceStatus('available', 'Available');
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;

  ResourceManagement_Data.AddResourceCategory('AA_Class', NULL, 'pool');
  ResourceManagement_Data.AddUser('AA_User1');
  ResourceManagement_Data.AddResourceAsset('AA_Asset', NULL, 'active');

  SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'AA_Asset';
  SELECT id INTO v_category_id FROM ResourceCategory WHERE name = 'AA_Class';

  ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_category_id, 1);
  ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'AA1', 'available');
  ResourceManagement_Data.AddAllocationContext(v_asset_id, 'AA_CONCUR_Test', SYSDATE + 1, SYSDATE + 2);
  COMMIT;

  DBMS_OUTPUT.PUT_LINE('Step 1: Setup complete. Asset=' || v_asset_id ||
    ', Category=' || v_category_id || ', 1 instance (AA1), capacity=1.');
END;
/


-- =============================================================================
-- =============================================================================
-- TEST 1: Concurrent Confirm + Cancel
-- =============================================================================
-- =============================================================================
--
-- GOAL: Verify that when one session confirms and another cancels the same
-- reservation concurrently, the system remains consistent.
--
-- EXPECTED OUTCOMES (timing-dependent):
--
-- Outcome A - Cancel's autonomous tx commits first:
--   Cancel: DELETEs ActiveAllocation row, commits journal 'cancelled'
--   Confirm: UPDATEs ActiveAllocation → 0 rows → -20911, journal ROLLED BACK
--   Result: reserved → cancelled. Confirm session gets error -20911.
--           ActiveAllocation: empty. Capacity: 0. Consistent.
--
-- Outcome B - Confirm's autonomous tx commits first:
--   Confirm: UPDATEs ActiveAllocation row, commits journal 'confirmed'
--   Cancel: reads CurrentAllocations (sees 'confirmed'), DELETEs AA row
--   Result: reserved → confirmed → cancelled. Both sessions succeed.
--           ActiveAllocation: empty. Capacity: 0. Consistent.
--
-- In BOTH outcomes the final state is consistent:
--   CurrentAllocations = 0, ActiveAllocation = 0, capacity active_count = 0
--
-- =============================================================================

PROMPT
PROMPT =========================================================================
PROMPT   TEST 1: Concurrent Confirm + Cancel
PROMPT =========================================================================
PROMPT

-- [SETUP] Create a reservation to operate on
-- The MakeReservation call BLOCKS on RESERVATION_EVENTS_Q. From a SECOND
-- session run AA_PUBLISH_CONFIRM (below) to unblock; the seat returns
-- already 'confirmed'. After Test 1 runs, swap status with UnconfirmReservation
-- if a 'reserved' precondition is required.

-- AA_PUBLISH_CONFIRM (run from Session B as needed):
--   DECLARE
--     v_user_id NUMBER;
--   BEGIN
--     SELECT id INTO v_user_id FROM Users WHERE name = 'AA_User1';
--     ResourceManagement.publish_group_reservation_event(
--       p_context_identifier => 'AA_CONCUR_Test',
--       p_user_id            => v_user_id,
--       p_category_name      => 'AA_Class',
--       p_action             => 'CONFIRM'
--     );
--   END;
--   /

DECLARE
  v_user_id NUMBER;
  v_leader  NUMBER;
BEGIN
  -- Reset from any previous test run
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  UPDATE Capacity SET active_count = 0
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  COMMIT;

  SELECT id INTO v_user_id FROM Users WHERE name = 'AA_User1';

  ResourceManagement.MakeReservation(
    p_context_identifier => 'AA_CONCUR_Test',
    p_user_id            => v_user_id,
    p_category_name      => 'AA_Class',
    p_quantity           => 1,
    p_new_journal_id     => v_leader
  );
  DBMS_OUTPUT.PUT_LINE('Test 1 setup: Reserved+confirmed seat. group_leader_journal_id = ' || NVL(TO_CHAR(v_leader), 'NULL'));
END;
/

-- Verify setup
SELECT aj.id AS journal_id, aj.status, ri.instance_identifier
FROM AllocationJournal aj
JOIN AllocationContext ac ON aj.context_id = ac.id
LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
WHERE ac.context_identifier = 'AA_CONCUR_Test'
ORDER BY aj.id;

PROMPT
PROMPT   INSTRUCTIONS:
PROMPT   -----------------------------------------------------------------------
PROMPT   1. Note the journal_id from the query above.
PROMPT   2. Prepare the SESSION 1 block (Confirm) in one session.
PROMPT   3. Prepare the SESSION 2 block (Cancel) in another session.
PROMPT   4. Run BOTH at the same time (within 1-2 seconds of each other).
PROMPT   5. After both complete, run the ASSERT below.
PROMPT   -----------------------------------------------------------------------
PROMPT

-- =============================================================================
-- TEST 1: [SESSION 1] - Confirm (paste in Session 1, run simultaneously)
-- =============================================================================
DECLARE
  v_journal_id NUMBER;
BEGIN
  -- Find the active reservation
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'AA_CONCUR_Test'
    AND ca.status = 'reserved';

  DBMS_OUTPUT.PUT_LINE('Test 1 Session 1: Confirming journal ' || v_journal_id || '...');

  ResourceManagement.ConfirmReservation(v_journal_id);
  -- COMMIT manually in this terminal when you want Session 1's tx to commit.
  DBMS_OUTPUT.PUT_LINE('Test 1 Session 1: SUCCESS - confirmed journal ' || v_journal_id);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('Test 1 Session 1: FAILED - ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('  (If -20911: cancel won the race - this is correct behavior)');
END;
/

-- =============================================================================
-- TEST 1: [SESSION 2] - Cancel (paste in Session 2, run simultaneously)
-- =============================================================================
DECLARE
  v_journal_id NUMBER;
BEGIN
  -- Find the active reservation
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'AA_CONCUR_Test'
    AND ca.status IN ('reserved', 'confirmed');

  DBMS_OUTPUT.PUT_LINE('Test 1 Session 2: Cancelling journal ' || v_journal_id || '...');

  ResourceManagement.CancelReservation(v_journal_id);
  -- COMMIT manually in this terminal when you want Session 2's tx to commit.
  DBMS_OUTPUT.PUT_LINE('Test 1 Session 2: SUCCESS - cancelled journal ' || v_journal_id);
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('Test 1 Session 2: FAILED - ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('  (If -20912: confirm+cancel race, cancel was too late)');
END;
/

-- =============================================================================
-- TEST 1: [ASSERT] - Run after both sessions complete
-- =============================================================================

PROMPT --- AllocationJournal entries ---
SELECT aj.id, aj.status, ri.instance_identifier,
       SUBSTR(aj.metadata, 1, 80) AS meta
FROM AllocationJournal aj
JOIN AllocationContext ac ON aj.context_id = ac.id
LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
WHERE ac.context_identifier = 'AA_CONCUR_Test'
ORDER BY aj.id;

PROMPT --- ActiveAllocation ---
SELECT aa.context_id, aa.resource_instance_id, aa.journal_id
FROM ActiveAllocation aa
JOIN AllocationContext ac ON aa.context_id = ac.id
WHERE ac.context_identifier = 'AA_CONCUR_Test';

PROMPT --- Capacity ---
SELECT c.total_capacity, c.active_count
FROM Capacity c JOIN AllocationContext ac ON c.context_id = ac.id
WHERE ac.context_identifier = 'AA_CONCUR_Test';

PROMPT --- CurrentAllocations ---
SELECT ca.journal_id, ca.status, ca.resource_instance_id
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
WHERE ac.context_identifier = 'AA_CONCUR_Test';

DECLARE
  v_jcount     NUMBER;
  v_reserved   NUMBER;
  v_confirmed  NUMBER;
  v_cancelled  NUMBER;
  v_aacount    NUMBER;
  v_ca_count   NUMBER;
  v_active     NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_jcount FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test';
  SELECT COUNT(*) INTO v_reserved FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test' AND aj.status = 'reserved';
  SELECT COUNT(*) INTO v_confirmed FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test' AND aj.status = 'confirmed';
  SELECT COUNT(*) INTO v_cancelled FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test' AND aj.status = 'cancelled';
  SELECT COUNT(*) INTO v_aacount FROM ActiveAllocation aa
  JOIN AllocationContext ac ON aa.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test';
  SELECT COUNT(*) INTO v_ca_count FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test';
  SELECT c.active_count INTO v_active FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test';

  DBMS_OUTPUT.PUT_LINE('=== Test 1 Assert: Concurrent Confirm + Cancel ===');
  DBMS_OUTPUT.PUT_LINE('  Journals : ' || v_jcount || ' (reserved=' || v_reserved ||
    ', confirmed=' || v_confirmed || ', cancelled=' || v_cancelled || ')');
  DBMS_OUTPUT.PUT_LINE('  ActiveAllocation: ' || v_aacount);
  DBMS_OUTPUT.PUT_LINE('  CurrentAlloc    : ' || v_ca_count);
  DBMS_OUTPUT.PUT_LINE('  Capacity active : ' || v_active);
  DBMS_OUTPUT.PUT_LINE('');

  -- CONSISTENCY CHECK: regardless of who won the race
  IF v_aacount = 0 AND v_ca_count = 0 AND v_active = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  CONSISTENCY CHECK: AA=0, CA=0, active=0 [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  CONSISTENCY CHECK: [FAIL] - state is inconsistent!');
    DBMS_OUTPUT.PUT_LINE('    Expected: AA=0, CA=0, active=0');
  END IF;

  IF v_cancelled = 1 AND v_reserved = 1 THEN
    IF v_confirmed = 0 THEN
      DBMS_OUTPUT.PUT_LINE('  OUTCOME A: Cancel won. Confirm got -20911. (reserved->cancelled)');
    ELSIF v_confirmed = 1 THEN
      DBMS_OUTPUT.PUT_LINE('  OUTCOME B: Confirm won first, then cancel. (reserved->confirmed->cancelled)');
    END IF;
  ELSE
    DBMS_OUTPUT.PUT_LINE('  UNEXPECTED journal counts. Check raw data above.');
  END IF;
END;
/

PROMPT --- DebugLog (relevant entries) ---
SELECT id, SUBSTR(message, 1, 120) AS message
FROM DebugLog
WHERE message LIKE '%confirm%' OR message LIKE '%cancel%' OR message LIKE '%20911%'
ORDER BY id DESC
FETCH FIRST 10 ROWS ONLY;


-- =============================================================================
-- =============================================================================
-- TEST 2: Concurrent Double-Cancel
-- =============================================================================
-- =============================================================================
--
-- GOAL: Verify that when two sessions try to cancel the same reservation
-- concurrently, only one succeeds and only one capacity decrement occurs.
--
-- EXPECTED OUTCOMES (timing-dependent):
--
-- Outcome A - Session 1's autonomous tx commits first:
--   Session 1: DELETEs ActiveAllocation, commits 'cancelled' journal
--   Session 2: DELETEs ActiveAllocation → 0 rows → -20912, journal ROLLED BACK
--   Result: reserved → cancelled (1 cancel entry only). Session 2 gets -20912.
--
-- Outcome B - Session 2 reads CurrentAllocations AFTER Session 1's autonomous commit:
--   Session 1 committed: 'cancelled' journal + AA deleted
--   Session 2: SELECT from CurrentAllocations → NO_DATA_FOUND → -20003
--   Result: reserved → cancelled (1 cancel entry only). Session 2 gets -20003.
--
-- In BOTH outcomes:
--   Journal has exactly 2 entries (1 reserved, 1 cancelled)
--   ActiveAllocation = 0, CurrentAllocations = 0, capacity active_count = 0
--   Capacity was decremented exactly once.
--
-- =============================================================================

PROMPT
PROMPT =========================================================================
PROMPT   TEST 2: Concurrent Double-Cancel
PROMPT =========================================================================
PROMPT

-- [SETUP] Create a reservation to operate on
-- BLOCKS on RESERVATION_EVENTS_Q. From a SECOND session run AA_PUBLISH_CONFIRM
-- (defined above Test 1) to unblock. The seat returns already 'confirmed'.

DECLARE
  v_user_id NUMBER;
  v_leader  NUMBER;
BEGIN
  -- Reset
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  UPDATE Capacity SET active_count = 0
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  COMMIT;

  SELECT id INTO v_user_id FROM Users WHERE name = 'AA_User1';

  ResourceManagement.MakeReservation(
    p_context_identifier => 'AA_CONCUR_Test',
    p_user_id            => v_user_id,
    p_category_name      => 'AA_Class',
    p_quantity           => 1,
    p_new_journal_id     => v_leader
  );
  DBMS_OUTPUT.PUT_LINE('Test 2 setup: Reserved+confirmed seat. group_leader_journal_id = ' || NVL(TO_CHAR(v_leader), 'NULL'));
END;
/

PROMPT
PROMPT   INSTRUCTIONS:
PROMPT   -----------------------------------------------------------------------
PROMPT   1. Paste the SAME block below into BOTH sessions.
PROMPT   2. Run BOTH at the same time (within 1-2 seconds of each other).
PROMPT   3. After both complete, run the ASSERT below.
PROMPT   -----------------------------------------------------------------------
PROMPT

-- =============================================================================
-- TEST 2: [SESSION 1] and [SESSION 2] - Cancel (paste in BOTH, run simultaneously)
-- =============================================================================
DECLARE
  v_journal_id NUMBER;
BEGIN
  -- Find the active reservation
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'AA_CONCUR_Test'
    AND ca.status = 'reserved';

  DBMS_OUTPUT.PUT_LINE('Test 2: Cancelling journal ' || v_journal_id || '...');

  ResourceManagement.CancelReservation(v_journal_id);
  -- COMMIT manually in this terminal when you want this session's tx to commit.
  DBMS_OUTPUT.PUT_LINE('Test 2: SUCCESS - cancelled journal ' || v_journal_id);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('Test 2: EXPECTED - reservation already gone (NO_DATA_FOUND)');
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('Test 2: EXPECTED FAILURE - ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('  (If -20912: the other session cancelled first - correct)');
    DBMS_OUTPUT.PUT_LINE('  (If -20003: reservation not found in CurrentAllocations - correct)');
END;
/

-- =============================================================================
-- TEST 2: [ASSERT] - Run after both sessions complete
-- =============================================================================

PROMPT --- AllocationJournal entries ---
SELECT aj.id, aj.status, ri.instance_identifier
FROM AllocationJournal aj
JOIN AllocationContext ac ON aj.context_id = ac.id
LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
WHERE ac.context_identifier = 'AA_CONCUR_Test'
ORDER BY aj.id;

DECLARE
  v_jcount    NUMBER;
  v_reserved  NUMBER;
  v_cancelled NUMBER;
  v_aacount   NUMBER;
  v_ca_count  NUMBER;
  v_active    NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_jcount FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test';
  SELECT COUNT(*) INTO v_reserved FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test' AND aj.status = 'reserved';
  SELECT COUNT(*) INTO v_cancelled FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test' AND aj.status = 'cancelled';
  SELECT COUNT(*) INTO v_aacount FROM ActiveAllocation aa
  JOIN AllocationContext ac ON aa.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test';
  SELECT COUNT(*) INTO v_ca_count FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test';
  SELECT c.active_count INTO v_active FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test';

  DBMS_OUTPUT.PUT_LINE('=== Test 2 Assert: Concurrent Double-Cancel ===');
  DBMS_OUTPUT.PUT_LINE('  Journals : ' || v_jcount || ' (reserved=' || v_reserved || ', cancelled=' || v_cancelled || ')');
  DBMS_OUTPUT.PUT_LINE('  ActiveAllocation: ' || v_aacount);
  DBMS_OUTPUT.PUT_LINE('  CurrentAlloc    : ' || v_ca_count);
  DBMS_OUTPUT.PUT_LINE('  Capacity active : ' || v_active);
  DBMS_OUTPUT.PUT_LINE('');

  -- CONSISTENCY CHECK
  IF v_aacount = 0 AND v_ca_count = 0 AND v_active = 0 THEN
    DBMS_OUTPUT.PUT_LINE('  CONSISTENCY CHECK: AA=0, CA=0, active=0 [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  CONSISTENCY CHECK: [FAIL] - state is inconsistent!');
  END IF;

  -- EXACTLY 1 cancel should exist (the other was rolled back or never created)
  IF v_reserved = 1 AND v_cancelled = 1 AND v_jcount = 2 THEN
    DBMS_OUTPUT.PUT_LINE('  DUPLICATE PREVENTION: exactly 1 cancel entry [PASS]');
    DBMS_OUTPUT.PUT_LINE('    (Second cancel was blocked by -20912 or -20003)');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  DUPLICATE PREVENTION: [CHECK] journals=' || v_jcount ||
      ', cancelled=' || v_cancelled);
    DBMS_OUTPUT.PUT_LINE('    Expected: 2 journals (1 reserved, 1 cancelled)');
  END IF;
END;
/


-- =============================================================================
-- =============================================================================
-- TEST 3: Concurrent Double-Confirm
-- =============================================================================
-- =============================================================================
--
-- GOAL: Observe behavior when two sessions try to confirm the same reservation
-- simultaneously. This test documents a timing-dependent TOCTOU window.
--
-- EXPECTED OUTCOMES (timing-dependent):
--
-- Outcome A - Both read CurrentAllocations BEFORE either's autonomous tx commits:
--   Both see status='reserved', pass the status check.
--   Session 1: UPDATE ActiveAllocation → locks row, commits
--   Session 2: UPDATE ActiveAllocation → waits for lock → row exists → succeeds
--   Result: Two 'confirmed' journal entries. Harmless duplicate.
--           ActiveAllocation points to Session 2's entry.
--
-- Outcome B - Session 2 reads AFTER Session 1's autonomous tx commits:
--   Session 1: committed 'confirmed' journal. CurrentAllocations now shows
--   the NEW journal_id (higher ID) as 'confirmed', not the original.
--   Session 2: SELECT WHERE journal_id = original → NO_DATA_FOUND → -20002
--   Result: One 'confirmed' entry. Second session gets clean error.
--
-- CONSISTENCY: In both outcomes, ActiveAllocation and CurrentAllocations are
-- consistent. Outcome A produces audit noise (two confirmed entries) but no
-- data corruption. The status validation prevents backward transitions
-- (e.g., confirming a 'boarded' entry).
--
-- =============================================================================

PROMPT
PROMPT =========================================================================
PROMPT   TEST 3: Concurrent Double-Confirm
PROMPT =========================================================================
PROMPT

-- [SETUP] Create a reservation to operate on
-- BLOCKS on RESERVATION_EVENTS_Q. From a SECOND session run AA_PUBLISH_CONFIRM
-- (defined above Test 1) to unblock.

DECLARE
  v_user_id NUMBER;
  v_leader  NUMBER;
BEGIN
  -- Reset
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  UPDATE Capacity SET active_count = 0
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  COMMIT;

  SELECT id INTO v_user_id FROM Users WHERE name = 'AA_User1';

  ResourceManagement.MakeReservation(
    p_context_identifier => 'AA_CONCUR_Test',
    p_user_id            => v_user_id,
    p_category_name      => 'AA_Class',
    p_quantity           => 1,
    p_new_journal_id     => v_leader
  );
  DBMS_OUTPUT.PUT_LINE('Test 3 setup: Reserved+confirmed seat. group_leader_journal_id = ' || NVL(TO_CHAR(v_leader), 'NULL'));
END;
/

PROMPT
PROMPT   INSTRUCTIONS:
PROMPT   -----------------------------------------------------------------------
PROMPT   1. Paste the SAME block below into BOTH sessions.
PROMPT   2. Run BOTH at the same time (within 1-2 seconds of each other).
PROMPT   3. After both complete, run the ASSERT below.
PROMPT   -----------------------------------------------------------------------
PROMPT

-- =============================================================================
-- TEST 3: [SESSION 1] and [SESSION 2] - Confirm (paste in BOTH, run simultaneously)
-- =============================================================================
DECLARE
  v_journal_id NUMBER;
BEGIN
  -- Find the active reservation
  SELECT ca.journal_id INTO v_journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'AA_CONCUR_Test'
    AND ca.status = 'reserved';

  DBMS_OUTPUT.PUT_LINE('Test 3: Confirming journal ' || v_journal_id || '...');

  ResourceManagement.ConfirmReservation(v_journal_id);
  -- COMMIT manually in this terminal when you want this session's tx to commit.
  DBMS_OUTPUT.PUT_LINE('Test 3: SUCCESS - confirmed journal ' || v_journal_id);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('Test 3: EXPECTED - reservation already confirmed (NO_DATA_FOUND on reserved status)');
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('Test 3: EXPECTED FAILURE - ' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('  (If -20002: other session already confirmed, original journal_id no longer latest)');
END;
/

-- =============================================================================
-- TEST 3: [ASSERT] - Run after both sessions complete
-- =============================================================================

PROMPT --- AllocationJournal entries ---
SELECT aj.id, aj.status, ri.instance_identifier
FROM AllocationJournal aj
JOIN AllocationContext ac ON aj.context_id = ac.id
LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
WHERE ac.context_identifier = 'AA_CONCUR_Test'
ORDER BY aj.id;

PROMPT --- ActiveAllocation ---
SELECT aa.context_id, aa.resource_instance_id, aa.journal_id
FROM ActiveAllocation aa
JOIN AllocationContext ac ON aa.context_id = ac.id
WHERE ac.context_identifier = 'AA_CONCUR_Test';

DECLARE
  v_jcount    NUMBER;
  v_reserved  NUMBER;
  v_confirmed NUMBER;
  v_aacount   NUMBER;
  v_ca_count  NUMBER;
  v_ca_status VARCHAR2(20);
BEGIN
  SELECT COUNT(*) INTO v_jcount FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test';
  SELECT COUNT(*) INTO v_reserved FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test' AND aj.status = 'reserved';
  SELECT COUNT(*) INTO v_confirmed FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test' AND aj.status = 'confirmed';
  SELECT COUNT(*) INTO v_aacount FROM ActiveAllocation aa
  JOIN AllocationContext ac ON aa.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test';
  SELECT COUNT(*) INTO v_ca_count FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test';
  BEGIN
    SELECT ca.status INTO v_ca_status FROM CurrentAllocations ca
    JOIN AllocationContext ac ON ca.context_id = ac.id WHERE ac.context_identifier = 'AA_CONCUR_Test';
  EXCEPTION
    WHEN NO_DATA_FOUND THEN v_ca_status := '(none)';
    WHEN TOO_MANY_ROWS THEN v_ca_status := '(multiple!)';
  END;

  DBMS_OUTPUT.PUT_LINE('=== Test 3 Assert: Concurrent Double-Confirm ===');
  DBMS_OUTPUT.PUT_LINE('  Journals : ' || v_jcount || ' (reserved=' || v_reserved || ', confirmed=' || v_confirmed || ')');
  DBMS_OUTPUT.PUT_LINE('  ActiveAllocation: ' || v_aacount);
  DBMS_OUTPUT.PUT_LINE('  CurrentAlloc    : ' || v_ca_count || ' (status=' || v_ca_status || ')');
  DBMS_OUTPUT.PUT_LINE('');

  -- CONSISTENCY CHECK: AA and CA must agree
  IF v_aacount = 1 AND v_ca_count = 1 AND v_ca_status = 'confirmed' THEN
    DBMS_OUTPUT.PUT_LINE('  CONSISTENCY CHECK: AA=1, CA=1, status=confirmed [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  CONSISTENCY CHECK: [FAIL] - AA=' || v_aacount || ', CA=' || v_ca_count);
  END IF;

  IF v_confirmed = 1 THEN
    DBMS_OUTPUT.PUT_LINE('  OUTCOME B: Second session got -20002 (1 confirm entry) [CLEAN]');
  ELSIF v_confirmed = 2 THEN
    DBMS_OUTPUT.PUT_LINE('  OUTCOME A: Both confirmed (TOCTOU window). 2 confirm entries.');
    DBMS_OUTPUT.PUT_LINE('    This is harmless audit noise - ActiveAllocation is consistent.');
    DBMS_OUTPUT.PUT_LINE('    (To fully prevent: would need SELECT FOR UPDATE in business layer)');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  UNEXPECTED: confirmed=' || v_confirmed || '. Check raw data above.');
  END IF;
END;
/


-- =============================================================================
-- TEARDOWN
-- =============================================================================

PROMPT
PROMPT =========================================================================
PROMPT   TEARDOWN - Run when all tests are complete
PROMPT =========================================================================

DECLARE
  v_j NUMBER; v_aa NUMBER; v_c NUMBER; v_ctx NUMBER;
  v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'AA_CONCUR_Test';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'AA_Asset');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'AA_Asset');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'AA_Asset';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name IN ('AA_User1');
  v_u := SQL%ROWCOUNT;
  DELETE FROM ResourceCategory WHERE name = 'AA_Class';
  v_rc := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Teardown: J=' || v_j || ' AA=' || v_aa || ' Cap=' || v_c ||
    ' Ctx=' || v_ctx || ' RI=' || v_ri || ' AC=' || v_ac || ' RA=' || v_ra ||
    ' U=' || v_u || ' RC=' || v_rc);
END;
/

PROMPT
PROMPT =========================================================================
PROMPT   MANUAL_Concurrent_ActiveAllocation complete.
PROMPT =========================================================================
