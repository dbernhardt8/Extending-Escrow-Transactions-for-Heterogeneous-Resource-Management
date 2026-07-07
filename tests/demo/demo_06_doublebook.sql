-- =============================================================================
-- demo_06_doublebook.sql
-- =============================================================================
-- Interactive demo: instance double-book is rejected synchronously (-20604).
--
-- Step 1: reserve seat M3 successfully (Session B confirms it).
-- Step 2: a second user tries to reserve THE SAME seat M3 in the same context
--         -> MakeReservation raises -20604 'Instance ... is already reserved'
--         WITHOUT entering the AQ wait. Demonstrates the up-front uniqueness
--         check that prevents double-booking the same physical seat.
--
-- Two SQL*Plus sessions are required:
--   * Session A (this script): setup, first reservation (blocks), inspection,
--     second reservation (fails synchronously).
--   * Session B (operator):    publish CONFIRM for the first reservation.
--
-- Run:    @demo_06_doublebook.sql      (in Session A)
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
SET DEFINE OFF
SET FEEDBACK ON
SET SQLBLANKLINES ON

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 06 - Double-book rejection (-20604)
PROMPT =============================================================================
PROMPT
PROMPT  Scenario: a flight has 3 Business seats. A first traveller reserves M3,
PROMPT  Session B confirms. A second traveller then tries to grab M3 too -- the
PROMPT  system rejects synchronously with ORA-20604 (no AQ wait at all).
PROMPT
PAUSE  Press ENTER to clean up any previous demo data and start setup...

-- =============================================================================
-- Step 1: Cleanup any previous run of this demo
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_DBL')]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_DBL')]');
  silent_delete(q'[DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_DBL')]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier = 'DEMO_DBL']');
  silent_delete(q'[DELETE FROM ResourceInstance WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_DBL_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity   WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_DBL_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset   WHERE name = 'DEMO_DBL_ASSET']');
  silent_delete(q'[DELETE FROM Users           WHERE name IN ('DEMO_DBL_USER_A','DEMO_DBL_USER_B')]');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_DBL_Business']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 1: previous demo data cleaned.');
END;
/

DELETE FROM DebugLog;
COMMIT;

-- =============================================================================
-- Step 2: Reference data + 3 Business seats on one asset, 2 users, 1 context
-- =============================================================================
DECLARE
  v_asset_id NUMBER;
  v_cat_id   NUMBER;
  v_i        NUMBER;
BEGIN
  BEGIN ResourceManagement_Data.AddResourceStatus('reserved',  'Held');     EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('confirmed', 'Confirmed');EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('cancelled', 'Cancelled');EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceInstanceStatus('available', 'Available'); EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;

  ResourceManagement_Data.AddResourceCategory('DEMO_DBL_Business', NULL, 'pool');
  ResourceManagement_Data.AddUser('DEMO_DBL_USER_A');
  ResourceManagement_Data.AddUser('DEMO_DBL_USER_B');
  ResourceManagement_Data.AddResourceAsset('DEMO_DBL_ASSET', NULL, 'active');

  SELECT id INTO v_asset_id FROM ResourceAsset    WHERE name = 'DEMO_DBL_ASSET';
  SELECT id INTO v_cat_id   FROM ResourceCategory WHERE name = 'DEMO_DBL_Business';

  ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_cat_id, 3);
  FOR v_i IN 1..3 LOOP
    ResourceManagement_Data.AddResourceInstance(v_asset_id, v_cat_id, 'M' || v_i, 'available');
  END LOOP;
  ResourceManagement_Data.AddAllocationContext(v_asset_id, 'DEMO_DBL', SYSDATE + 1, SYSDATE + 2);
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 2: setup complete (3 seats M1..M3, 2 users, context DEMO_DBL).');
END;
/

PROMPT
PROMPT  Step 2 done. 3 seats available, no allocations yet.
PROMPT
PAUSE  Press ENTER to inspect the initial state...

-- =============================================================================
-- Step 3: Show pre-state
-- =============================================================================
PROMPT
PROMPT === Resource instances (3 available seats) ===

SELECT ri.id, ri.instance_identifier, ri.status
  FROM ResourceInstance ri
  JOIN ResourceAsset    ra ON ri.asset_id = ra.id
 WHERE ra.name = 'DEMO_DBL_ASSET'
 ORDER BY ri.id;

PROMPT === Capacity (active_count = 0) ===

SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_DBL';

PROMPT
PAUSE  Press ENTER to see the Session B publish block...

-- =============================================================================
-- Step 4: Print exact Session B block, then run the first (blocking) reservation
-- =============================================================================
PROMPT
PROMPT =============================================================================
PROMPT   COPY THIS BLOCK INTO A SECOND SQL*Plus / SQLcl SESSION (Session B).
PROMPT   DO NOT RUN IT YET. Come back here and press ENTER first; this script
PROMPT   will then BLOCK on the AQ queue and Session B can run the publish.
PROMPT =============================================================================
PROMPT
PROMPT   -- Session B: confirm M3 for USER_A -----------------------------------
PROMPT   DECLARE
PROMPT     v_user_id NUMBER;
PROMPT     v_inst_id NUMBER;
PROMPT   BEGIN
PROMPT     SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_DBL_USER_A';
PROMPT     SELECT ri.id INTO v_inst_id
PROMPT       FROM ResourceInstance ri
PROMPT       JOIN ResourceAsset    ra ON ri.asset_id = ra.id
PROMPT      WHERE ra.name = 'DEMO_DBL_ASSET'
PROMPT        AND ri.instance_identifier = 'M3';
PROMPT     ResourceManagement.publish_reservation_event(
PROMPT       p_resource_id        => v_inst_id,
PROMPT       p_context_identifier => 'DEMO_DBL',
PROMPT       p_user_id            => v_user_id,
PROMPT       p_action             => 'CONFIRM'   -- or 'CANCEL'
PROMPT     );
PROMPT   END;
PROMPT   /
PROMPT
PROMPT   -----------------------------------------------------------------------
PROMPT
PAUSE  Session B ready? Press ENTER -- THIS WILL BLOCK until Session B publishes.

