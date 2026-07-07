-- =============================================================================
-- demo_07_time_conflict.sql
-- =============================================================================
-- Interactive demo: shared (direct-mode) resource time conflict (-20703).
--
-- A single shared meeting room is booked by USER_A for 10:00-11:00. USER_B
-- then tries to book the SAME room for an OVERLAPPING window (10:30-11:30).
-- MakeReservation rejects synchronously with ORA-20703 -- no AQ wait.
--
-- Two SQL*Plus sessions are required:
--   * Session A (this script): setup, first reservation (blocks), inspection,
--     second reservation (fails synchronously with -20703).
--   * Session B (operator):    publish CONFIRM for the first reservation.
--
-- Run:    @demo_07_time_conflict.sql      (in Session A)
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
SET DEFINE OFF
SET FEEDBACK ON
SET SQLBLANKLINES ON

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 07 - Shared resource time conflict (-20703)
PROMPT =============================================================================
PROMPT
PROMPT  Scenario: one shared meeting room (direct allocation).
PROMPT    Meeting1 (USER_A): tomorrow 10:00 - 11:00   -- this one wins.
PROMPT    Meeting2 (USER_B): tomorrow 10:30 - 11:30   -- overlaps with Meeting1
PROMPT                                                   => rejected (-20703).
PROMPT
PAUSE  Press ENTER to clean up any previous demo data and start setup...

-- =============================================================================
-- Step 1: Cleanup any previous run of this demo
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation
    WHERE context_id IN (SELECT id FROM AllocationContext
                          WHERE context_identifier IN ('DEMO_TC_Meeting1','DEMO_TC_Meeting2'))]');
  silent_delete(q'[DELETE FROM AllocationJournal
    WHERE context_id IN (SELECT id FROM AllocationContext
                          WHERE context_identifier IN ('DEMO_TC_Meeting1','DEMO_TC_Meeting2'))]');
  silent_delete(q'[DELETE FROM AllocationContext
    WHERE context_identifier IN ('DEMO_TC_Meeting1','DEMO_TC_Meeting2')]');
  silent_delete(q'[DELETE FROM ResourceInstance
    WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_TC_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset WHERE name = 'DEMO_TC_ASSET']');
  silent_delete(q'[DELETE FROM Users         WHERE name IN ('DEMO_TC_USER_A','DEMO_TC_USER_B')]');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_TC_Room']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 1: previous demo data cleaned.');
END;
/

DELETE FROM DebugLog;
COMMIT;

-- =============================================================================
-- Step 2: Reference data + 1 shared room (direct), 2 users, 2 contexts
-- =============================================================================
DECLARE
  v_asset_id NUMBER;
  v_cat_id   NUMBER;
  v_start1   DATE;
  v_end1     DATE;
  v_start2   DATE;
  v_end2     DATE;
BEGIN
  BEGIN ResourceManagement_Data.AddResourceStatus('reserved',  'Held');     EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('confirmed', 'Confirmed');EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('cancelled', 'Cancelled');EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceInstanceStatus('available', 'Available'); EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;

  ResourceManagement_Data.AddResourceCategory('DEMO_TC_Room', NULL, 'direct');
  ResourceManagement_Data.AddUser('DEMO_TC_USER_A');
  ResourceManagement_Data.AddUser('DEMO_TC_USER_B');
  ResourceManagement_Data.AddResourceAsset('DEMO_TC_ASSET', NULL, 'active');

  SELECT id INTO v_asset_id FROM ResourceAsset    WHERE name = 'DEMO_TC_ASSET';
  SELECT id INTO v_cat_id   FROM ResourceCategory WHERE name = 'DEMO_TC_Room';
  ResourceManagement_Data.AddResourceInstance(v_asset_id, v_cat_id, 'ROOM_42', 'available');

  v_start1 := TRUNC(SYSDATE) + 1 + 10/24;
  v_end1   := TRUNC(SYSDATE) + 1 + 11/24;
  v_start2 := TRUNC(SYSDATE) + 1 + 10.5/24;
  v_end2   := TRUNC(SYSDATE) + 1 + 11.5/24;
  ResourceManagement_Data.AddDirectAllocationContext('DEMO_TC_Meeting1', v_start1, v_end1);
  ResourceManagement_Data.AddDirectAllocationContext('DEMO_TC_Meeting2', v_start2, v_end2);
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 2: setup complete (ROOM_42, Meeting1 10:00-11:00, Meeting2 10:30-11:30).');
END;
/

