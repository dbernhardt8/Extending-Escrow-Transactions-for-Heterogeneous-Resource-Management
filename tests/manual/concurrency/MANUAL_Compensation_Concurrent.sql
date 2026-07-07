-- =============================================================================
-- MANUAL_Compensation_Concurrent.sql
-- =============================================================================
-- Multi-session manual test for compensation logic using REAL concurrency.
--
-- APPROACH:
-- Instead of a test-hook trigger on Capacity (which doesn't work with
-- RESERVABLE columns because triggers fire at COMMIT, not during UPDATE),
-- this test uses two SQL sessions running in parallel to trigger the real
-- compensation path: the ActiveAllocation UNIQUE constraint violation
-- (error -20910) that occurs when two sessions try to reserve the same
-- resource instance concurrently.
--
-- HOW IT WORKS:
-- The only compensation path in MakeReservation that fires INSIDE the
-- procedure (not at commit time) is the e_active_alloc_conflict exception
-- (-20910). This happens when AddAllocationJournal (autonomous) tries to
-- INSERT into ActiveAllocation and hits a DUP_VAL_ON_INDEX because another
-- session's autonomous tx already committed the same (context_id,
-- resource_instance_id) row.
--
-- When this happens:
--   1. AddAllocationJournal's autonomous tx rolls back (no journal committed
--      for the conflicting entry)
--   2. -20910 propagates to MakeReservation's WHEN e_active_alloc_conflict
--   3. ROLLBACK TO start_reservation undoes capacity
--   4. CompensateJournalEntry cancels any journals committed in EARLIER
--      iterations of the FOR loop (before the conflict)
--   5. MakeReservation retries up to 3 times
--
-- =============================================================================
--
-- LIVE COMPENSATION PATHS
-- ========================
--
-- 1. MakeReservation → e_active_alloc_conflict (-20910)
--    Trigger: Two sessions reserve the same instance concurrently
--    Compensation: Cancel all journals from earlier loop iterations
--    TESTABLE with concurrent sessions: YES (Test A below)
--
-- 2. MakeReservation → WHEN OTHERS (general failure)
--    Trigger: Any unexpected error during Phase 2
--    Compensation: Cancel all journals from this attempt
--    NOTE: Safety net only. With RESERVABLE columns, capacity errors surface
--    at COMMIT, not here.
--    TESTABLE with concurrent sessions: NO
--
-- 3. ReserveContained / ReserveShared → WHEN OTHERS
--    Same safety-net pattern as #2 for single-instance reservations
--    (called via MakeReservation dispatcher).
--    TESTABLE: NO
--
-- 4. reserve_offer_batch → WHEN OTHERS
--    Used by MakeReservationWithAlternative for substitution offers.
--    Compensation: Cancel all journals committed in THIS batch
--    TESTABLE: Requires substitution setup + concurrent conflict
--
-- 5. CancelFlight → WHEN OTHERS
--    Compensation: Cancel all committed block journals
--    Uses local v_committed_journal_ids collection.
--    TESTABLE: Partially - if one BlockResource inside the loop fails
--    due to concurrency, all prior blocks are compensated.
--
-- CONCURRENCY GUARDS (in AddAllocationJournal):
--
-- 6. INSERT ActiveAllocation → DUP_VAL_ON_INDEX → -20910
--    Guards against double-booking same instance in same context.
--    TESTABLE: YES (Tests A, C below)
--
-- 7. UPDATE ActiveAllocation → SQL%ROWCOUNT = 0 → -20911
--    Guards against transitioning an allocation concurrently cancelled.
--    TESTABLE: YES (see MANUAL_Concurrent_ActiveAllocation.sql)
--
-- 8. DELETE ActiveAllocation → SQL%ROWCOUNT = 0 → -20912
--    Guards against double-cancel / double-complete.
--    TESTABLE: YES (see MANUAL_Concurrent_ActiveAllocation.sql)
--
--
-- TESTABLE SCENARIOS IN THIS FILE:
-- =================================
-- Test A: MakeReservation concurrent conflict (e_active_alloc_conflict)
--         → Compensation cancels journals from earlier loop iterations
-- Test C: Concurrent BlockResource on same instance
--         → DUP_VAL_ON_INDEX on ActiveAllocation (-20910)
-- Test D: MakeReservation with quantity > 1, conflict on 2nd seat
--         → First seat's journal is compensated, second seat's autonomous
--         tx rolled back
--
-- =============================================================================
-- PREREQUISITES
-- =============================================================================
-- 1. Two SQL sessions connected to the same database schema
--    (e.g., two SQL Developer windows, two sqlplus terminals, or two
--    APEX SQL Workshop tabs)
-- 2. Reference data loaded (ResourceStatus, ResourceInstanceStatus)
-- 3. DO NOT have any uncommitted transactions in either session
--
-- 4. AQ-BLOCKING BEHAVIOR (NEW):
--    MakeReservation now reserves all seats atomically and then BLOCKS on
--    RESERVATION_EVENTS_Q (correlation 'RESGRP_<leader>') until a
--    publish_group_reservation_event arrives or the timeout expires.
--    For Tests A and D below, the WINNING session reserves both seats and
--    then blocks until a CONFIRM/CANCEL is published from a third session
--    (or the loser session, after its error has surfaced). The LOSING
--    session conflicts on ActiveAllocation (-20910), compensates whatever
--    it had committed up to that point, and returns synchronously.
--    A "WAKE WINNER" block is provided after the race. Run it from any
--    free session to release the still-blocked winner.
--
-- =============================================================================
-- NOTATION
-- =============================================================================
-- [SETUP]      = Run in either session (only one person runs it)
-- [SESSION 1]  = Run in session 1 only
-- [SESSION 2]  = Run in session 2 only
-- [ASSERT]     = Run in either session to verify results
-- [CLEANUP]    = Run in either session
--
-- COMMIT BEHAVIOR (NEW):
-- ----------------------
-- MakeReservation commits internally on its own success/failure path
-- (autonomous-tx journals + final COMMIT after the AQ event arrives;
-- ROLLBACK + compensation on error). No manual COMMIT/ROLLBACK from the
-- calling session is required around MakeReservation.
--
-- Setup steps (Step 0, Step 1, per-test setup) and TEARDOWN still keep
-- their explicit COMMIT so shared state is visible to both sessions.
--
-- IMPORTANT: Follow the steps IN ORDER. The timing matters.
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

