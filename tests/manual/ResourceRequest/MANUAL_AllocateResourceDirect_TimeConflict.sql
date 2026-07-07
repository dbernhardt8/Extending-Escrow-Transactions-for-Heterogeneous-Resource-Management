-- =============================================================================
-- MANUAL_MakeReservation_TimeConflict.sql (#21)
-- =============================================================================
-- Manual, cell-style test: MakeReservation (direct/shared mode) – time conflict.
-- Multiple direct allocation contexts mixing overlapping and non-overlapping
-- time intervals; one shared resource instance. First conflicting allocation
-- succeeds; subsequent overlapping allocations fail with -20703 (conflict),
-- while a non-overlapping allocation succeeds.
-- Assert: CheckResourceTimeConflict(instance, ctx2) = ctx1_id, allocations for ctx1 and ctx3.
--
-- Setup: Cell 1 = reference data; Cell 2 = Data Setup (direct category, 4 users,
-- asset, 4 resource instances, 4 direct contexts with mixed overlap).
--
-- Run cells in order. In SQL Developer: select from "-- ===== Cell N:" to the
-- start of the next cell, then Execute.
--
-- Cell index:
--   0  Cleanup (optional first)
--   1  Reference data (ResourceStatus, ResourceInstanceStatus)
--   2  Data Setup – direct category, 4 users, asset, 4 instances, 4 direct contexts (mixed overlap)
--   3  Assert: 4 contexts exist, no Capacity (direct mode), instances available
--   4  Act: MakeReservation(ctx1, instance, user1) → success (direct mode via dispatcher)
--   5  Act: MakeReservation(ctx2, instance, user2) → expect exception -20703
--   5a Act: MakeReservation(ctx4, instance, user4) → expect exception -20703
--   5b Act: MakeReservation(ctx3, instance, user3) → success (non-overlapping)
--   6  Assert: CheckResourceTimeConflict(instance, ctx2)=ctx1_id, CurrentAllocations 2 rows (ctx1+ctx3)
--   7  Teardown
--
-- Test identifiers:
--   MANUAL_Direct_Meeting1 (10:00–11:00)
--   MANUAL_Direct_Meeting2 (10:30–11:30) [overlaps with 1]
--   MANUAL_Direct_Meeting4 (10:15–10:45) [overlaps with 1]
--   MANUAL_Direct_Meeting3 (12:00–13:00) [non-overlapping]
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_MakeReservation_TimeConflict (#21) ===');
  DBMS_OUTPUT.PUT_LINE('Mixed overlap: allocate overlapping contexts fails (-20703), non-overlap succeeds.');
  DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- Cell 0: Cleanup (optional – run first to remove leftover data from last run)
-- =============================================================================
-- Direct contexts have no Capacity rows. Teardown: ActiveAllocation → Journal → Context → Instance → AssetCapacity → Asset → User → ResourceCategory.
-- Category (MANUAL_Direct_Category) is reused.

DECLARE
  v_j NUMBER; v_aa NUMBER; v_ctx NUMBER; v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (
    SELECT id FROM AllocationContext
    WHERE context_identifier IN (
      'MANUAL_Direct_Meeting1',
      'MANUAL_Direct_Meeting2',
      'MANUAL_Direct_Meeting3',
      'MANUAL_Direct_Meeting4'
    )
  );
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (
    SELECT id FROM AllocationContext
    WHERE context_identifier IN (
      'MANUAL_Direct_Meeting1',
      'MANUAL_Direct_Meeting2',
      'MANUAL_Direct_Meeting3',
      'MANUAL_Direct_Meeting4'
    )
  );
  v_j := SQL%ROWCOUNT;
  DELETE FROM AllocationContext
  WHERE context_identifier IN (
    'MANUAL_Direct_Meeting1',
    'MANUAL_Direct_Meeting2',
    'MANUAL_Direct_Meeting3',
    'MANUAL_Direct_Meeting4'
  );
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE instance_identifier IN (
    'RI(MANUAL_User_Direct1)',
    'RI(MANUAL_User_Direct2)',
    'RI(MANUAL_User_Direct3)',
    'RI(MANUAL_User_Direct4)'
  );
  v_ri := SQL%ROWCOUNT;
  -- Keep shared asset WF_SHARED_ASSET persistent across DB runs.
  v_ac := 0;
  v_ra := 0;
  DELETE FROM Users WHERE name IN ('MANUAL_User_Direct1', 'MANUAL_User_Direct2', 'MANUAL_User_Direct3', 'MANUAL_User_Direct4');
  v_u := SQL%ROWCOUNT;
  DELETE FROM ResourceCategory WHERE name = 'MANUAL_Direct_Category';
  v_rc := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 0: Cleanup done. Deleted: Journal=' || v_j || ', ActiveAllocation=' || v_aa || ', Context=' || v_ctx ||
    ', Instances=' || v_ri || ', AssetCap=' || v_ac || ', Asset=' || v_ra || ', Users=' || v_u || ', Category=' || v_rc);
END;
/

PROMPT Cell 0 done: Cleanup (if any)

-- =============================================================================
-- Cell 1: Reference data (ResourceStatus, ResourceInstanceStatus)
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

PROMPT Cell 1: Reference data

-- -----------------------------------------------------------------------------
-- Cell 1a: Create RESERVJRNL_CAPACITY view (optional)
-- -----------------------------------------------------------------------------
DECLARE
  v_obj_id NUMBER;
  v_sql    VARCHAR2(4000);
BEGIN
  SELECT object_id INTO v_obj_id
  FROM user_objects
  WHERE object_name = 'CAPACITY' AND object_type = 'TABLE';

  v_sql := 'CREATE OR REPLACE VIEW RESERVJRNL_CAPACITY AS ' ||
           'SELECT * FROM SYS_RESERVJRNL_' || v_obj_id;
  EXECUTE IMMEDIATE v_sql;
  DBMS_OUTPUT.PUT_LINE('Created view RESERVJRNL_CAPACITY for SYS_RESERVJRNL_' || v_obj_id);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Could not create RESERVJRNL_CAPACITY view: ' || SQLERRM);
END;
/

PROMPT Cell 1a done: RESERVJRNL_CAPACITY view

-- =============================================================================
-- Cell 2: Data Setup – direct category, 4 users, asset, 4 instances, 4 direct contexts (mixed overlap)
-- =============================================================================
-- Meeting1: tomorrow 10:00–11:00
-- Meeting2: tomorrow 10:30–11:30 (overlap with 1)
-- Meeting4: tomorrow 10:15–10:45 (overlap with 1 and 2)
-- Meeting3: tomorrow 12:00–13:00 (non-overlapping)

DECLARE
  v_count       NUMBER;
  v_asset_id    NUMBER;
  v_category_id NUMBER;
  v_ctx_count  NUMBER;
  v_start1      DATE;
  v_end1        DATE;
  v_start2      DATE;
  v_end2        DATE;
  v_start3      DATE;
  v_end3        DATE;
  v_start4      DATE;
  v_end4        DATE;
BEGIN
  -- Category (direct allocation mode)
  SELECT COUNT(*) INTO v_count FROM ResourceCategory WHERE name = 'MANUAL_Direct_Category';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceCategory('MANUAL_Direct_Category', NULL, 'direct');
  END IF;

  -- Users
  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_Direct1';
  IF v_count = 0 THEN ResourceManagement_Data.AddUser('MANUAL_User_Direct1'); END IF;
  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_Direct2';
  IF v_count = 0 THEN ResourceManagement_Data.AddUser('MANUAL_User_Direct2'); END IF;
  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_Direct3';
  IF v_count = 0 THEN ResourceManagement_Data.AddUser('MANUAL_User_Direct3'); END IF;
  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_Direct4';
  IF v_count = 0 THEN ResourceManagement_Data.AddUser('MANUAL_User_Direct4'); END IF;

  -- Shared container asset (persistent across runs)
  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'WF_SHARED_ASSET';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceAsset('WF_SHARED_ASSET', NULL, 'active');
  END IF;

  -- Four resource instances (RI per user) – direct mode category
  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'WF_SHARED_ASSET' AND c.name = 'MANUAL_Direct_Category';
  -- The time-conflict scenario uses RI(User1) in all reservation attempts.
  SELECT COUNT(*) INTO v_count
  FROM ResourceInstance
  WHERE asset_id = v_asset_id
    AND instance_identifier = 'RI(MANUAL_User_Direct1)';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'RI(MANUAL_User_Direct1)', 'available');
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM ResourceInstance
  WHERE asset_id = v_asset_id
    AND instance_identifier = 'RI(MANUAL_User_Direct2)';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'RI(MANUAL_User_Direct2)', 'available');
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM ResourceInstance
  WHERE asset_id = v_asset_id
    AND instance_identifier = 'RI(MANUAL_User_Direct3)';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'RI(MANUAL_User_Direct3)', 'available');
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM ResourceInstance
  WHERE asset_id = v_asset_id
    AND instance_identifier = 'RI(MANUAL_User_Direct4)';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'RI(MANUAL_User_Direct4)', 'available');
  END IF;

  -- Four direct contexts with mixed overlap and non-overlap
  -- Meeting1: tomorrow 10:00 – 11:00
  -- Meeting2: tomorrow 10:30 – 11:30
  -- Meeting4: tomorrow 10:15 – 10:45
  -- Meeting3: tomorrow 12:00 – 13:00
  v_start1 := TRUNC(SYSDATE) + 1 + 10/24;
  v_end1   := TRUNC(SYSDATE) + 1 + 11/24;
  v_start2 := TRUNC(SYSDATE) + 1 + 10.5/24;
  v_end2   := TRUNC(SYSDATE) + 1 + 11.5/24;
  v_start3 := TRUNC(SYSDATE) + 1 + 12/24;
  v_end3   := TRUNC(SYSDATE) + 1 + 13/24;
  v_start4 := TRUNC(SYSDATE) + 1 + 10.25/24;
  v_end4   := TRUNC(SYSDATE) + 1 + 10.75/24;

  SELECT COUNT(*) INTO v_ctx_count FROM AllocationContext WHERE context_identifier = 'MANUAL_Direct_Meeting1';
  IF v_ctx_count = 0 THEN
    ResourceManagement_Data.AddDirectAllocationContext('MANUAL_Direct_Meeting1', v_start1, v_end1);
  END IF;
  SELECT COUNT(*) INTO v_ctx_count FROM AllocationContext WHERE context_identifier = 'MANUAL_Direct_Meeting2';
  IF v_ctx_count = 0 THEN
    ResourceManagement_Data.AddDirectAllocationContext('MANUAL_Direct_Meeting2', v_start2, v_end2);
  END IF;
  SELECT COUNT(*) INTO v_ctx_count FROM AllocationContext WHERE context_identifier = 'MANUAL_Direct_Meeting3';
  IF v_ctx_count = 0 THEN
    ResourceManagement_Data.AddDirectAllocationContext('MANUAL_Direct_Meeting3', v_start3, v_end3);
  END IF;
  SELECT COUNT(*) INTO v_ctx_count FROM AllocationContext WHERE context_identifier = 'MANUAL_Direct_Meeting4';
  IF v_ctx_count = 0 THEN
    ResourceManagement_Data.AddDirectAllocationContext('MANUAL_Direct_Meeting4', v_start4, v_end4);
  END IF;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data Setup complete (4 contexts, mixed overlap, 4 users/instances).');
