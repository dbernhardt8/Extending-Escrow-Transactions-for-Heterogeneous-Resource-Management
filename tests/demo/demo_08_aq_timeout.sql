-- =============================================================================
-- demo_08_aq_timeout.sql
-- =============================================================================
-- Interactive demo: AQ timeout safety net (1 minute).
--
-- ReserveByCategory reserves 2 seats and then waits on RESERVATION_EVENTS_Q
-- for a CONFIRM / CANCEL message. If nothing arrives within
-- p_timeout_minutes, the procedure auto-cancels the whole group, frees the
-- capacity and writes metadata.reason = 'timeout' on each journal entry.
--
-- Only ONE SQL*Plus session is strictly required: DO NOT publish from Session B.
-- Session A will block for ~1 minute, then return on its own.
--
-- A Session B 'early cancel' block is also printed for completeness -- you can
-- use it to short-circuit the timeout if you do not want to wait the full
-- minute. (You can also use 'CONFIRM' there to demonstrate the happy path.)
--
-- Run:    @demo_08_aq_timeout.sql      (in Session A)
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
SET DEFINE OFF
SET FEEDBACK ON
SET SQLBLANKLINES ON

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 08 - AQ timeout (1 min): no publisher -> auto-cancel
PROMPT =============================================================================
PROMPT
PROMPT  Scenario: a flight has 5 Business seats. The traveller asks for 2.
PROMPT  ReserveByCategory reserves them and waits 1 minute for an AQ message
PROMPT  that NEVER arrives. The subscriber wakes up on timeout, cancels the
PROMPT  whole group, and frees the 2 seats. Each journal entry receives
PROMPT  metadata.reason = 'timeout'.
PROMPT
PAUSE  Press ENTER to clean up any previous demo data and start setup...

-- =============================================================================
-- Step 1: Cleanup any previous run of this demo
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_TO')]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_TO')]');
  silent_delete(q'[DELETE FROM Capacity          WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_TO')]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier = 'DEMO_TO']');
  silent_delete(q'[DELETE FROM ResourceInstance  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_TO_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity    WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_TO_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset    WHERE name = 'DEMO_TO_ASSET']');
  silent_delete(q'[DELETE FROM Users            WHERE name = 'DEMO_TO_USER']');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_TO_Business']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 1: previous demo data cleaned.');
END;
/

DELETE FROM DebugLog;
COMMIT;

-- =============================================================================
-- Step 2: Reference data + 5 Business seats on one asset, 1 user, 1 context
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

  ResourceManagement_Data.AddResourceCategory('DEMO_TO_Business', NULL, 'pool');
  ResourceManagement_Data.AddUser('DEMO_TO_USER');
  ResourceManagement_Data.AddResourceAsset('DEMO_TO_ASSET', NULL, 'active');

  SELECT id INTO v_asset_id FROM ResourceAsset    WHERE name = 'DEMO_TO_ASSET';
  SELECT id INTO v_cat_id   FROM ResourceCategory WHERE name = 'DEMO_TO_Business';

  ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_cat_id, 5);
  FOR v_i IN 1..5 LOOP
    ResourceManagement_Data.AddResourceInstance(v_asset_id, v_cat_id, 'BIZ' || v_i, 'available');
  END LOOP;
  ResourceManagement_Data.AddAllocationContext(v_asset_id, 'DEMO_TO', SYSDATE + 1, SYSDATE + 2);
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 2: setup complete (5 seats BIZ1..BIZ5, user DEMO_TO_USER, context DEMO_TO).');
END;
/

PROMPT
PROMPT  Step 2 done. The pool is full (5/5) and unused.
PROMPT
PAUSE  Press ENTER to inspect the initial state...

-- =============================================================================
-- Step 3: Show pre-state
-- =============================================================================
PROMPT
PROMPT === Capacity (total_capacity / active_count) ===

SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_TO';

PROMPT === No journals, no allocations yet ===

SELECT COUNT(*) AS journals
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
 WHERE ac.context_identifier = 'DEMO_TO';

PROMPT
PAUSE  Press ENTER to see the (optional) Session B early-cancel block...