PROMPT
PROMPT  *** Session A: USER_A calls MakeReservation(instance=M3). Blocking... ***
PROMPT

DECLARE
  v_user_id    NUMBER;
  v_inst_id    NUMBER;
  v_journal_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_DBL_USER_A';
  SELECT ri.id INTO v_inst_id
    FROM ResourceInstance ri
    JOIN ResourceAsset    ra ON ri.asset_id = ra.id
   WHERE ra.name = 'DEMO_DBL_ASSET'
     AND ri.instance_identifier = 'M3';

  ResourceManagement.MakeReservation(
    p_context_identifier => 'DEMO_DBL',
    p_user_id            => v_user_id,
    p_instance_id        => v_inst_id,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_journal_id
  );
  DBMS_OUTPUT.PUT_LINE('Step 4: USER_A reservation returned. journal_id=' || NVL(TO_CHAR(v_journal_id), 'NULL'));
END;
/

PROMPT
PROMPT  Unblocked. M3 is now held by USER_A.
PROMPT
PAUSE  Press ENTER to inspect the state after the first reservation...

-- =============================================================================
-- Step 5: Show intermediate state (M3 confirmed for USER_A)
-- =============================================================================
PROMPT === AllocationJournal entries ===

SELECT aj.id, aj.status, u.name AS user_name, ri.instance_identifier
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
  LEFT JOIN Users u             ON aj.user_id = u.id
  LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_DBL'
 ORDER BY aj.id;

PROMPT === CurrentAllocations ===

SELECT u.name AS user_name, ri.instance_identifier, ca.status, ca.journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  LEFT JOIN Users u             ON ca.user_id = u.id
  LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_DBL';

PROMPT
PAUSE  Press ENTER to let USER_B try to grab M3 too (expected: ORA-20604)...

-- =============================================================================
-- Step 6: USER_B attempts to reserve M3 -> rejected synchronously (-20604)
-- =============================================================================
PROMPT
PROMPT  *** Session A: USER_B calls MakeReservation(instance=M3).             ***
PROMPT  ***            The double-book check fires BEFORE the AQ dequeue, so  ***
PROMPT  ***            this call returns immediately with ORA-20604.          ***
PROMPT

DECLARE
  v_user_id    NUMBER;
  v_inst_id    NUMBER;
  v_journal_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_DBL_USER_B';
  SELECT ri.id INTO v_inst_id
    FROM ResourceInstance ri
    JOIN ResourceAsset    ra ON ri.asset_id = ra.id
   WHERE ra.name = 'DEMO_DBL_ASSET'
     AND ri.instance_identifier = 'M3';

  BEGIN
    ResourceManagement.MakeReservation(
      p_context_identifier => 'DEMO_DBL',
      p_user_id            => v_user_id,
      p_instance_id        => v_inst_id,
      p_timeout_minutes    => 5,
      p_new_journal_id     => v_journal_id
    );
    DBMS_OUTPUT.PUT_LINE('Step 6: UNEXPECTED -- second MakeReservation did NOT raise.');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20604 THEN
        DBMS_OUTPUT.PUT_LINE('Step 6: EXPECTED ORA-20604 received: ' || SUBSTR(SQLERRM, 1, 200));
      ELSE
        DBMS_OUTPUT.PUT_LINE('Step 6: Unexpected error ' || SQLCODE || ': ' || SQLERRM);
      END IF;
  END;
END;
/

PROMPT
PAUSE  Press ENTER to inspect the final state...

-- =============================================================================
-- Step 7: Show final state (one allocation, no new journal for USER_B)
-- =============================================================================
PROMPT === AllocationJournal entries (only USER_A should appear) ===

SELECT aj.id, aj.status, u.name AS user_name, ri.instance_identifier
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
  LEFT JOIN Users u             ON aj.user_id = u.id
  LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_DBL'
 ORDER BY aj.id;

PROMPT === Capacity (still exactly 1 active seat) ===

SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_DBL';

PROMPT === Recent DebugLog (look for the double-book rejection) ===

SELECT id, SUBSTR(message, 1, 140) AS message
  FROM DebugLogSorted
 FETCH FIRST 10 ROWS ONLY;

PROMPT
PAUSE  Press ENTER to tear down the demo data...

-- =============================================================================
-- Step 8: Teardown
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_DBL')]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_DBL')]');
  silent_delete(q'[DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_DBL')]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier = 'DEMO_DBL']');
  silent_delete(q'[DELETE FROM ResourceInstance WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_DBL_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity   WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_DBL_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset   WHERE name = 'DEMO_DBL_ASSET']');
  silent_delete(q'[DELETE FROM Users           WHERE name IN ('DEMO_DBL_USER_A','DEMO_DBL_USER_B')]');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_DBL_Business']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 8: teardown complete.');
END;
/

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 06 finished.
PROMPT =============================================================================
