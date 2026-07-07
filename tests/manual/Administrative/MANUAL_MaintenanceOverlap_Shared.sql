-- =============================================================================
-- MANUAL_MaintenanceOverlap_Shared.sql
-- =============================================================================
-- Manual, cell-style test: maintenance overlap behavior for direct/shared mode.
--
-- Scenario:
--   1) Create Meeting A (normal direct context)
--   2) Reserve one shared resource in Meeting A
--   3) Create overlapping maintenance context for that resource
--   4) Assert blocked retroactively appears in Meeting A
--   5) Create Meeting C (non-overlap with A but overlap with maintenance)
--   6) Assert Meeting C auto-blocked and reservation is rejected
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_MaintenanceOverlap_Shared ===');
END;
/

-- =============================================================================
-- Cell 0: Cleanup
-- =============================================================================
DECLARE
  v_j NUMBER; v_aa NUMBER; v_ctx NUMBER; v_ri NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (
    SELECT id FROM AllocationContext
    WHERE context_identifier IN (
      'MANUAL_Maint_Meeting_A',
      'MANUAL_Maint_Meeting_B',
      'MANUAL_Maint_Meeting_C',
      'MANUAL_Maint_Period_Direct'
    )
  );
  v_aa := SQL%ROWCOUNT;

  DELETE FROM AllocationJournal
  WHERE context_id IN (
    SELECT id FROM AllocationContext
    WHERE context_identifier IN (
      'MANUAL_Maint_Meeting_A',
      'MANUAL_Maint_Meeting_B',
      'MANUAL_Maint_Meeting_C',
      'MANUAL_Maint_Period_Direct'
    )
  );
  v_j := SQL%ROWCOUNT;

  DELETE FROM AllocationContext
  WHERE context_identifier IN (
    'MANUAL_Maint_Meeting_A',
    'MANUAL_Maint_Meeting_B',
    'MANUAL_Maint_Meeting_C',
    'MANUAL_Maint_Period_Direct'
  );
  v_ctx := SQL%ROWCOUNT;

  DELETE FROM ResourceInstance
  WHERE instance_identifier = 'RI(MANUAL_Maint_Person)';
  v_ri := SQL%ROWCOUNT;

  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Maint_Direct_Asset';
  v_ra := SQL%ROWCOUNT;

  DELETE FROM Users WHERE name = 'MANUAL_Maint_Direct_User';
  v_u := SQL%ROWCOUNT;

  DELETE FROM ResourceCategory WHERE name = 'MANUAL_Maint_Direct_Class';
  v_rc := SQL%ROWCOUNT;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 0: Cleanup done. Journal=' || v_j || ', AA=' || v_aa || ', Context=' || v_ctx ||
                       ', Instances=' || v_ri || ', Asset=' || v_ra || ', User=' || v_u || ', Category=' || v_rc);
END;
/

-- =============================================================================
-- Cell 1: Reference data
-- =============================================================================
BEGIN
  ResourceManagement_Data.AddResourceStatus('reserved', 'Held');
  ResourceManagement_Data.AddResourceStatus('confirmed', 'Confirmed');
  ResourceManagement_Data.AddResourceStatus('cancelled', 'Cancelled');
  ResourceManagement_Data.AddResourceStatus('checked-in', 'Checked In');
  ResourceManagement_Data.AddResourceStatus('boarded', 'Boarded');
  ResourceManagement_Data.AddResourceStatus('blocked', 'Blocked');
  ResourceManagement_Data.AddResourceStatus('completed', 'Completed');
EXCEPTION
  WHEN DUP_VAL_ON_INDEX THEN NULL;
END;
/

BEGIN
  ResourceManagement_Data.AddResourceInstanceStatus('available', 'Available');
  ResourceManagement_Data.AddResourceInstanceStatus('unavailable', 'Unavailable');
  ResourceManagement_Data.AddResourceInstanceStatus('in-use', 'In Use');
EXCEPTION
  WHEN DUP_VAL_ON_INDEX THEN NULL;
END;
/
COMMIT;

-- =============================================================================
-- Cell 2: Setup direct category, user, asset, instance, Meeting A
-- =============================================================================
DECLARE
  v_count NUMBER;
  v_asset_id NUMBER;
  v_category_id NUMBER;
  v_start_a DATE := TRUNC(SYSDATE) + 10 + 10/24;
  v_end_a   DATE := TRUNC(SYSDATE) + 10 + 12/24;