-- =============================================================================
-- STEP 0: [SETUP] Cleanup any previous test data
-- =============================================================================

DECLARE
  v_j NUMBER; v_aa NUMBER; v_c NUMBER; v_ctx NUMBER; v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'CONCUR_Asset');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'CONCUR_Asset');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'CONCUR_Asset';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name IN ('CONCUR_User1', 'CONCUR_User2');
  v_u := SQL%ROWCOUNT;
  DELETE FROM ResourceCategory WHERE name = 'CONCUR_Class';
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
-- Asset with only 2 instances (to make conflicts easy to trigger)

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
  BEGIN ResourceManagement_Data.AddResourceStatus('checked-in', 'Checked In');
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('blocked', 'Blocked');
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('completed', 'Completed');
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceInstanceStatus('available', 'Available');
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;

  ResourceManagement_Data.AddResourceCategory('CONCUR_Class', NULL, 'pool');
  ResourceManagement_Data.AddUser('CONCUR_User1');
  ResourceManagement_Data.AddUser('CONCUR_User2');
  ResourceManagement_Data.AddResourceAsset('CONCUR_Asset', NULL, 'active');

  SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'CONCUR_Asset';
  SELECT id INTO v_category_id FROM ResourceCategory WHERE name = 'CONCUR_Class';

  ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_category_id, 2);

  -- Only 2 instances: forces conflict when both sessions try quantity=2
  ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'CC1', 'available');
  ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'CC2', 'available');

  ResourceManagement_Data.AddAllocationContext(v_asset_id, 'CONCUR_CompTest', SYSDATE + 1, SYSDATE + 2);
  COMMIT;

  DBMS_OUTPUT.PUT_LINE('Step 1: Setup complete. Asset=' || v_asset_id ||
    ', Category=' || v_category_id || ', 2 instances, capacity=2.');