END;
/

PROMPT Cell 2 done: Data Setup

-- =============================================================================
-- Cell 3: Assert – 4 contexts exist, no Capacity for these contexts, instances available
-- =============================================================================

SELECT id, context_identifier, asset_id, start_date, end_date
FROM AllocationContext
WHERE context_identifier IN (
  'MANUAL_Direct_Meeting1',
  'MANUAL_Direct_Meeting2',
  'MANUAL_Direct_Meeting3',
  'MANUAL_Direct_Meeting4'
)
ORDER BY context_identifier;

SELECT COUNT(*) AS capacity_rows
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
WHERE ac.context_identifier IN (
  'MANUAL_Direct_Meeting1',
  'MANUAL_Direct_Meeting2',
  'MANUAL_Direct_Meeting3',
  'MANUAL_Direct_Meeting4'
);
-- Expected: 0 (direct contexts have no Capacity)

SELECT ri.id, ri.instance_identifier, ri.status
FROM ResourceInstance ri
JOIN ResourceAsset ra ON ri.asset_id = ra.id
WHERE ra.name = 'WF_SHARED_ASSET';
-- Expected: 4 rows, status = available

DECLARE
  v_ctx_count  NUMBER;
  v_cap_count  NUMBER;
  v_inst_count NUMBER;
  v_ok         BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_ctx_count
  FROM AllocationContext
  WHERE context_identifier IN (
    'MANUAL_Direct_Meeting1',
    'MANUAL_Direct_Meeting2',
    'MANUAL_Direct_Meeting3',
    'MANUAL_Direct_Meeting4'
  );
  SELECT COUNT(*) INTO v_cap_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  WHERE ac.context_identifier IN (
    'MANUAL_Direct_Meeting1',
    'MANUAL_Direct_Meeting2',
    'MANUAL_Direct_Meeting3',
    'MANUAL_Direct_Meeting4'
  );
  SELECT COUNT(*) INTO v_inst_count
  FROM ResourceInstance ri
  JOIN ResourceAsset ra ON ri.asset_id = ra.id
  WHERE ra.name = 'WF_SHARED_ASSET';

  IF v_ctx_count != 4 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: Expected 4 contexts, actual ' || v_ctx_count || ' [FAIL]');
  END IF;
  IF v_cap_count != 0 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: Expected 0 Capacity rows for direct contexts, actual ' || v_cap_count || ' [FAIL]');
  END IF;
  IF v_inst_count != 4 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: Expected 4 instances, actual ' || v_inst_count || ' [FAIL]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 3: 4 contexts, 0 Capacity, 4 instances [PASS]');
  END IF;