BEGIN
  SELECT COUNT(*) INTO v_count FROM ResourceCategory WHERE name = 'MANUAL_Maint_Direct_Class';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceCategory('MANUAL_Maint_Direct_Class', 'Direct category for maintenance overlap', 'direct');
  END IF;

  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_Maint_Direct_User';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddUser('MANUAL_Maint_Direct_User');
  END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Maint_Direct_Asset';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceAsset('MANUAL_Maint_Direct_Asset', NULL, 'active');
  END IF;

  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Maint_Direct_Asset'
    AND c.name = 'MANUAL_Maint_Direct_Class';

  SELECT COUNT(*) INTO v_count
  FROM ResourceInstance
  WHERE asset_id = v_asset_id
    AND instance_identifier = 'RI(MANUAL_Maint_Person)';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'RI(MANUAL_Maint_Person)', 'available');
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM AllocationContext
  WHERE context_identifier = 'MANUAL_Maint_Meeting_A';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddDirectAllocationContext(
      p_context_identifier => 'MANUAL_Maint_Meeting_A',
      p_start_date => v_start_a,
      p_end_date => v_end_a,
      p_metadata => '{"context_type":"normal"}'
    );
  END IF;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Setup complete.');
END;
/

-- =============================================================================
-- Cell 3: [SESSION A] MakeReservation for person in Meeting A - BLOCKS
-- =============================================================================
-- Run this block in Session A. While it is blocked, run Cell 3b in Session B.
DECLARE
  v_user_id NUMBER;
  v_person_id NUMBER;
  v_journal_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_Maint_Direct_User';
  SELECT ri.id INTO v_person_id
  FROM ResourceInstance ri
  WHERE ri.instance_identifier = 'RI(MANUAL_Maint_Person)';

  ResourceManagement.MakeReservation(
    p_context_identifier => 'MANUAL_Maint_Meeting_A',
    p_user_id            => v_user_id,
    p_instance_id        => v_person_id,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_journal_id
  );
  DBMS_OUTPUT.PUT_LINE('Cell 3: MakeReservation returned. journal=' || v_journal_id);
END;
/

-- =============================================================================
-- Cell 3b: [SESSION B] Publish CONFIRM event for Meeting A reservation
-- =============================================================================
-- Run in a second session while Cell 3 is blocked.
DECLARE
  v_user_id NUMBER;
  v_person_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_Maint_Direct_User';
  SELECT ri.id INTO v_person_id FROM ResourceInstance ri WHERE ri.instance_identifier = 'RI(MANUAL_Maint_Person)';
  ResourceManagement.publish_reservation_event(
    p_resource_id        => v_person_id,
    p_context_identifier => 'MANUAL_Maint_Meeting_A',
    p_user_id            => v_user_id,
    p_action             => 'CONFIRM'
  );
END;
/

-- =============================================================================
-- Cell 4: Assert no blocked before maintenance
-- =============================================================================
SELECT COUNT(*) AS blocked_before
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ac.id = ca.context_id
JOIN ResourceInstance ri ON ri.id = ca.resource_instance_id
WHERE ac.context_identifier = 'MANUAL_Maint_Meeting_A'
  AND ri.instance_identifier = 'RI(MANUAL_Maint_Person)'
  AND ca.status = 'blocked';
-- Expected: 0

-- =============================================================================
-- Cell 5: Create direct maintenance context overlapping Meeting A
-- =============================================================================
DECLARE
  v_person_id NUMBER;
  v_start_m DATE := TRUNC(SYSDATE) + 10 + 11/24;
  v_end_m   DATE := TRUNC(SYSDATE) + 10 + 13/24;