PROMPT
PROMPT  Step 2 done. Two overlapping meetings, one shared room.
PROMPT
PAUSE  Press ENTER to inspect the initial state...

-- =============================================================================
-- Step 3: Show pre-state
-- =============================================================================
PROMPT
PROMPT === Contexts (start/end) ===

SELECT context_identifier,
       TO_CHAR(start_date, 'YYYY-MM-DD HH24:MI') AS starts,
       TO_CHAR(end_date,   'YYYY-MM-DD HH24:MI') AS ends
  FROM AllocationContext
 WHERE context_identifier IN ('DEMO_TC_Meeting1','DEMO_TC_Meeting2')
 ORDER BY context_identifier;

PROMPT === Resource instance (1 shared room) ===

SELECT ri.id, ri.instance_identifier, ri.status
  FROM ResourceInstance ri
  JOIN ResourceAsset    ra ON ri.asset_id = ra.id
 WHERE ra.name = 'DEMO_TC_ASSET';

PROMPT === No journals yet ===

SELECT COUNT(*) AS journals
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
 WHERE ac.context_identifier IN ('DEMO_TC_Meeting1','DEMO_TC_Meeting2');

PROMPT
PAUSE  Press ENTER to see the Session B publish block...

-- =============================================================================
-- Step 4: Print Session B block + run the first (blocking) reservation
-- =============================================================================
PROMPT
PROMPT =============================================================================
PROMPT   COPY THIS BLOCK INTO A SECOND SQL*Plus / SQLcl SESSION (Session B).
PROMPT   DO NOT RUN IT YET. Come back here and press ENTER first; this script
PROMPT   will then BLOCK on the AQ queue and Session B can run the publish.
PROMPT =============================================================================
PROMPT
PROMPT   -- Session B: confirm Meeting1 for USER_A ----------------------------
PROMPT   DECLARE
PROMPT     v_user_id NUMBER;
PROMPT     v_inst_id NUMBER;
PROMPT   BEGIN
PROMPT     SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_TC_USER_A';
PROMPT     SELECT ri.id INTO v_inst_id
PROMPT       FROM ResourceInstance ri
PROMPT       JOIN ResourceAsset    ra ON ri.asset_id = ra.id
PROMPT      WHERE ra.name = 'DEMO_TC_ASSET'
PROMPT        AND ri.instance_identifier = 'ROOM_42';
PROMPT     ResourceManagement.publish_reservation_event(
PROMPT       p_resource_id        => v_inst_id,
PROMPT       p_context_identifier => 'DEMO_TC_Meeting1',
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
PROMPT  *** Session A: USER_A books ROOM_42 for Meeting1 (10:00-11:00). Blocking... ***
PROMPT

DECLARE
  v_user_id    NUMBER;
  v_inst_id    NUMBER;
  v_journal_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_TC_USER_A';
  SELECT ri.id INTO v_inst_id
    FROM ResourceInstance ri
    JOIN ResourceAsset    ra ON ri.asset_id = ra.id
   WHERE ra.name = 'DEMO_TC_ASSET'
     AND ri.instance_identifier = 'ROOM_42';

  ResourceManagement.MakeReservation(
    p_context_identifier => 'DEMO_TC_Meeting1',
    p_user_id            => v_user_id,
    p_instance_id        => v_inst_id,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_journal_id
  );
  DBMS_OUTPUT.PUT_LINE('Step 4: USER_A / Meeting1 returned. journal_id=' || NVL(TO_CHAR(v_journal_id), 'NULL'));
END;
/

PROMPT
PROMPT  Unblocked. ROOM_42 is now held for Meeting1.
PROMPT
PAUSE  Press ENTER to inspect the state after the first booking...

-- =============================================================================
-- Step 5: Show intermediate state (Meeting1 holds ROOM_42)
-- =============================================================================
PROMPT === AllocationJournal entries ===

SELECT aj.id, aj.status, u.name AS user_name, ri.instance_identifier, ac.context_identifier
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
  LEFT JOIN Users u             ON aj.user_id = u.id
  LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
 WHERE ac.context_identifier IN ('DEMO_TC_Meeting1','DEMO_TC_Meeting2')
 ORDER BY aj.id;

PROMPT === Time-conflict probe for Meeting2 ===
PROMPT (CheckResourceTimeConflict returns the conflicting context_id if any)

SELECT ResourceManagement.CheckResourceTimeConflict(
         (SELECT ri.id FROM ResourceInstance ri JOIN ResourceAsset ra ON ri.asset_id = ra.id
            WHERE ra.name = 'DEMO_TC_ASSET' AND ri.instance_identifier = 'ROOM_42'),
         'DEMO_TC_Meeting2'
       ) AS conflict_context_id
  FROM DUAL;

PROMPT
PAUSE  Press ENTER to let USER_B try the overlapping Meeting2 (expected: ORA-20703)...

-- =============================================================================
-- Step 6: USER_B attempts the overlapping Meeting2 -> rejected (-20703)
-- =============================================================================
PROMPT
PROMPT  *** Session A: USER_B calls MakeReservation(ROOM_42, Meeting2).      ***
PROMPT  ***            The time-conflict check fires BEFORE the AQ dequeue,  ***
PROMPT  ***            so this call returns immediately with ORA-20703.      ***
PROMPT

DECLARE
  v_user_id    NUMBER;
  v_inst_id    NUMBER;
  v_journal_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_TC_USER_B';
  SELECT ri.id INTO v_inst_id
    FROM ResourceInstance ri
    JOIN ResourceAsset    ra ON ri.asset_id = ra.id
   WHERE ra.name = 'DEMO_TC_ASSET'
     AND ri.instance_identifier = 'ROOM_42';

  BEGIN
    ResourceManagement.MakeReservation(
      p_context_identifier => 'DEMO_TC_Meeting2',
      p_user_id            => v_user_id,
      p_instance_id        => v_inst_id,
      p_timeout_minutes    => 5,
      p_new_journal_id     => v_journal_id
    );
    DBMS_OUTPUT.PUT_LINE('Step 6: UNEXPECTED -- second MakeReservation did NOT raise.');
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -20703 THEN
        DBMS_OUTPUT.PUT_LINE('Step 6: EXPECTED ORA-20703 received: ' || SUBSTR(SQLERRM, 1, 200));
      ELSE
        DBMS_OUTPUT.PUT_LINE('Step 6: Unexpected error ' || SQLCODE || ': ' || SQLERRM);
      END IF;
  END;
END;
/

PROMPT
PAUSE  Press ENTER to inspect the final state...

-- =============================================================================
-- Step 7: Show final state (only Meeting1 has a journal)
-- =============================================================================
PROMPT === AllocationJournal entries ===

SELECT aj.id, aj.status, u.name AS user_name, ri.instance_identifier, ac.context_identifier
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
  LEFT JOIN Users u             ON aj.user_id = u.id
  LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
 WHERE ac.context_identifier IN ('DEMO_TC_Meeting1','DEMO_TC_Meeting2')
 ORDER BY aj.id;

PROMPT === CurrentAllocations (only Meeting1 should appear) ===

SELECT u.name AS user_name, ri.instance_identifier, ca.status, ac.context_identifier
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  LEFT JOIN Users u             ON ca.user_id = u.id
  LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
 WHERE ac.context_identifier IN ('DEMO_TC_Meeting1','DEMO_TC_Meeting2');

PROMPT === Recent DebugLog (look for the time-conflict rejection) ===

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
  silent_delete(q'[DELETE FROM ActiveAllocation
    WHERE context_id IN (SELECT id FROM AllocationContext
                          WHERE context_identifier IN ('DEMO_TC_Meeting1','DEMO_TC_Meeting2'))]');
  silent_delete(q'[DELETE FROM AllocationJournal
    WHERE context_id IN (SELECT id FROM AllocationContext
                          WHERE context_identifier IN ('DEMO_TC_Meeting1','DEMO_TC_Meeting2'))]');
  silent_delete(q'[DELETE FROM AllocationContext
    WHERE context_identifier IN ('DEMO_TC_Meeting1','DEMO_TC_Meeting2')]');
  silent_delete(q'[DELETE FROM ResourceInstance
    WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_TC_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset WHERE name = 'DEMO_TC_ASSET']');
  silent_delete(q'[DELETE FROM Users         WHERE name IN ('DEMO_TC_USER_A','DEMO_TC_USER_B')]');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_TC_Room']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 8: teardown complete.');
END;
/

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 07 finished.
PROMPT =============================================================================