END;
/

PROMPT Cell 3 done: Assert init

-- =============================================================================
-- Cell 4: Act – MakeReservation(Meeting1, instance, user1) → success (direct mode)
-- =============================================================================

-- IMPORTANT: MakeReservation BLOCKS on RESERVATION_EVENTS_Q until Session B
-- publishes a CONFIRM. Run Cell 4b in a SECOND SQL session while this cell
-- is blocked.

DECLARE
  v_user1_id    NUMBER;
  v_instance_id NUMBER;
  v_journal_id  NUMBER;
BEGIN
  SELECT id INTO v_user1_id FROM Users WHERE name = 'MANUAL_User_Direct1';
  SELECT ri.id INTO v_instance_id
  FROM ResourceInstance ri
  JOIN ResourceAsset ra ON ri.asset_id = ra.id
  WHERE ra.name = 'WF_SHARED_ASSET' AND ri.instance_identifier = 'RI(MANUAL_User_Direct1)';

  ResourceManagement.MakeReservation(
    p_context_identifier => 'MANUAL_Direct_Meeting1',
    p_user_id            => v_user1_id,
    p_instance_id        => v_instance_id,
    p_timeout_minutes    => 15,
    p_new_journal_id     => v_journal_id
  );
  DBMS_OUTPUT.PUT_LINE('Cell 4: MakeReservation(Meeting1, RI(User1), user1) done. journal_id=' || v_journal_id || ' [PASS]');