END;
/

-- Verify initial state
SELECT c.total_capacity, c.active_count
FROM Capacity c JOIN AllocationContext ac ON c.context_id = ac.id
WHERE ac.context_identifier = 'CONCUR_CompTest';

SELECT COUNT(*) AS journal_count FROM AllocationJournal aj
JOIN AllocationContext ac ON aj.context_id = ac.id
WHERE ac.context_identifier = 'CONCUR_CompTest';

SELECT COUNT(*) AS aa_count FROM ActiveAllocation aa
JOIN AllocationContext ac ON aa.context_id = ac.id
WHERE ac.context_identifier = 'CONCUR_CompTest';

PROMPT
PROMPT =========================================================================
PROMPT   Setup complete. Initial state: capacity=2, journals=0, AA=0
PROMPT =========================================================================
PROMPT


-- =============================================================================
-- TEST A: MakeReservation concurrent conflict (e_active_alloc_conflict)
-- =============================================================================
-- Goal: Two sessions both try MakeReservation(quantity=2) on an asset with
-- only 2 instances. Both sessions query the same 2 available instances.
-- One session's autonomous INSERT into ActiveAllocation succeeds first;
-- the other session hits DUP_VAL_ON_INDEX, triggering compensation.
--
-- EXPECTED BEHAVIOR (with the new AQ flow):
--   - Session 1 (winner): Reserves 2 seats and BLOCKS on RESERVATION_EVENTS_Q
--     waiting for a CONFIRM/CANCEL.
--   - Session 2 (loser):  Hits -20910 on the ActiveAllocation INSERT, retries
--     up to 3 times, eventually surfaces -20001 "Not enough seats" once both
--     instances are taken. Any earlier committed seat is compensated.
--   - Use the "WAKE WINNER" block at the end of Test A to release Session 1.
--
-- TIMING: The race window is between the two sessions' AddAllocationJournal
-- calls (autonomous commits). Both sessions query the same available
-- instances BEFORE either commits, so the conflict is very likely.
-- =============================================================================

PROMPT
PROMPT =========================================================================
PROMPT   TEST A: Concurrent MakeReservation conflict
PROMPT =========================================================================
PROMPT
PROMPT   INSTRUCTIONS:
PROMPT   -----------------------------------------------------------------------
PROMPT   1. Open TWO SQL sessions (Session 1 and Session 2)
PROMPT   2. Run Step 0 + Step 1 in one session first (setup)
PROMPT   3. Prepare the following block in BOTH sessions (do NOT run yet):
PROMPT
PROMPT   ------ COPY THIS TO BOTH SESSIONS ------

-- =============================================================================
-- TEST A: [SESSION 1] and [SESSION 2] - Run simultaneously
-- =============================================================================
-- Paste this in both sessions. Run Session 1 first, then Session 2 immediately
-- (within 1-2 seconds).

DECLARE
  v_user_id   NUMBER;
  v_leader    NUMBER;
  v_user_name VARCHAR2(50);
