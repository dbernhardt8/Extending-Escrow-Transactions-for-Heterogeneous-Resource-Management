-- =============================================================================
-- demo_09_maintenance_overlap_contained.sql
-- =============================================================================
-- Interactive demo: maintenance overlap on a pool/category flight.
--
-- Two SQL*Plus / SQLcl sessions are required for the reservation step:
--   * Session A (this script): setup, reserve 2 seats, then maintenance logic.
--   * Session B (operator):      when prompted, publish CONFIRM for the group.
--
-- Run:    @demo_09_maintenance_overlap_contained.sql   (in Session A)
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
SET DEFINE OFF
SET FEEDBACK ON
SET SQLBLANKLINES ON

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 09 - Maintenance overlap (contained / category pool)
PROMPT =============================================================================
PROMPT
PROMPT  Scenario:
PROMPT    1) Flight A is created and 2 Business seats are reserved+confirmed.
PROMPT    2) A maintenance window overlaps Flight A for those 2 seat instances.
PROMPT    3) Those seats become blocked retroactively on Flight A.
PROMPT    4) A new overlapping normal flight on the same asset is rejected (-20302).
PROMPT    5) Flight C (no overlap with A, inside maintenance) auto-blocks same seats.
PROMPT
PAUSE  Press ENTER to clean up any previous demo data and start setup...

-- =============================================================================
-- Step 1: Cleanup
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation WHERE context_id IN (
    SELECT id FROM AllocationContext WHERE context_identifier IN (
      'DEMO_MAINT_Flight_A','DEMO_MAINT_Flight_B','DEMO_MAINT_Flight_C','DEMO_MAINT_Period_1'
    ))]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (
    SELECT id FROM AllocationContext WHERE context_identifier IN (
      'DEMO_MAINT_Flight_A','DEMO_MAINT_Flight_B','DEMO_MAINT_Flight_C','DEMO_MAINT_Period_1'
    ))]');
  silent_delete(q'[DELETE FROM Capacity WHERE context_id IN (
    SELECT id FROM AllocationContext WHERE context_identifier IN (
      'DEMO_MAINT_Flight_A','DEMO_MAINT_Flight_B','DEMO_MAINT_Flight_C','DEMO_MAINT_Period_1'
    ))]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier IN (
    'DEMO_MAINT_Flight_A','DEMO_MAINT_Flight_B','DEMO_MAINT_Flight_C','DEMO_MAINT_Period_1'
  )]');
  silent_delete(q'[DELETE FROM ResourceInstance WHERE asset_id IN (
    SELECT id FROM ResourceAsset WHERE name = 'DEMO_MAINT_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity WHERE asset_id IN (
    SELECT id FROM ResourceAsset WHERE name = 'DEMO_MAINT_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset WHERE name = 'DEMO_MAINT_ASSET']');
  silent_delete(q'[DELETE FROM Users WHERE name = 'DEMO_MAINT_USER']');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_MAINT_Business']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 1: previous demo data cleaned.');
END;
/

DELETE FROM DebugLog;
COMMIT;

-- =============================================================================
-- Step 2: Reference data + asset + 10 seats + Flight A
-- =============================================================================
DECLARE
  v_asset_id NUMBER;
  v_cat_id   NUMBER;
  v_i        NUMBER;
  v_start_a  DATE := TRUNC(SYSDATE) + 10 + 10/24;
  v_end_a    DATE := TRUNC(SYSDATE) + 10 + 12/24;