END;
/

PROMPT Cell 4 done: Allocate Meeting1 → success

-- =============================================================================
-- Cell 4b: [SESSION B] Publish CONFIRM to unblock Cell 4
-- =============================================================================
-- DECLARE
--   v_user_id     NUMBER;
--   v_instance_id NUMBER;
-- BEGIN
--   SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_Direct1';
--   SELECT ri.id INTO v_instance_id
--   FROM ResourceInstance ri
--   JOIN ResourceAsset ra ON ri.asset_id = ra.id
--   WHERE ra.name = 'WF_SHARED_ASSET' AND ri.instance_identifier = 'RI(MANUAL_User_Direct1)';
--   ResourceManagement.publish_reservation_event(
--     p_resource_id        => v_instance_id,
--     p_context_identifier => 'MANUAL_Direct_Meeting1',
--     p_user_id            => v_user_id,
--     p_action             => 'CONFIRM'
--   );
-- END;
-- /

SELECT * FROM RESERVJRNL_CAPACITY;

-- =============================================================================
-- Cell 5: Act – MakeReservation(Meeting2, instance, user2) → expect -20703
-- =============================================================================

DECLARE
  v_user2_id    NUMBER;
  v_instance_id NUMBER;
  v_journal_id  NUMBER;
  v_sqlcode     NUMBER;
  v_sqlerrm     VARCHAR2(4000);
  v_exception   BOOLEAN := FALSE;
