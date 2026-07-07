-- =============================================================================
-- MANUAL_MakeReservation_ByCategory.sql
-- =============================================================================
-- Manual, cell-style test: MakeReservation (category overload, dispatcher path).
-- Calls the new MakeReservation(context, user, category, quantity, ...) overload
-- which delegates to ReserveByCategory and returns the GROUP LEADER journal id
-- as a scalar OUT (= the smallest journal id in the resulting group).
--
-- Two-session pattern: Session A blocks in Cell 4; Session B publishes CONFIRM
-- in Cell 4b. Cell 5 asserts:
--   * the OUT scalar from Cell 4 == MIN(journal_id) of the group
--   * each journal carries metadata.group_leader_journal_id = leader
--   * all journals are confirmed
--
-- Cell index:
--   0  Cleanup
--   1  Reference data
--   2  Data Setup
--   3  Assert: context + capacity init
--   4  Act (Session A): MakeReservation(category overload, qty=2, timeout 5 min)
--   4b Act (Session B): publish_group_reservation_event('CONFIRM')
--   5  Assert: OUT scalar matches leader; metadata stamped; all confirmed
--   6  Teardown
--
-- Test identifier: 'MANUAL_MR_ByCategory'
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

VAR g_leader_out NUMBER

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_MakeReservation_ByCategory ===');
  DBMS_OUTPUT.PUT_LINE('Dispatcher overload returns the group leader; group confirmed via single AQ event.');
END;
/

-- =============================================================================
-- Cell 0: Cleanup
-- =============================================================================

BEGIN
  DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_MR_ByCategory');
  DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_MR_ByCategory');
  DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_MR_ByCategory');
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_MR_ByCategory';
  DELETE FROM ResourceInstance  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_MR_ByCategory');
  DELETE FROM AssetCapacity     WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_MR_ByCategory');
  DELETE FROM ResourceAsset     WHERE name = 'MANUAL_Asset_MR_ByCategory';
  DELETE FROM Users             WHERE name = 'MANUAL_User_MR_ByCategory';
  DELETE FROM ResourceCategory  WHERE name = 'MANUAL_MR_Cat_ByCategory';
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 0: Cleanup done.');
END;
/
PROMPT Cell 0 done

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
  ResourceManagement_Data.AddResourceInstanceStatus('available', 'Available');
  ResourceManagement_Data.AddResourceInstanceStatus('unavailable', 'Unavailable');
  ResourceManagement_Data.AddResourceInstanceStatus('in-use', 'In Use');
  COMMIT;
EXCEPTION WHEN DUP_VAL_ON_INDEX THEN COMMIT;
END;
/
PROMPT Cell 1 done

-- =============================================================================
-- Cell 2: Data Setup
-- =============================================================================

DECLARE v_count NUMBER; v_asset_id NUMBER; v_category_id NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM ResourceCategory WHERE name = 'MANUAL_MR_Cat_ByCategory';
  IF v_count = 0 THEN ResourceManagement_Data.AddResourceCategory('MANUAL_MR_Cat_ByCategory', NULL, 'pool'); END IF;

  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_MR_ByCategory';
  IF v_count = 0 THEN ResourceManagement_Data.AddUser('MANUAL_User_MR_ByCategory'); END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Asset_MR_ByCategory';
  IF v_count = 0 THEN ResourceManagement_Data.AddResourceAsset('MANUAL_Asset_MR_ByCategory', NULL, 'active'); END IF;

  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Asset_MR_ByCategory' AND c.name = 'MANUAL_MR_Cat_ByCategory';

  SELECT COUNT(*) INTO v_count FROM AssetCapacity WHERE asset_id = v_asset_id AND category_id = v_category_id;
  IF v_count = 0 THEN ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_category_id, 5); END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceInstance WHERE asset_id = v_asset_id;
  IF v_count = 0 THEN
    FOR i IN 1..5 LOOP
      ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'BC' || i, 'available');
    END LOOP;
  END IF;

  SELECT COUNT(*) INTO v_count FROM AllocationContext WHERE context_identifier = 'MANUAL_MR_ByCategory';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddAllocationContext(v_asset_id, 'MANUAL_MR_ByCategory', SYSDATE + 1, SYSDATE + 2);
  END IF;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data Setup complete (5 seats).');
END;
/
PROMPT Cell 2 done

-- =============================================================================
-- Cell 3: Assert init
-- =============================================================================

