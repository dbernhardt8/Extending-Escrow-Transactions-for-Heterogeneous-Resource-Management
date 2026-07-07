-- =============================================================================
-- demo_03_compensation_concurrent.sql
-- =============================================================================
-- Interactive demo: ActiveAllocation conflict (-20910) + saga compensation.
--
-- Two sessions race for the SAME 2 seats of a tiny category pool. The winner
-- commits two autonomous journals and blocks on the AQ event queue. The loser
-- hits DUP_VAL_ON_INDEX on the ActiveAllocation unique constraint, surfaces
-- as -20910 inside ReserveByCategory, triggers CompensateJournalEntry on any
-- earlier seat already committed by THIS attempt, retries up to 3 times with
-- exponential back-off, and finally raises -20001 "Unable to complete
-- reservation due to high demand" once the pool is empty.
--
-- After the race, a CONFIRM event from a third session (or from the loser
-- session once it has dismissed its error) wakes the winner.
--
-- Run:    @demo_03_compensation_concurrent.sql      (in Session A = winner)
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
SET DEFINE OFF
SET FEEDBACK ON
SET SQLBLANKLINES ON

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 03 - Concurrent Compensation (-20910 race + saga compensation)
PROMPT =============================================================================
PROMPT
PROMPT  Scenario: 2 sessions, only 2 seats. Both ask for 2 within a 1-second
PROMPT  window. Winner reserves both; loser sees -20910 / -20001 and the
PROMPT  AllocationJournal records the compensation entries.
PROMPT
PAUSE  Press ENTER to clean up any previous demo data and start setup...

-- =============================================================================
-- Step 1: Cleanup
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_RACE')]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_RACE')]');
  silent_delete(q'[DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_RACE')]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier = 'DEMO_RACE']');
  silent_delete(q'[DELETE FROM ResourceInstance WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_RACE_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity    WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_RACE_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset    WHERE name = 'DEMO_RACE_ASSET']');
  silent_delete(q'[DELETE FROM Users            WHERE name IN ('DEMO_RACE_USER_A','DEMO_RACE_USER_B')]');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_RACE_Business']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 1: previous demo data cleaned.');
END;
/

DELETE FROM DebugLog;
COMMIT;

-- =============================================================================
-- Step 2: Setup (only 2 seats so conflict is forced)
-- =============================================================================
DECLARE
  v_asset_id NUMBER;
  v_cat_id   NUMBER;
  v_i        NUMBER;
BEGIN
  BEGIN ResourceManagement_Data.AddResourceStatus('reserved',  'Held');      EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('confirmed', 'Confirmed'); EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('cancelled', 'Cancelled'); EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceInstanceStatus('available', 'Available'); EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;

  ResourceManagement_Data.AddResourceCategory('DEMO_RACE_Business', NULL, 'pool');
  ResourceManagement_Data.AddUser('DEMO_RACE_USER_A');
  ResourceManagement_Data.AddUser('DEMO_RACE_USER_B');
  ResourceManagement_Data.AddResourceAsset('DEMO_RACE_ASSET', NULL, 'active');

  SELECT id INTO v_asset_id FROM ResourceAsset    WHERE name = 'DEMO_RACE_ASSET';
  SELECT id INTO v_cat_id   FROM ResourceCategory WHERE name = 'DEMO_RACE_Business';

  ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_cat_id, 2);
  FOR v_i IN 1..2 LOOP
    ResourceManagement_Data.AddResourceInstance(v_asset_id, v_cat_id, 'RC' || v_i, 'available');
  END LOOP;
  ResourceManagement_Data.AddAllocationContext(v_asset_id, 'DEMO_RACE', SYSDATE + 1, SYSDATE + 2);
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 2: setup complete (2 instances RC1/RC2, capacity=2, 2 users).');
END;
/

PROMPT
PAUSE  Press ENTER to inspect the initial state...

-- =============================================================================
-- Step 3: Show pre-state
-- =============================================================================
PROMPT === Resource instances ===
SELECT ri.id, ri.instance_identifier, ri.status
  FROM ResourceInstance ri
  JOIN ResourceAsset    ra ON ri.asset_id = ra.id
 WHERE ra.name = 'DEMO_RACE_ASSET'
 ORDER BY ri.id;

PROMPT === Capacity (total=2, active=0) ===
SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_RACE';

PROMPT === No journals ===
SELECT COUNT(*) FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
 WHERE ac.context_identifier = 'DEMO_RACE';

PROMPT
PAUSE  Press ENTER to see the Session B "loser" block...

-- =============================================================================
-- Step 4: Show Session B block + start race
-- =============================================================================
PROMPT
PROMPT =============================================================================
PROMPT   COPY THIS BLOCK INTO A SECOND SESSION (Session B). Paste it but DO NOT
PROMPT   run it yet. The timing matters: Session A presses ENTER first, then
PROMPT   Session B presses ENTER within ~1 second.
PROMPT =============================================================================
PROMPT
PROMPT   -- Session B: race for the same 2 seats as DEMO_RACE_USER_A -----------
PROMPT   DECLARE
PROMPT     v_user_id NUMBER;
PROMPT     v_ids     NUMBER;
PROMPT   BEGIN
PROMPT     SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_RACE_USER_B';
PROMPT     ResourceManagement.MakeReservation(
PROMPT       p_context_identifier => 'DEMO_RACE',
PROMPT       p_user_id            => v_user_id,
PROMPT       p_category_name      => 'DEMO_RACE_Business',
PROMPT       p_quantity           => 2,
PROMPT       p_timeout_minutes    => 5,
PROMPT       p_new_journal_id     => v_ids
PROMPT     );
PROMPT     DBMS_OUTPUT.PUT_LINE('Session B: SUCCESS leader=' || v_ids);
PROMPT   EXCEPTION
PROMPT     WHEN OTHERS THEN
PROMPT       DBMS_OUTPUT.PUT_LINE('Session B: EXPECTED FAILURE ' || SQLERRM);
PROMPT   END;
PROMPT   /
PROMPT
PROMPT   -----------------------------------------------------------------------
PROMPT
PAUSE  Session B ready? Press ENTER -- Session A will start; immediately press ENTER on Session B.