BEGIN
  SELECT id INTO v_user2_id FROM Users WHERE name = 'MANUAL_User_Direct2';
  SELECT ri.id INTO v_instance_id
  FROM ResourceInstance ri
  JOIN ResourceAsset ra ON ri.asset_id = ra.id
  WHERE ra.name = 'WF_SHARED_ASSET' AND ri.instance_identifier = 'RI(MANUAL_User_Direct1)';

  BEGIN
    -- Time-conflict check raises -20703 before the AQ dequeue, so this call
    -- returns synchronously without blocking.
    ResourceManagement.MakeReservation(
      p_context_identifier => 'MANUAL_Direct_Meeting2',
      p_user_id            => v_user2_id,
      p_instance_id        => v_instance_id,
      p_timeout_minutes    => 15,
      p_new_journal_id     => v_journal_id
    );
    DBMS_OUTPUT.PUT_LINE('Cell 5: MakeReservation(Meeting2) did NOT raise – expected -20703 [FAIL]');
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlcode := SQLCODE;
      v_sqlerrm := SQLERRM;
      IF v_sqlcode = -20703 THEN
        DBMS_OUTPUT.PUT_LINE('Cell 5: Expected exception -20703 (time conflict): ' || SUBSTR(v_sqlerrm, 1, 120) || ' [PASS]');
      ELSE
        DBMS_OUTPUT.PUT_LINE('Cell 5: Exception code=' || v_sqlcode || ' (expected -20703): ' || SUBSTR(v_sqlerrm, 1, 120) || ' [FAIL]');
      END IF;
  END;
END;
/

PROMPT Cell 5 done: Allocate Meeting2 → expect -20703

-- =============================================================================
-- Cell 5a: Act – MakeReservation(Meeting4, instance, user4) → expect exception -20703
-- =============================================================================

DECLARE
  v_user4_id    NUMBER;
  v_instance_id NUMBER;
  v_journal_id  NUMBER;
  v_sqlcode     NUMBER;
  v_sqlerrm     VARCHAR2(4000);
BEGIN
  SELECT id INTO v_user4_id FROM Users WHERE name = 'MANUAL_User_Direct4';
  SELECT ri.id INTO v_instance_id
  FROM ResourceInstance ri
  JOIN ResourceAsset ra ON ri.asset_id = ra.id
  WHERE ra.name = 'WF_SHARED_ASSET' AND ri.instance_identifier = 'RI(MANUAL_User_Direct1)';

  BEGIN
    -- Time-conflict check raises -20703 before the AQ dequeue, so this call
    -- returns synchronously without blocking.
    ResourceManagement.MakeReservation(
      p_context_identifier => 'MANUAL_Direct_Meeting4',
      p_user_id            => v_user4_id,
      p_instance_id        => v_instance_id,
      p_timeout_minutes    => 15,
      p_new_journal_id     => v_journal_id
    );
    DBMS_OUTPUT.PUT_LINE('Cell 5a: MakeReservation(Meeting4) did NOT raise – expected -20703 [FAIL]');
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlcode := SQLCODE;
      v_sqlerrm := SQLERRM;
      IF v_sqlcode = -20703 THEN
        DBMS_OUTPUT.PUT_LINE('Cell 5a: Expected exception -20703 (time conflict): ' || SUBSTR(v_sqlerrm, 1, 120) || ' [PASS]');
      ELSE
        DBMS_OUTPUT.PUT_LINE('Cell 5a: Exception code=' || v_sqlcode || ' (expected -20703): ' || SUBSTR(v_sqlerrm, 1, 120) || ' [FAIL]');
      END IF;
  END;