DECLARE v_total NUMBER; v_active NUMBER;
BEGIN
  SELECT c.total_capacity, c.active_count INTO v_total, v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE ac.context_identifier = 'MANUAL_MR_ByCategory' AND rc.name = 'MANUAL_MR_Cat_ByCategory';
  DBMS_OUTPUT.PUT_LINE('Cell 3: total=' || v_total || ', active=' || v_active ||
    CASE WHEN v_total = 5 AND v_active = 0 THEN ' [PASS]' ELSE ' [FAIL]' END);
END;
/
PROMPT Cell 3 done

-- =============================================================================
-- Cell 4 (Session A): MakeReservation(category overload, qty=2) – BLOCKS
-- =============================================================================
-- Calls the dispatcher overload that returns the group leader as a scalar.

DECLARE
  v_user_id  NUMBER;
  v_leader   NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_MR_ByCategory';
  ResourceManagement.MakeReservation(
    p_context_identifier => 'MANUAL_MR_ByCategory',
    p_user_id            => v_user_id,
    p_category_name      => 'MANUAL_MR_Cat_ByCategory',
    p_quantity           => 2,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_leader
  );
  COMMIT;
  :g_leader_out := v_leader;
  DBMS_OUTPUT.PUT_LINE('Cell 4: MakeReservation (category) returned. group_leader=' || NVL(TO_CHAR(v_leader), 'NULL'));
END;
/
PROMPT Cell 4 done: dispatcher returned

-- =============================================================================
-- Cell 4b (Session B): publish CONFIRM
-- =============================================================================

DECLARE v_user_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_MR_ByCategory';
  ResourceManagement.publish_group_reservation_event(
    p_context_identifier => 'MANUAL_MR_ByCategory',
    p_user_id            => v_user_id,
    p_category_name      => 'MANUAL_MR_Cat_ByCategory',
    p_action             => 'CONFIRM'
  );
  DBMS_OUTPUT.PUT_LINE('Cell 4b: published CONFIRM.');
END;
/
PROMPT Cell 4b done

-- =============================================================================
-- Cell 5: Assert – OUT scalar matches MIN(journal_id), metadata stamped, all confirmed
-- =============================================================================

DECLARE
  v_ctx_id          NUMBER;
  v_min_jid         NUMBER;
  v_confirmed       NUMBER;
  v_metadata_match  NUMBER;
  v_total_journals  NUMBER;
  v_leader          NUMBER := :g_leader_out;
BEGIN
  SELECT id INTO v_ctx_id FROM AllocationContext WHERE context_identifier = 'MANUAL_MR_ByCategory';

  SELECT MIN(id), COUNT(*) INTO v_min_jid, v_total_journals
  FROM AllocationJournal
  WHERE context_id = v_ctx_id;

  SELECT COUNT(*) INTO v_confirmed
  FROM CurrentAllocations WHERE context_id = v_ctx_id AND status = 'confirmed';

  -- All journals in the group should carry metadata.group_leader_journal_id = leader
  SELECT COUNT(*) INTO v_metadata_match
  FROM AllocationJournal aj
  WHERE aj.context_id = v_ctx_id
    AND aj.metadata IS NOT NULL
    AND JSON_VALUE(aj.metadata, '$.group_leader_journal_id' RETURNING NUMBER) = v_leader;

  DBMS_OUTPUT.PUT_LINE('Cell 5: leader_out=' || NVL(TO_CHAR(v_leader), 'NULL') ||
    ', min_jid=' || v_min_jid ||
    ', confirmed=' || v_confirmed ||
    ', metadata_match=' || v_metadata_match ||
    ', total_journals=' || v_total_journals);

  IF v_leader = v_min_jid
     AND v_confirmed = 2
     AND v_metadata_match >= 2 THEN
    DBMS_OUTPUT.PUT_LINE('Cell 5: dispatcher leader-id, metadata, and confirmation all consistent [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 5: dispatcher assertions failed [FAIL]');
  END IF;
END;
/
PROMPT Cell 5 done

-- =============================================================================
-- Cell 6: Teardown
-- =============================================================================

DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_MR_ByCategory');
DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_MR_ByCategory');
DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_MR_ByCategory');
DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_MR_ByCategory';
DELETE FROM ResourceInstance  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_MR_ByCategory');
DELETE FROM AssetCapacity     WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_MR_ByCategory');
DELETE FROM ResourceAsset     WHERE name = 'MANUAL_Asset_MR_ByCategory';
DELETE FROM Users             WHERE name = 'MANUAL_User_MR_ByCategory';
DELETE FROM ResourceCategory  WHERE name = 'MANUAL_MR_Cat_ByCategory';
COMMIT;
PROMPT Cell 6 done: Teardown