BEGIN
  SELECT ri.id INTO v_person_id
  FROM ResourceInstance ri
  WHERE ri.instance_identifier = 'RI(MANUAL_Maint_Person)';

  ResourceManagement_Data.AddDirectAllocationContext(
    p_context_identifier => 'MANUAL_Maint_Period_Direct',
    p_start_date => v_start_m,
    p_end_date => v_end_m,
    p_metadata => '{"context_type":"maintenance","resource_instance_ids":[' || v_person_id || ']}'
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 5: Direct maintenance context created.');
END;
/

-- =============================================================================
-- Cell 6: Assert retroactive blocked on Meeting A
-- =============================================================================
SELECT ri.instance_identifier, ca.status, ca.user_id
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ac.id = ca.context_id
JOIN ResourceInstance ri ON ri.id = ca.resource_instance_id
WHERE ac.context_identifier = 'MANUAL_Maint_Meeting_A'
  AND ri.instance_identifier = 'RI(MANUAL_Maint_Person)';
-- Expected: status='blocked', user_id NULL

-- =============================================================================
-- Cell 7: Create Meeting B overlapping A, then reservation should fail
-- =============================================================================
DECLARE
  v_user_id NUMBER;
  v_person_id NUMBER;
  v_journal_id NUMBER;
  v_start_b DATE := TRUNC(SYSDATE) + 10 + 11.25/24;
  v_end_b   DATE := TRUNC(SYSDATE) + 10 + 11.75/24;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_Maint_Direct_User';
  SELECT ri.id INTO v_person_id FROM ResourceInstance ri WHERE ri.instance_identifier = 'RI(MANUAL_Maint_Person)';

  BEGIN
    ResourceManagement_Data.AddDirectAllocationContext(
      p_context_identifier => 'MANUAL_Maint_Meeting_B',
      p_start_date => v_start_b,
      p_end_date => v_end_b,
      p_metadata => '{"context_type":"normal","resource_instance_ids":[' || v_person_id || ']}'
    );
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Cell 7: Meeting B creation rejected: ' || SQLERRM);
      RETURN;
  END;

  BEGIN
    ResourceManagement.MakeReservation('MANUAL_Maint_Meeting_B', v_user_id, v_person_id, v_journal_id);
    DBMS_OUTPUT.PUT_LINE('Cell 7: Expected reservation failure but succeeded [FAIL]');
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Cell 7: Reservation rejected as expected: ' || SQLERRM || ' [PASS]');
  END;
END;
/

-- =============================================================================
-- Cell 8: Create Meeting C (non-overlap A, overlap maintenance)
-- =============================================================================
DECLARE
  v_person_id NUMBER;
  v_start_c DATE := TRUNC(SYSDATE) + 10 + 12.5/24;
  v_end_c   DATE := TRUNC(SYSDATE) + 10 + 12.75/24;
BEGIN
  SELECT ri.id INTO v_person_id FROM ResourceInstance ri WHERE ri.instance_identifier = 'RI(MANUAL_Maint_Person)';
  ResourceManagement_Data.AddDirectAllocationContext(
    p_context_identifier => 'MANUAL_Maint_Meeting_C',
    p_start_date => v_start_c,
    p_end_date => v_end_c,
    p_metadata => '{"context_type":"normal","resource_instance_ids":[' || v_person_id || ']}'
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 8: Meeting C created.');
END;
/

-- =============================================================================
-- Cell 9: Assert Meeting C auto-blocked
-- =============================================================================
SELECT ri.instance_identifier, ca.status, ca.user_id
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ac.id = ca.context_id
JOIN ResourceInstance ri ON ri.id = ca.resource_instance_id
WHERE ac.context_identifier = 'MANUAL_Maint_Meeting_C';
-- Expected: one row, status='blocked', user_id NULL

-- =============================================================================
-- Cell 10: Reservation on Meeting C should fail
-- =============================================================================
DECLARE
  v_user_id NUMBER;
  v_person_id NUMBER;
  v_journal_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_Maint_Direct_User';
  SELECT ri.id INTO v_person_id FROM ResourceInstance ri WHERE ri.instance_identifier = 'RI(MANUAL_Maint_Person)';

  BEGIN
    ResourceManagement.MakeReservation('MANUAL_Maint_Meeting_C', v_user_id, v_person_id, v_journal_id);
    DBMS_OUTPUT.PUT_LINE('Cell 10: Expected rejection but reservation succeeded [FAIL]');
  EXCEPTION
    WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('Cell 10: Reservation rejected as expected: ' || SQLERRM || ' [PASS]');
  END;
END;
/

-- =============================================================================
-- Cell 11: Teardown
-- =============================================================================
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (
    SELECT id FROM AllocationContext
    WHERE context_identifier IN (
      'MANUAL_Maint_Meeting_A',
      'MANUAL_Maint_Meeting_B',
      'MANUAL_Maint_Meeting_C',
      'MANUAL_Maint_Period_Direct'
    )
  );

  DELETE FROM AllocationJournal
  WHERE context_id IN (
    SELECT id FROM AllocationContext
    WHERE context_identifier IN (
      'MANUAL_Maint_Meeting_A',
      'MANUAL_Maint_Meeting_B',
      'MANUAL_Maint_Meeting_C',
      'MANUAL_Maint_Period_Direct'
    )
  );

  DELETE FROM AllocationContext
  WHERE context_identifier IN (
    'MANUAL_Maint_Meeting_A',
    'MANUAL_Maint_Meeting_B',
    'MANUAL_Maint_Meeting_C',
    'MANUAL_Maint_Period_Direct'
  );

  DELETE FROM ResourceInstance WHERE instance_identifier = 'RI(MANUAL_Maint_Person)';
  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Maint_Direct_Asset';
  DELETE FROM Users WHERE name = 'MANUAL_Maint_Direct_User';
  DELETE FROM ResourceCategory WHERE name = 'MANUAL_Maint_Direct_Class';
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 11: Teardown complete.');
END;
/