BEGIN
  -- Session 1 uses CONCUR_User1, Session 2 uses CONCUR_User2
  -- >>> CHANGE THIS LINE for Session 2: use 'CONCUR_User2' <<<
  v_user_name := 'CONCUR_User1';

  SELECT id INTO v_user_id FROM Users WHERE name = v_user_name;

  DBMS_OUTPUT.PUT_LINE('Test A: ' || v_user_name || ' requesting 2 seats...');

  BEGIN
    -- Winner: reserves both seats and BLOCKS on AQ until CONFIRM/CANCEL.
    -- Loser:  -20910 → compensation → retry → -20001 (returns synchronously).
    ResourceManagement.MakeReservation(
      p_context_identifier => 'CONCUR_CompTest',
      p_user_id            => v_user_id,
      p_category_name      => 'CONCUR_Class',
      p_quantity           => 2,
      p_timeout_minutes    => 5,
      p_new_journal_id     => v_leader
    );
    DBMS_OUTPUT.PUT_LINE('Test A: SUCCESS - ' || v_user_name || ' group_leader=' || NVL(TO_CHAR(v_leader), 'NULL'));
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Test A: EXPECTED FAILURE - ' || v_user_name || ': ' || SQLERRM);
  END;
END;
/

PROMPT
PROMPT   -----------------------------------------------------------------------
PROMPT   4. The WINNING session is now blocked on AQ. From any free session run
PROMPT      the WAKE WINNER block (below) to release it.
PROMPT   5. After the winner returns, run the ASSERT in either session.
PROMPT   -----------------------------------------------------------------------
PROMPT

-- =============================================================================
-- TEST A: [WAKE WINNER] - Run from a free session after the loser fails
-- =============================================================================
-- Replace the user name with whichever user actually has reserved seats in
-- ActiveAllocation (the winner of the race).

-- DECLARE
--   v_user_id NUMBER;
-- BEGIN
--   SELECT id INTO v_user_id FROM Users WHERE name = 'CONCUR_User1';   -- adjust to actual winner
--   ResourceManagement.publish_group_reservation_event(
--     p_context_identifier => 'CONCUR_CompTest',
--     p_user_id            => v_user_id,
--     p_category_name      => 'CONCUR_Class',
--     p_action             => 'CONFIRM'   -- or 'CANCEL'
--   );
-- END;
-- /

-- =============================================================================
-- TEST A: [ASSERT] - Run after both sessions complete
-- =============================================================================

-- --- AllocationJournal entries ---
SELECT aj.id, aj.status, u.name AS user_name,
       ri.instance_identifier, SUBSTR(aj.metadata, 1, 80) AS meta
FROM AllocationJournal aj
JOIN AllocationContext ac ON aj.context_id = ac.id
LEFT JOIN Users u ON aj.user_id = u.id
LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
WHERE ac.context_identifier = 'CONCUR_CompTest'
ORDER BY aj.id;

-- --- ActiveAllocation ---
SELECT aa.context_id, aa.resource_instance_id, aa.journal_id,
       ri.instance_identifier
FROM ActiveAllocation aa
JOIN AllocationContext ac ON aa.context_id = ac.id
LEFT JOIN ResourceInstance ri ON aa.resource_instance_id = ri.id
WHERE ac.context_identifier = 'CONCUR_CompTest';

-- --- Capacity ---
SELECT c.total_capacity, c.active_count
FROM Capacity c JOIN AllocationContext ac ON c.context_id = ac.id
WHERE ac.context_identifier = 'CONCUR_CompTest';

-- --- CurrentAllocations ---
SELECT ca.journal_id, ca.status, ca.user_id, ca.resource_instance_id
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
WHERE ac.context_identifier = 'CONCUR_CompTest';

-- --- DebugLog (compensation entries) ---
SELECT id, SUBSTR(message, 1, 120) AS message
FROM DebugLog
WHERE message LIKE '%COMPENSATION%' OR message LIKE '%MakeReservation%retry%'
ORDER BY id DESC
FETCH FIRST 10 ROWS ONLY;

