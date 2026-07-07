-- =============================================================================
-- demo_01_request_by_category.sql
-- =============================================================================
-- Interactive demo: reserve N seats from a category pool.
--
-- Two SQL*Plus sessions are required:
--   * Session A (this script): runs setup, shows state, issues the blocking
--     ResourceManagement.MakeReservation(category, quantity) call.
--   * Session B (operator):    when prompted, copy/paste the publish block
--     printed below to confirm (or cancel) the whole group.
--
-- Run:    @demo_01_request_by_category.sql      (in Session A)
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
SET DEFINE OFF
SET FEEDBACK ON
SET SQLBLANKLINES ON

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 01 - Reserve by Category (atomic multi-seat reservation)
PROMPT =============================================================================
PROMPT
PROMPT  Scenario: a flight has 4 Business seats. The traveller asks for 2 at once.
PROMPT  Session A blocks on the reservation event queue until Session B confirms
PROMPT  (or cancels) the whole group via publish_group_reservation_event.
PROMPT
PAUSE  Press ENTER to clean up any previous demo data and start setup...

-- =============================================================================
-- Step 1: Cleanup any previous run of this demo
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_CAT')]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_CAT')]');
  silent_delete(q'[DELETE FROM Capacity WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_CAT')]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier = 'DEMO_CAT']');
  silent_delete(q'[DELETE FROM ResourceInstance WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_CAT_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity   WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_CAT_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset   WHERE name = 'DEMO_CAT_ASSET']');
  silent_delete(q'[DELETE FROM Users           WHERE name = 'DEMO_CAT_USER']');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_CAT_Business']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 1: previous demo data cleaned.');
END;
/

DELETE FROM DebugLog;
COMMIT;

-- =============================================================================
-- Step 2: Reference data + 4 Business seats on one asset, 1 user, 1 context
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

  ResourceManagement_Data.AddResourceCategory('DEMO_CAT_Business', NULL, 'pool');
  ResourceManagement_Data.AddUser('DEMO_CAT_USER');
  ResourceManagement_Data.AddResourceAsset('DEMO_CAT_ASSET', NULL, 'active');

  SELECT id INTO v_asset_id FROM ResourceAsset    WHERE name = 'DEMO_CAT_ASSET';
  SELECT id INTO v_cat_id   FROM ResourceCategory WHERE name = 'DEMO_CAT_Business';

  ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_cat_id, 4);
  FOR v_i IN 1..4 LOOP
    ResourceManagement_Data.AddResourceInstance(v_asset_id, v_cat_id, 'BIZ' || v_i, 'available');
  END LOOP;
  ResourceManagement_Data.AddAllocationContext(v_asset_id, 'DEMO_CAT', SYSDATE + 1, SYSDATE + 2);
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 2: setup complete (DEMO_CAT_ASSET, DEMO_CAT_Business, 4 seats, context DEMO_CAT).');
END;
/

PROMPT
PROMPT  Step 2 done. The category pool is fully empty and ready.
PROMPT
PAUSE  Press ENTER to inspect the initial state...

-- =============================================================================
-- Step 3: Show pre-state (capacity, instances, no allocations yet)
-- =============================================================================
PROMPT
PROMPT === Capacity (total_capacity / active_count) ===

SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_CAT'
 ORDER BY rc.name;

PROMPT === Resource instances (4 available seats) ===

SELECT ri.id, ri.instance_identifier, ri.status
  FROM ResourceInstance ri
  JOIN ResourceAsset    ra ON ri.asset_id = ra.id
 WHERE ra.name = 'DEMO_CAT_ASSET'
 ORDER BY ri.id;

PROMPT === No journals, no allocations yet ===

SELECT COUNT(*) AS journals
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
 WHERE ac.context_identifier = 'DEMO_CAT';

PROMPT
PAUSE  Press ENTER to see the ReservationRequest (Session A will block soon)...

-- =============================================================================
-- Step 4: Print exact Session B block, then block the call
-- =============================================================================
PROMPT Workflow will now request 2 seats from the Business Category.
PROMPT ResourceManagement.MakeReservation(
PROMPT    p_context_identifier => 'DEMO_CAT',
PROMPT    p_user_id            => v_user_id,
PROMPT    p_category_name      => 'DEMO_CAT_Business',
PROMPT    p_quantity           => 2,
PROMPT    p_timeout_minutes    => 5,
PROMPT    p_new_journal_id     => v_group_leader);
PROMPT
PROMPT   -----------------------------------------------------------------------
PROMPT
PAUSE  Session B ready? Press ENTER -- THIS WILL BLOCK until Session B publishes.

PROMPT
PROMPT  *** Session A: calling MakeReservation(category=DEMO_CAT_Business, quantity=2). Blocking... ***
PROMPT

DECLARE
  v_user_id      NUMBER;
  v_group_leader NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_CAT_USER';
  ResourceManagement.MakeReservation(
    p_context_identifier => 'DEMO_CAT',
    p_user_id            => v_user_id,
    p_category_name      => 'DEMO_CAT_Business',
    p_quantity           => 2,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_group_leader
  );
  DBMS_OUTPUT.PUT_LINE('Step 4: MakeReservation returned. group_leader_journal_id=' || NVL(TO_CHAR(v_group_leader), 'NULL'));
END;
/

PROMPT
PROMPT  Unblocked. The Session B event has been processed.
PROMPT
PAUSE  Press ENTER to inspect the final journal / allocation state...

-- =============================================================================
-- Step 5: Show post-state (journals, capacity, current allocations)
-- =============================================================================
PROMPT
PROMPT === AllocationJournal entries (newest first) ===

SELECT aj.id, aj.status, ri.instance_identifier,
       JSON_VALUE(aj.metadata, '$.group_leader_journal_id') AS leader,
       JSON_VALUE(aj.metadata, '$.group_size')              AS grp_size
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
  LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_CAT'
 ORDER BY aj.id DESC;

PROMPT === Capacity now (active_count should reflect kept seats) ===

SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_CAT';

PROMPT === CurrentAllocations (live state per instance) ===

SELECT ca.status, ri.instance_identifier, ca.journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext  ac ON ca.context_id = ac.id
  LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_CAT'
 ORDER BY ri.instance_identifier;

PROMPT === Recent DebugLog (last 10 lines) ===

SELECT id, SUBSTR(message, 1, 140) AS message
  FROM DebugLogSorted
 FETCH FIRST 10 ROWS ONLY;

PROMPT
PAUSE  Press ENTER to tear down the demo data...

-- =============================================================================
-- Step 6: Teardown
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_CAT')]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_CAT')]');
  silent_delete(q'[DELETE FROM Capacity WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_CAT')]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier = 'DEMO_CAT']');
  silent_delete(q'[DELETE FROM ResourceInstance WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_CAT_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity   WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_CAT_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset   WHERE name = 'DEMO_CAT_ASSET']');
  silent_delete(q'[DELETE FROM Users           WHERE name = 'DEMO_CAT_USER']');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_CAT_Business']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 6: teardown complete.');
END;
/

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 01 finished.
PROMPT =============================================================================