BEGIN
  BEGIN ResourceManagement_Data.AddResourceStatus('reserved',  'Held');      EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('confirmed', 'Confirmed'); EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('cancelled', 'Cancelled'); EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('blocked',   'Blocked');   EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceInstanceStatus('available', 'Available'); EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;

  ResourceManagement_Data.AddResourceCategory('DEMO_MAINT_Business', 'Maintenance overlap demo', 'pool');
  ResourceManagement_Data.AddUser('DEMO_MAINT_USER');
  ResourceManagement_Data.AddResourceAsset('DEMO_MAINT_ASSET', NULL, 'active');

  SELECT id INTO v_asset_id FROM ResourceAsset    WHERE name = 'DEMO_MAINT_ASSET';
  SELECT id INTO v_cat_id   FROM ResourceCategory WHERE name = 'DEMO_MAINT_Business';

  ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_cat_id, 10);
  FOR v_i IN 1..10 LOOP
    ResourceManagement_Data.AddResourceInstance(v_asset_id, v_cat_id, 'M' || v_i, 'available');
  END LOOP;

  ResourceManagement_Data.AddAllocationContext(
    p_asset_id           => v_asset_id,
    p_context_identifier => 'DEMO_MAINT_Flight_A',
    p_start_date         => v_start_a,
    p_end_date           => v_end_a,
    p_metadata           => '{"context_type":"normal"}'
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 2: setup complete (10 seats, Flight A).');
END;
/

PROMPT
PROMPT  Step 2 done. Flight A is ready with an empty category pool.
PROMPT
PAUSE  Press ENTER to inspect the initial state...

-- =============================================================================
-- Step 3: Pre-state
-- =============================================================================
PROMPT === Capacity (Flight A) ===

SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_MAINT_Flight_A';

PROMPT === Instances (M1..M10) ===

SELECT ri.id, ri.instance_identifier, ri.status
  FROM ResourceInstance ri
  JOIN ResourceAsset    ra ON ri.asset_id = ra.id
 WHERE ra.name = 'DEMO_MAINT_ASSET'
 ORDER BY ri.id;

PROMPT
PAUSE  Press ENTER to see the ReservationRequest (Session A will block soon)...

PROMPT  ResourceManagement.MakeReservation(
PROMPT    p_context_identifier => 'DEMO_MAINT_Flight_A',
PROMPT    p_user_id            => v_user_id,
PROMPT    p_category_name      => 'DEMO_MAINT_Business',
PROMPT    p_quantity           => 2,
PROMPT    p_timeout_minutes    => 5,
PROMPT    p_new_journal_id     => v_group_leader);
PROMPT
PROMPT *** Session A: MakeReservation(category=DEMO_MAINT_Business, quantity=2). Blocking... ***

DECLARE
  v_user_id      NUMBER;
  v_group_leader NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_MAINT_USER';
  ResourceManagement.MakeReservation(
    p_context_identifier => 'DEMO_MAINT_Flight_A',
    p_user_id            => v_user_id,
    p_category_name      => 'DEMO_MAINT_Business',
    p_quantity           => 2,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_group_leader
  );
  DBMS_OUTPUT.PUT_LINE('Step 4: MakeReservation returned. group_leader_journal_id=' ||
                       NVL(TO_CHAR(v_group_leader), 'NULL'));
END;
/

PROMPT
PROMPT  Unblocked. Two seats should now be confirmed on Flight A.
PROMPT
PAUSE  Press ENTER to continue with maintenance overlap steps...

-- =============================================================================
-- Step 5: Show confirmed seats on Flight A (these will be put under maintenance)
-- =============================================================================
PROMPT === CurrentAllocations on Flight A (expect 2 confirmed seats) ===

SELECT ri.instance_identifier, ca.status, ca.journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext  ac ON ca.context_id = ac.id
  JOIN ResourceInstance   ri ON ri.id = ca.resource_instance_id
 WHERE ac.context_identifier = 'DEMO_MAINT_Flight_A'
 ORDER BY ri.instance_identifier;

PROMPT
PAUSE  Press ENTER to create overlapping maintenance period for those 2 instances...

-- =============================================================================
-- Step 6: Create maintenance context (retroactive block on Flight A)
-- =============================================================================
PROMPT API CALL to create maintenance context and system will auto-block the 2 confirmed seats on Flight A:

PROMPT ResourceManagement_Data.AddAllocationContext(
PROMPT    p_asset_id           => v_asset_id,
PROMPT    p_context_identifier => 'DEMO_MAINT_Period_1',
PROMPT    p_start_date         => v_start_m, -- 11:00 am
PROMPT    p_end_date           => v_end_m, -- 01:00 pm
PROMPT    p_metadata           => '{"context_type":"maintenance","resource_instance_ids":' || v_instance_ids || '}');

PAUSE Press ENTER to execute the maintenance context creation...

DECLARE
  v_asset_id   NUMBER;
  v_start_m    DATE := TRUNC(SYSDATE) + 10 + 11/24;
  v_end_m      DATE := TRUNC(SYSDATE) + 10 + 13/24;
  v_instance_ids CLOB;
BEGIN
  SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'DEMO_MAINT_ASSET';

  SELECT '[' || LISTAGG(ri.id, ',') WITHIN GROUP (ORDER BY ri.id) || ']'
    INTO v_instance_ids
    FROM CurrentAllocations ca
    JOIN AllocationContext  ac ON ca.context_id = ac.id
    JOIN ResourceInstance   ri ON ri.id = ca.resource_instance_id
   WHERE ac.context_identifier = 'DEMO_MAINT_Flight_A'
     AND ca.status IN ('confirmed', 'reserved');

  IF v_instance_ids IS NULL OR v_instance_ids = '[]' THEN
    RAISE_APPLICATION_ERROR(-20999,
      'No reserved seats on Flight A. Complete Step 4 and Session B CONFIRM first.');
  END IF;

  ResourceManagement_Data.AddAllocationContext(
    p_asset_id           => v_asset_id,
    p_context_identifier => 'DEMO_MAINT_Period_1',
    p_start_date         => v_start_m,
    p_end_date           => v_end_m,
    p_metadata           => '{"context_type":"maintenance","resource_instance_ids":' || v_instance_ids || '}'
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 6: maintenance context created for instances ' || v_instance_ids);
END;
/

PROMPT === Flight A after maintenance (expect those seats blocked) ===

SELECT ri.instance_identifier, ca.status, ca.user_id
  FROM CurrentAllocations ca
  JOIN AllocationContext  ac ON ca.context_id = ac.id
  JOIN ResourceInstance   ri ON ri.id = ca.resource_instance_id
 WHERE ac.context_identifier = 'DEMO_MAINT_Flight_A'
 ORDER BY ri.instance_identifier;

PROMPT
PAUSE  Press ENTER to try creating overlapping Flight B (expect ORA-20302)...

-- =============================================================================
-- Step 7: Overlapping normal flight B on same asset -> expect -20302
-- =============================================================================

PROMPT API CALL to create an overlapping normal flight B (expect ORA-20302):

PROMPT ResourceManagement_Data.AddAllocationContext(
PROMPT    p_asset_id           => v_asset_id,
PROMPT    p_context_identifier => 'DEMO_MAINT_Period_1',
PROMPT    p_start_date         => v_start_m, -- 11:30 am
PROMPT    p_end_date           => v_end_m, -- 01:30 pm
PROMPT    p_metadata           => '{"context_type":"maintenance","resource_instance_ids":' || v_instance_ids || '}');

PAUSE Press ENTER to execute the overlapping Flight B creation...

DECLARE
  v_asset_id NUMBER;
  v_start_b  DATE := TRUNC(SYSDATE) + 10 + 11.5/24;
  v_end_b    DATE := TRUNC(SYSDATE) + 10 + 12.5/24;
BEGIN
  SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'DEMO_MAINT_ASSET';
  ResourceManagement_Data.AddAllocationContext(
    p_asset_id           => v_asset_id,
    p_context_identifier => 'DEMO_MAINT_Flight_B',
    p_start_date         => v_start_b,
    p_end_date           => v_end_b,
    p_metadata           => '{"context_type":"normal"}'
  );
  DBMS_OUTPUT.PUT_LINE('Step 7: UNEXPECTED - Flight B was created.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -20302 THEN
      DBMS_OUTPUT.PUT_LINE('Step 7: EXPECTED ORA-20302 - overlapping normal flight rejected.');
    ELSE
      RAISE;
    END IF;
END;
/

PROMPT
PAUSE  Press ENTER to create Flight C (inside maintenance, no overlap with A)...

-- =============================================================================
-- Step 8: Flight C (no overlap with A, overlaps maintenance) + auto-block
-- =============================================================================
DECLARE
  v_asset_id NUMBER;
  v_start_c  DATE := TRUNC(SYSDATE) + 10 + 12.5/24;
  v_end_c    DATE := TRUNC(SYSDATE) + 10 + 12.75/24;
BEGIN
  SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'DEMO_MAINT_ASSET';
  ResourceManagement_Data.AddAllocationContext(
    p_asset_id           => v_asset_id,
    p_context_identifier => 'DEMO_MAINT_Flight_C',
    p_start_date         => v_start_c,
    p_end_date           => v_end_c,
    p_metadata           => '{"context_type":"normal"}'
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 8: Flight C created.');
END;
/

PROMPT === Flight C allocations (maintained seats should be blocked) ===

SELECT ri.instance_identifier, ca.status
  FROM CurrentAllocations ca
  JOIN AllocationContext  ac ON ca.context_id = ac.id
  LEFT JOIN ResourceInstance ri ON ri.id = ca.resource_instance_id
 WHERE ac.context_identifier = 'DEMO_MAINT_Flight_C'
 ORDER BY ri.instance_identifier;

PROMPT === Available seats on Flight C (expect 8 of 10) ===

SELECT ResourceManagement.GetAvailableSeatCount('DEMO_MAINT_Flight_C', 'DEMO_MAINT_Business') AS available_seats
  FROM DUAL;

PROMPT
PAUSE  Press ENTER to tear down demo data...

-- =============================================================================
-- Step 9: Teardown
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation WHERE context_id IN (
    SELECT id FROM AllocationContext WHERE context_identifier IN (
      'DEMO_MAINT_Flight_A','DEMO_MAINT_Flight_B','DEMO_MAINT_Flight_C','DEMO_MAINT_Period_1'
    ))]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (
    SELECT id FROM AllocationContext WHERE context_identifier IN (
      'DEMO_MAINT_Flight_A','DEMO_MAINT_Flight_B','DEMO_MAINT_Flight_C','DEMO_MAINT_Period_1'
    ))]');
  silent_delete(q'[DELETE FROM Capacity WHERE context_id IN (
    SELECT id FROM AllocationContext WHERE context_identifier IN (
      'DEMO_MAINT_Flight_A','DEMO_MAINT_Flight_B','DEMO_MAINT_Flight_C','DEMO_MAINT_Period_1'
    ))]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier IN (
    'DEMO_MAINT_Flight_A','DEMO_MAINT_Flight_B','DEMO_MAINT_Flight_C','DEMO_MAINT_Period_1'
  )]');
  silent_delete(q'[DELETE FROM ResourceInstance WHERE asset_id IN (
    SELECT id FROM ResourceAsset WHERE name = 'DEMO_MAINT_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity WHERE asset_id IN (
    SELECT id FROM ResourceAsset WHERE name = 'DEMO_MAINT_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset WHERE name = 'DEMO_MAINT_ASSET']');
  silent_delete(q'[DELETE FROM Users WHERE name = 'DEMO_MAINT_USER']');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name = 'DEMO_MAINT_Business']');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 9: teardown complete.');
END;
/

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 09 finished.
PROMPT =============================================================================