END;
/

PROMPT Cell 5a done: Allocate Meeting4 → expect -20703

-- =============================================================================
-- Cell 5b: Act – MakeReservation(Meeting3, instance, user3) → success (non-overlapping)
-- =============================================================================

-- IMPORTANT: BLOCKS on RESERVATION_EVENTS_Q. Run Cell 5c (below) in a SECOND
-- session to publish CONFIRM and unblock.

DECLARE
  v_user3_id    NUMBER;
  v_instance_id NUMBER;
  v_journal_id  NUMBER;
BEGIN
  SELECT id INTO v_user3_id FROM Users WHERE name = 'MANUAL_User_Direct3';
  SELECT ri.id INTO v_instance_id
  FROM ResourceInstance ri
  JOIN ResourceAsset ra ON ri.asset_id = ra.id
  WHERE ra.name = 'WF_SHARED_ASSET' AND ri.instance_identifier = 'RI(MANUAL_User_Direct1)';

  ResourceManagement.MakeReservation(
    p_context_identifier => 'MANUAL_Direct_Meeting3',
    p_user_id            => v_user3_id,
    p_instance_id        => v_instance_id,
    p_timeout_minutes    => 15,
    p_new_journal_id     => v_journal_id
  );
  DBMS_OUTPUT.PUT_LINE('Cell 5b: MakeReservation(Meeting3, RI(User1), user3) done. journal_id=' || v_journal_id || ' [PASS]');
END;
/

PROMPT Cell 5b done: Allocate Meeting3 (non-overlapping) → success

-- =============================================================================
-- Cell 5c: [SESSION B] Publish CONFIRM to unblock Cell 5b
-- =============================================================================
-- DECLARE
--   v_user_id     NUMBER;
--   v_instance_id NUMBER;
-- BEGIN
--   SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_Direct3';
--   SELECT ri.id INTO v_instance_id
--   FROM ResourceInstance ri
--   JOIN ResourceAsset ra ON ri.asset_id = ra.id
--   WHERE ra.name = 'WF_SHARED_ASSET' AND ri.instance_identifier = 'RI(MANUAL_User_Direct1)';
--   ResourceManagement.publish_reservation_event(
--     p_resource_id        => v_instance_id,
--     p_context_identifier => 'MANUAL_Direct_Meeting3',
--     p_user_id            => v_user_id,
--     p_action             => 'CONFIRM'
--   );
-- END;
-- /

-- =============================================================================
-- Cell 6: Assert – CheckResourceTimeConflict(instance, Meeting2)=ctx1_id, CurrentAllocations 2 rows (ctx1+ctx3)
-- =============================================================================

SELECT ResourceManagement.CheckResourceTimeConflict(
  (SELECT ri.id FROM ResourceInstance ri JOIN ResourceAsset ra ON ri.asset_id = ra.id WHERE ra.name = 'WF_SHARED_ASSET' AND ri.instance_identifier = 'RI(MANUAL_User_Direct1)'),
  'MANUAL_Direct_Meeting2'
) AS conflict_context_id FROM DUAL;
-- Expected: conflict_context_id = id of MANUAL_Direct_Meeting1

SELECT ac.context_identifier, ca.journal_id, ca.status
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
WHERE ac.context_identifier IN (
  'MANUAL_Direct_Meeting1',
  'MANUAL_Direct_Meeting2',
  'MANUAL_Direct_Meeting3',
  'MANUAL_Direct_Meeting4'
);
-- Expected: 2 rows (MANUAL_Direct_Meeting1 and MANUAL_Direct_Meeting3 only)

DECLARE
  v_ctx1_id     NUMBER;
  v_ctx3_id     NUMBER;
  v_conflict_id NUMBER;
  v_instance_id NUMBER;
  v_ca_count    NUMBER;
  v_ca_count_ctx1 NUMBER;
  v_ca_count_ctx3 NUMBER;
  v_ok          BOOLEAN := TRUE;