-- =============================================================================
-- Step 4: (Optional) Session B early-decision block + blocking call
-- =============================================================================
PROMPT
PROMPT =============================================================================
PROMPT   THIS DEMO IS DESIGNED TO TIME OUT. The Session A call below will block
PROMPT   ~1 minute, then auto-cancel both journals.
PROMPT
PROMPT   If you do NOT want to wait the full minute, you may run the block below
PROMPT   in a second SQL*Plus / SQLcl session (Session B) BEFORE the minute ends.
PROMPT   Use 'CANCEL' for the same auto-cancel outcome (just faster), or
PROMPT   'CONFIRM' to flip the demo into a happy-path confirmation.
PROMPT =============================================================================
PROMPT
PROMPT   -- Session B: optional early decision ---------------------------------
PROMPT   DECLARE
PROMPT     v_user_id NUMBER;
PROMPT   BEGIN
PROMPT     SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_TO_USER';
PROMPT     ResourceManagement.publish_group_reservation_event(
PROMPT       p_context_identifier => 'DEMO_TO',
PROMPT       p_user_id            => v_user_id,
PROMPT       p_category_name      => 'DEMO_TO_Business',
PROMPT       p_action             => 'CANCEL'   -- or 'CONFIRM'
PROMPT     );
PROMPT   END;
PROMPT   /
PROMPT
PROMPT   -----------------------------------------------------------------------
PROMPT
PAUSE  Press ENTER to issue the ReserveByCategory call (timeout=1 min, blocking)...

PROMPT
PROMPT  *** Session A: ReserveByCategory(qty=2, timeout_minutes=1). Blocking... ***
PROMPT  *** Expected: returns after ~1 minute with both journals cancelled.    ***
PROMPT

DECLARE
  v_user_id     NUMBER;
  v_journal_ids SYS.ODCINUMBERLIST;
  v_t0          TIMESTAMP;
  v_t1          TIMESTAMP;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_TO_USER';
  v_t0 := SYSTIMESTAMP;
  ResourceManagement.ReserveByCategory(
    p_context_identifier => 'DEMO_TO',
    p_category_name      => 'DEMO_TO_Business',
    p_user_id            => v_user_id,
    p_quantity           => 2,
    p_timeout_minutes    => 1,
    p_new_journal_ids    => v_journal_ids
  );
  v_t1 := SYSTIMESTAMP;
  DBMS_OUTPUT.PUT_LINE('Step 4: ReserveByCategory returned after ' ||
    EXTRACT(SECOND FROM (v_t1 - v_t0)) || ' s with ' ||
    NVL(v_journal_ids.COUNT, 0) || ' journal id(s).');
END;
/

PROMPT
PROMPT  Unblocked. Inspect the journals: both should be cancelled.
PROMPT
PAUSE  Press ENTER to inspect the final journal / allocation state...

-- =============================================================================
-- Step 5: Show post-state (journals cancelled, capacity restored, no allocations)
-- =============================================================================
PROMPT
PROMPT === AllocationJournal entries (newest first) ===

SELECT aj.id,
       aj.status,
       ri.instance_identifier,
       JSON_VALUE(aj.metadata, '$.reason')                 AS reason,
       JSON_VALUE(aj.metadata, '$.group_leader_journal_id') AS leader,
       JSON_VALUE(aj.metadata, '$.group_size')              AS grp_size
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
  LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_TO'
 ORDER BY aj.id DESC;

PROMPT === Capacity now (active_count should be 0 again) ===

SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_TO';

PROMPT === CurrentAllocations (should be empty) ===

SELECT ca.status, ri.instance_identifier, ca.journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext  ac ON ca.context_id = ac.id
  LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_TO'
 ORDER BY ri.instance_identifier;

PROMPT === Recent DebugLog (look for 'timeout' messages from the subscriber) ===

SELECT id, SUBSTR(message, 1, 140) AS message
  FROM DebugLogSorted
 FETCH FIRST 15 ROWS ONLY;

PROMPT
PAUSE  Press ENTER to tear down the demo data...

-- =============================================================================
-- Step 6: Teardown
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_TO')]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_TO')]');
  silent_delete(q'[DELETE FROM Capacity          WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_TO')]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier = 'DEMO_TO']');
  silent_delete(q'[DELETE FROM ResourceInstance  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_TO_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity    WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_TO_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset    WHERE name = 'DEMO_TO_ASSET']');
  silent_delete(q'[DELETE FROM Users            WHERE name = 'DEMO_TO_USER']');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_TO_Business']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 6: teardown complete.');
END;
/

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 08 finished.
PROMPT =============================================================================