PROMPT
PROMPT  *** Session A: calling MakeReservation(category, quantity=2). ***
PROMPT  ***            One of A/B will win, the other will surface -20910 ***
PROMPT  ***            and emit compensation journals. ***
PROMPT

DECLARE
  v_user_id      NUMBER;
  v_group_leader NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_RACE_USER_A';
  ResourceManagement.MakeReservation(
    p_context_identifier => 'DEMO_RACE',
    p_user_id            => v_user_id,
    p_category_name      => 'DEMO_RACE_Business',
    p_quantity           => 2,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_group_leader
  );
  DBMS_OUTPUT.PUT_LINE('Session A: SUCCESS leader=' || v_group_leader);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Session A: FAILURE ' || SQLERRM);
END;
/

PAUSE CHECK ESCROW TABLE

SELECT * FROM SYS_RESERVJRNL_78355;

PAUSE PROCEED WITH CAUTION, NEXT STEP IS MANUAL COMMIT

COMMIT;


PROMPT
PROMPT  Session A returned. If Session A WON it just unblocked because Session B
PROMPT  raised an error (no AQ event was needed). If Session A LOST you saw the
PROMPT  compensation message above; Session B is now blocked on AQ and needs a
PROMPT  CONFIRM event below.
PROMPT
PAUSE  Press ENTER to inspect the journals (look for cancelled rows with compensation metadata)...

-- =============================================================================
-- Step 5: Show post-state (look for cancellation/compensation rows)
-- =============================================================================
PROMPT === AllocationJournal entries (newest first) ===
SELECT aj.id, aj.status,
       u.name AS user_name,
       ri.instance_identifier,
       JSON_VALUE(aj.metadata, '$.compensation_reason') AS comp_reason,
       JSON_VALUE(aj.metadata, '$.original_journal_id') AS orig_journal_id
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
  LEFT JOIN Users u             ON aj.user_id = u.id
  LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_RACE'
 ORDER BY aj.id DESC;

PROMPT === ActiveAllocation (live seats) ===
SELECT u.name AS user_name, ri.instance_identifier, aa.journal_id
  FROM ActiveAllocation aa
  JOIN AllocationContext ac ON aa.context_id = ac.id
  LEFT JOIN Users            u  ON aa.user_id = u.id
  LEFT JOIN ResourceInstance ri ON aa.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_RACE';

PROMPT === Capacity ===
SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_RACE';

PROMPT === DebugLog: compensation / retry / conflict ===
SELECT id, SUBSTR(message, 1, 150) AS message
  FROM DebugLogSorted
 WHERE message LIKE '%ReserveByCategory%'
    OR message LIKE '%conflict%'
    OR message LIKE '%retry%'
    OR message LIKE '%CompensateJournal%'
    OR message LIKE '%-20910%'
 FETCH FIRST 20 ROWS ONLY;

PROMPT
PROMPT  Interpret:
PROMPT    * If you see 2 'reserved' (one user) AND 1+ 'cancelled' rows with
PROMPT      compensation_reason='retry_conflict' (other user) -> COMPENSATION FIRED.
PROMPT    * If you only see 2 'reserved' for one user and the other failed with
PROMPT      "Not enough seats" without cancelled rows, the loser conflicted on
PROMPT      the FIRST seat (nothing to compensate yet) and bailed out cleanly.
PROMPT
PROMPT  The winner is whichever user still has rows in ActiveAllocation.
PROMPT
PAUSE  Press ENTER to see the wake-up publish block for whichever session is still blocked...

-- =============================================================================
-- Step 6: Wake the winner (if still blocked) from a third session
-- =============================================================================
PROMPT
PROMPT =============================================================================
PROMPT   If a session is still blocked on AQ (its DBMS_AQ.DEQUEUE is waiting),
PROMPT   wake it from any free session with this block. Replace the user name
PROMPT   with whichever user actually has 'reserved' rows in ActiveAllocation.
PROMPT =============================================================================
PROMPT
PROMPT   DECLARE
PROMPT     v_user_id NUMBER;
PROMPT   BEGIN
PROMPT     SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_RACE_USER_A'; -- adjust to actual winner
PROMPT     ResourceManagement.publish_group_reservation_event(
PROMPT       p_context_identifier => 'DEMO_RACE',
PROMPT       p_user_id            => v_user_id,
PROMPT       p_category_name      => 'DEMO_RACE_Business',
PROMPT       p_action             => 'CONFIRM'  -- or 'CANCEL'
PROMPT     );
PROMPT   END;
PROMPT   /
PROMPT
PAUSE  Press ENTER to tear down the demo data...

-- =============================================================================
-- Step 7: Teardown
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_RACE')]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_RACE')]');
  silent_delete(q'[DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_RACE')]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier = 'DEMO_RACE']');
  silent_delete(q'[DELETE FROM ResourceInstance WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_RACE_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity    WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_RACE_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset    WHERE name = 'DEMO_RACE_ASSET']');
  silent_delete(q'[DELETE FROM Users            WHERE name IN ('DEMO_RACE_USER_A','DEMO_RACE_USER_B')]');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_RACE_Business']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 7: teardown complete.');
END;
/

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 03 finished.
PROMPT =============================================================================