BEGIN
  SELECT id INTO v_ctx1_id FROM AllocationContext WHERE context_identifier = 'MANUAL_Direct_Meeting1';
  SELECT id INTO v_ctx3_id FROM AllocationContext WHERE context_identifier = 'MANUAL_Direct_Meeting3';
  SELECT ri.id INTO v_instance_id
  FROM ResourceInstance ri
  JOIN ResourceAsset ra ON ri.asset_id = ra.id
  WHERE ra.name = 'WF_SHARED_ASSET' AND ri.instance_identifier = 'RI(MANUAL_User_Direct1)';
  v_conflict_id := ResourceManagement.CheckResourceTimeConflict(v_instance_id, 'MANUAL_Direct_Meeting2');
  SELECT COUNT(*) INTO v_ca_count
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier IN (
    'MANUAL_Direct_Meeting1',
    'MANUAL_Direct_Meeting2',
    'MANUAL_Direct_Meeting3',
    'MANUAL_Direct_Meeting4'
  );
  SELECT COUNT(*) INTO v_ca_count_ctx1
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Direct_Meeting1';
  SELECT COUNT(*) INTO v_ca_count_ctx3
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Direct_Meeting3';

  IF v_conflict_id != v_ctx1_id THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 6: CheckResourceTimeConflict expected ' || v_ctx1_id || ', got ' || NVL(TO_CHAR(v_conflict_id), 'NULL') || ' [FAIL]');
  END IF;
  IF v_ca_count != 2 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 6: CurrentAllocations expected 2 rows, actual ' || v_ca_count || ' [FAIL]');
  END IF;
  IF v_ca_count_ctx1 != 1 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 6: Expected exactly 1 allocation for MANUAL_Direct_Meeting1, actual ' || v_ca_count_ctx1 || ' [FAIL]');
  END IF;
  IF v_ca_count_ctx3 != 1 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 6: Expected exactly 1 allocation for MANUAL_Direct_Meeting3, actual ' || v_ca_count_ctx3 || ' [FAIL]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 6: CheckResourceTimeConflict=ctx1_id, CurrentAllocations=2 (ctx1+ctx3) [PASS]');
  END IF;
END;
/

PROMPT Cell 6 done: Assert conflict and allocations for ctx1+ctx3

-- =============================================================================
-- Cell 7: Teardown
-- =============================================================================

DELETE FROM ActiveAllocation
WHERE context_id IN (
  SELECT id FROM AllocationContext
  WHERE context_identifier IN (
    'MANUAL_Direct_Meeting1',
    'MANUAL_Direct_Meeting2',
    'MANUAL_Direct_Meeting3',
    'MANUAL_Direct_Meeting4'
  )
);
DELETE FROM AllocationJournal
WHERE context_id IN (
  SELECT id FROM AllocationContext
  WHERE context_identifier IN (
    'MANUAL_Direct_Meeting1',
    'MANUAL_Direct_Meeting2',
    'MANUAL_Direct_Meeting3',
    'MANUAL_Direct_Meeting4'
  )
);
DELETE FROM AllocationContext
WHERE context_identifier IN (
  'MANUAL_Direct_Meeting1',
  'MANUAL_Direct_Meeting2',
  'MANUAL_Direct_Meeting3',
  'MANUAL_Direct_Meeting4'
);
DELETE FROM ResourceInstance
WHERE instance_identifier IN (
  'RI(MANUAL_User_Direct1)',
  'RI(MANUAL_User_Direct2)',
  'RI(MANUAL_User_Direct3)',
  'RI(MANUAL_User_Direct4)'
);
DELETE FROM Users WHERE name IN ('MANUAL_User_Direct1', 'MANUAL_User_Direct2', 'MANUAL_User_Direct3', 'MANUAL_User_Direct4');
DELETE FROM ResourceCategory WHERE name = 'MANUAL_Direct_Category';
COMMIT;

BEGIN
  DBMS_OUTPUT.PUT_LINE('Cell 7: Teardown complete.');
END;
/
PROMPT Cell 7 done: Teardown complete