DECLARE
  v_jcount    NUMBER;
  v_reserved  NUMBER;
  v_cancelled NUMBER;
  v_active    NUMBER;
  v_aacount   NUMBER;
  v_ca_count  NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_jcount FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'CONCUR_CompTest';
  SELECT COUNT(*) INTO v_reserved FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'CONCUR_CompTest' AND aj.status = 'reserved';
  SELECT COUNT(*) INTO v_cancelled FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'CONCUR_CompTest' AND aj.status = 'cancelled';
  SELECT c.active_count INTO v_active FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id WHERE ac.context_identifier = 'CONCUR_CompTest';
  SELECT COUNT(*) INTO v_aacount FROM ActiveAllocation aa
  JOIN AllocationContext ac ON aa.context_id = ac.id WHERE ac.context_identifier = 'CONCUR_CompTest';
  SELECT COUNT(*) INTO v_ca_count FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id WHERE ac.context_identifier = 'CONCUR_CompTest';

  DBMS_OUTPUT.PUT_LINE('=== Test A Assert ===');
  DBMS_OUTPUT.PUT_LINE('  Total journals  : ' || v_jcount || ' (reserved=' || v_reserved || ', cancelled=' || v_cancelled || ')');
  DBMS_OUTPUT.PUT_LINE('  ActiveAllocation: ' || v_aacount);
  DBMS_OUTPUT.PUT_LINE('  CurrentAlloc    : ' || v_ca_count);
  DBMS_OUTPUT.PUT_LINE('  Capacity active : ' || v_active);
  DBMS_OUTPUT.PUT_LINE('');

  -- One session should succeed with 2 reserved. The other should fail.
  -- If the losing session had committed any journals before conflict, those
  -- should be compensated (cancelled).
  IF v_ca_count = 2 AND v_aacount = 2 THEN
    DBMS_OUTPUT.PUT_LINE('  Winner: 2 active allocations [OK]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  Unexpected active allocation count [CHECK]');
  END IF;

  -- Any cancelled entries indicate compensation ran
  IF v_cancelled > 0 THEN
    DBMS_OUTPUT.PUT_LINE('  Compensation: ' || v_cancelled || ' cancelled entries found [COMPENSATION VERIFIED]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  Compensation: No cancelled entries.');
    DBMS_OUTPUT.PUT_LINE('    This is OK if the losing session hit conflict on the FIRST');
    DBMS_OUTPUT.PUT_LINE('    instance (no prior journal to compensate) and then got');
    DBMS_OUTPUT.PUT_LINE('    "not enough seats" on retry.');
  END IF;
END;
/


-- =============================================================================
-- TEST D: MakeReservation(2) conflict on SECOND seat
-- =============================================================================
-- This is the most interesting test: it triggers compensation of the FIRST
-- seat's journal after conflict on the SECOND seat.
--
-- Setup: 3 instances, both sessions request 2 seats.
-- Session 1 reserves instances 1+2. Session 2 gets instance 1 (or 2) first
-- (autonomous commit), then conflicts on the other. The compensation must
-- cancel the first journal that Session 2 committed.
-- =============================================================================

PROMPT
PROMPT =========================================================================
PROMPT   TEST D: Conflict on 2nd seat with compensation of 1st
PROMPT =========================================================================
PROMPT
PROMPT   To run Test D, first reset and add a 3rd instance:
PROMPT

-- [SETUP] Reset + add 3rd instance for Test D
DECLARE
  v_asset_id    NUMBER;
  v_category_id NUMBER;
  v_count       NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
  UPDATE Capacity SET active_count = 0
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
  COMMIT;

  SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'CONCUR_Asset';
  SELECT id INTO v_category_id FROM ResourceCategory WHERE name = 'CONCUR_Class';

  -- Add a 3rd instance so each session CAN get the first seat
  SELECT COUNT(*) INTO v_count FROM ResourceInstance
  WHERE asset_id = v_asset_id AND instance_identifier = 'CC3';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'CC3', 'available');
    -- Update capacity to 3
    UPDATE AssetCapacity SET quantity = 3
    WHERE asset_id = v_asset_id AND category_id = v_category_id;
    UPDATE Capacity SET total_capacity = 3
    WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
    COMMIT;
  END IF;

  DBMS_OUTPUT.PUT_LINE('Test D setup: 3 instances (CC1, CC2, CC3), capacity=3, journals=0, AA=0.');
