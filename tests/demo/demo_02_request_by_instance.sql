-- =============================================================================
-- demo_02_request_by_instance.sql
-- =============================================================================
-- Interactive demo: reserve ONE specific resource instance.
--
-- Same "subscribing main transaction" pattern as demo_01, but for a SINGLE
-- instance (contained / pool mode dispatches to ReserveContained). Session A
-- blocks on RESERVATION_EVENTS_Q with correlation 'RES_<journal_id>' until
-- Session B calls publish_reservation_event with CONFIRM or CANCEL.
--
-- Run:    @demo_02_request_by_instance.sql      (in Session A)
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
SET DEFINE OFF
SET FEEDBACK ON
SET SQLBLANKLINES ON

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 02 - Reserve by Instance ID (single specific seat)
PROMPT =============================================================================
PROMPT
PROMPT  Scenario: the traveller picks seat BIZ2 from the seat map. Session A
PROMPT  reserves THAT exact instance and blocks until Session B confirms it.
PROMPT
PAUSE  Press ENTER to clean up any previous demo data and start setup...

-- =============================================================================
-- Step 1: Cleanup
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_INST')]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_INST')]');
  silent_delete(q'[DELETE FROM Capacity WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_INST')]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier = 'DEMO_INST']');
  silent_delete(q'[DELETE FROM ResourceInstance WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_INST_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity   WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_INST_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset   WHERE name = 'DEMO_INST_ASSET']');
  silent_delete(q'[DELETE FROM Users           WHERE name = 'DEMO_INST_USER']');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_INST_Business']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 1: previous demo data cleaned.');
END;
/

DELETE FROM DebugLog;
COMMIT;

-- =============================================================================
-- Step 2: Setup (3 seats so BIZ2 has neighbours)
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

  ResourceManagement_Data.AddResourceCategory('DEMO_INST_Business', NULL, 'pool');
  ResourceManagement_Data.AddUser('DEMO_INST_USER');
  ResourceManagement_Data.AddResourceAsset('DEMO_INST_ASSET', NULL, 'active');

  SELECT id INTO v_asset_id FROM ResourceAsset    WHERE name = 'DEMO_INST_ASSET';
  SELECT id INTO v_cat_id   FROM ResourceCategory WHERE name = 'DEMO_INST_Business';

  ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_cat_id, 3);
  FOR v_i IN 1..3 LOOP
    ResourceManagement_Data.AddResourceInstance(v_asset_id, v_cat_id, 'BIZ' || v_i, 'available');
  END LOOP;
  ResourceManagement_Data.AddAllocationContext(v_asset_id, 'DEMO_INST', SYSDATE + 1, SYSDATE + 2);
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 2: setup complete (3 instances BIZ1/BIZ2/BIZ3, context DEMO_INST).');
END;
/

PROMPT
PAUSE  Press ENTER to inspect the initial state...

-- =============================================================================
-- Step 3: Show pre-state
-- =============================================================================
PROMPT
PROMPT === Resource instances ===
SELECT ri.id, ri.instance_identifier, ri.status
  FROM ResourceInstance ri
  JOIN ResourceAsset    ra ON ri.asset_id = ra.id
 WHERE ra.name = 'DEMO_INST_ASSET'
 ORDER BY ri.id;

PROMPT === Capacity (active_count = 0) ===
SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_INST';

PROMPT
PAUSE  Press ENTER to see the Session B publish block...

-- =============================================================================
-- Step 4: Show Session B block + issue blocking MakeReservation on BIZ2
-- =============================================================================
PROMPT
PROMPT =============================================================================
PROMPT   COPY THIS BLOCK INTO A SECOND SESSION (Session B). Do NOT run it yet --
PROMPT   first press ENTER below so Session A starts to block.
PROMPT =============================================================================
PROMPT
PROMPT   -- Session B: confirm THE specific instance (BIZ2) --------------------
PROMPT   DECLARE
PROMPT     v_user_id  NUMBER;
PROMPT     v_inst_id  NUMBER;
PROMPT   BEGIN
PROMPT     SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_INST_USER';
PROMPT     SELECT ri.id INTO v_inst_id
PROMPT       FROM ResourceInstance ri
PROMPT       JOIN ResourceAsset    ra ON ri.asset_id = ra.id
PROMPT      WHERE ra.name = 'DEMO_INST_ASSET'
PROMPT        AND ri.instance_identifier = 'BIZ2';
PROMPT     ResourceManagement.publish_reservation_event(
PROMPT       p_resource_id        => v_inst_id,
PROMPT       p_context_identifier => 'DEMO_INST',
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
PROMPT  *** Session A: calling MakeReservation(instance=BIZ2). Blocking... ***
PROMPT

DECLARE
  v_user_id    NUMBER;
  v_inst_id    NUMBER;
  v_journal_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_INST_USER';
  SELECT ri.id INTO v_inst_id
    FROM ResourceInstance ri
    JOIN ResourceAsset    ra ON ri.asset_id = ra.id
   WHERE ra.name = 'DEMO_INST_ASSET'
     AND ri.instance_identifier = 'BIZ2';

  DBMS_OUTPUT.PUT_LINE('Step 4: requesting instance BIZ2 (id=' || v_inst_id || ') for user ' || v_user_id || '.');

  ResourceManagement.MakeReservation(
    p_context_identifier => 'DEMO_INST',
    p_user_id            => v_user_id,
    p_instance_id        => v_inst_id,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_journal_id
  );
  DBMS_OUTPUT.PUT_LINE('Step 4: MakeReservation returned. journal_id=' || NVL(TO_CHAR(v_journal_id), 'NULL'));
END;
/

PROMPT
PAUSE  Unblocked. Press ENTER to inspect the final state...

-- =============================================================================
-- Step 5: Show post-state
-- =============================================================================
PROMPT === AllocationJournal entries ===
SELECT aj.id, aj.status, ri.instance_identifier,
       SUBSTR(aj.metadata, 1, 120) AS metadata
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
  LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_INST'
 ORDER BY aj.id;

PROMPT === Capacity ===
SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_INST';

PROMPT === CurrentAllocations ===
SELECT ca.status, ri.instance_identifier, ca.journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext  ac ON ca.context_id = ac.id
  LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_INST'
 ORDER BY ri.instance_identifier;

PROMPT === Recent DebugLog ===
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
  silent_delete(q'[DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_INST')]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_INST')]');
  silent_delete(q'[DELETE FROM Capacity WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_INST')]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier = 'DEMO_INST']');
  silent_delete(q'[DELETE FROM ResourceInstance WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_INST_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity   WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_INST_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset   WHERE name = 'DEMO_INST_ASSET']');
  silent_delete(q'[DELETE FROM Users           WHERE name = 'DEMO_INST_USER']');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_INST_Business']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 6: teardown complete.');
END;
/

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 02 finished.
PROMPT =============================================================================