END;
/

PROMPT
PROMPT   INSTRUCTIONS:
PROMPT   -----------------------------------------------------------------------
PROMPT   Both sessions run MakeReservation(quantity=2) simultaneously.
PROMPT   With 3 instances, both sessions query [CC1, CC2] (ROWNUM <= 2).
PROMPT   Session 1 reserves CC1 (autonomous commit), then CC2.
PROMPT   Session 2 reserves CC1 (conflict! -20910) or CC2, then conflicts.
PROMPT
PROMPT   If Session 2 successfully reserved CC1 before conflicting on CC2:
PROMPT     - CC1 journal (reserved) was committed autonomously
PROMPT     - CC2 conflict triggers e_active_alloc_conflict
PROMPT     - CompensateJournalEntry cancels CC1 journal
PROMPT     - Retry: only CC3 is available, but quantity=2 requested
PROMPT     - Fails with "not enough seats"
PROMPT
PROMPT   Use the same TEST A block (already updated for the new signature).
PROMPT   The WINNING session BLOCKS on AQ; release it with the WAKE WINNER
PROMPT   block above. Then run the ASSERT below.
PROMPT   -----------------------------------------------------------------------
PROMPT

-- [ASSERT] Test D
DECLARE
  v_jcount    NUMBER;
  v_reserved  NUMBER;
  v_cancelled NUMBER;
  v_comp      NUMBER;
  v_active    NUMBER;
  v_aacount   NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_jcount FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'CONCUR_CompTest';
  SELECT COUNT(*) INTO v_reserved FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'CONCUR_CompTest' AND aj.status = 'reserved';
  SELECT COUNT(*) INTO v_cancelled FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'CONCUR_CompTest' AND aj.status = 'cancelled';
  SELECT COUNT(*) INTO v_comp FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id WHERE ac.context_identifier = 'CONCUR_CompTest'
    AND aj.metadata IS NOT NULL AND aj.metadata LIKE '%compensation_reason%';
  SELECT c.active_count INTO v_active FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id WHERE ac.context_identifier = 'CONCUR_CompTest';
  SELECT COUNT(*) INTO v_aacount FROM ActiveAllocation aa
  JOIN AllocationContext ac ON aa.context_id = ac.id WHERE ac.context_identifier = 'CONCUR_CompTest';

  DBMS_OUTPUT.PUT_LINE('=== Test D Assert ===');
  DBMS_OUTPUT.PUT_LINE('  Total journals  : ' || v_jcount);
  DBMS_OUTPUT.PUT_LINE('  Reserved        : ' || v_reserved);
  DBMS_OUTPUT.PUT_LINE('  Cancelled       : ' || v_cancelled);
  DBMS_OUTPUT.PUT_LINE('  Compensation    : ' || v_comp);
  DBMS_OUTPUT.PUT_LINE('  ActiveAllocation: ' || v_aacount);
  DBMS_OUTPUT.PUT_LINE('  Capacity active : ' || v_active);
  DBMS_OUTPUT.PUT_LINE('');

  -- Winner: 2 reserved journals, loser: 1+ reserved + 1+ cancelled (compensation)
  IF v_cancelled > 0 AND v_comp > 0 THEN
    DBMS_OUTPUT.PUT_LINE('  COMPENSATION VERIFIED: ' || v_comp || ' compensation entries found.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  No compensation entries found.');
    DBMS_OUTPUT.PUT_LINE('    Check: did losing session conflict on the 1st instance (no prior journal)?');
  END IF;

  IF v_aacount = 2 THEN
    DBMS_OUTPUT.PUT_LINE('  Winner has 2 active allocations [OK]');
  END IF;
END;
/

-- --- DebugLog (recent) ---
SELECT id, SUBSTR(message, 1, 120) AS message
FROM DebugLog
WHERE message LIKE '%COMPENSATION%' OR message LIKE '%retry%' OR message LIKE '%compensating%'
ORDER BY id DESC
FETCH FIRST 15 ROWS ONLY;


-- =============================================================================
-- TEST C: Concurrent BlockResource on same instance
-- =============================================================================
-- Both sessions try to block the same resource instance simultaneously.
-- One succeeds; the other gets -20910 from ActiveAllocation.
--
-- BlockResource has no WHEN OTHERS handler (removed as dead code).
-- The -20910 error propagates directly from AddAllocationJournal through
-- BlockResource to the caller. Since the autonomous tx rolled back, no
-- journal entry was committed for the losing session.

PROMPT
PROMPT =========================================================================
PROMPT   TEST C: Concurrent BlockResource
PROMPT =========================================================================
PROMPT

-- [SETUP] Reset for Test C
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
  UPDATE Capacity SET active_count = 0
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Test C setup: reset done.');
END;
/

PROMPT
PROMPT   INSTRUCTIONS:
PROMPT   -----------------------------------------------------------------------
PROMPT   Both sessions run the SAME block below simultaneously.
PROMPT   Both try to block the same resource instance (CC1).
PROMPT
PROMPT   Expected:
PROMPT     - Session 1: BlockResource succeeds -> 'blocked' journal + AA row
PROMPT     - Session 2: AddAllocationJournal's INSERT into ActiveAllocation
PROMPT       hits DUP_VAL_ON_INDEX -> autonomous tx rolls back ->
PROMPT       -20910 propagates directly to caller (no handler in BlockResource)
PROMPT       -> No journal was committed for Session 2
PROMPT
PROMPT   ------ COPY THIS TO BOTH SESSIONS ------

DECLARE
  v_instance_id  NUMBER;
  v_journal_id   NUMBER;
BEGIN
  SELECT ri.id INTO v_instance_id
  FROM ResourceInstance ri
  JOIN ResourceAsset ra ON ri.asset_id = ra.id
  WHERE ra.name = 'CONCUR_Asset'
    AND ri.instance_identifier = 'CC1';

  DBMS_OUTPUT.PUT_LINE('Test C: Blocking instance CC1 (id=' || v_instance_id || ')...');

  BEGIN
    ResourceManagement.BlockResource(
      p_context_identifier   => 'CONCUR_CompTest',
      p_resource_instance_id => v_instance_id,
      p_reason               => 'Test C: concurrent block',
      p_metadata             => NULL,
      p_new_journal_id       => v_journal_id
    );
    -- COMMIT manually in this terminal when you want this session's tx to commit.
    DBMS_OUTPUT.PUT_LINE('Test C: SUCCESS - journal_id=' || v_journal_id);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      DBMS_OUTPUT.PUT_LINE('Test C: EXPECTED FAILURE - ' || SQLERRM);
  END;
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
  v_j NUMBER; v_aa NUMBER; v_c NUMBER; v_ctx NUMBER; v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'CONCUR_CompTest';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'CONCUR_Asset');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'CONCUR_Asset');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'CONCUR_Asset';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name IN ('CONCUR_User1', 'CONCUR_User2');
  v_u := SQL%ROWCOUNT;
  DELETE FROM ResourceCategory WHERE name = 'CONCUR_Class';
  v_rc := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Teardown: J=' || v_j || ' AA=' || v_aa || ' Cap=' || v_c ||
    ' Ctx=' || v_ctx || ' RI=' || v_ri || ' AC=' || v_ac || ' RA=' || v_ra ||
    ' U=' || v_u || ' RC=' || v_rc);
END;
/

PROMPT
PROMPT =========================================================================
PROMPT   MANUAL_Compensation_Concurrent complete.
PROMPT =========================================================================
