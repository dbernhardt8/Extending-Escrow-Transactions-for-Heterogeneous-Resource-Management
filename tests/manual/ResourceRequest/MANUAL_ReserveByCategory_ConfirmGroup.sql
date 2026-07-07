-- =============================================================================
-- MANUAL_ReserveByCategory_ConfirmGroup.sql
-- =============================================================================
-- Manual, cell-style test: ReserveByCategory (pool group) – CONFIRM all seats
-- via a single group event on RESERVATION_EVENTS_Q.
--
-- Two-session pattern:
--   Session A runs Cell 4 (ReserveByCategory blocks waiting for AQ).
--   Session B runs Cell 4b (publish_group_reservation_event 'CONFIRM').
--   Session A wakes, confirms all N journals, COMMITs.
--
-- Cell index:
--   0  Cleanup (optional first)
--   1  Reference data (statuses)
--   2  Data Setup – category, user, asset, capacity, instances, context
--   3  Assert: context + capacity init
--   4  Act (Session A): ReserveByCategory(qty=3, timeout 5 min) – blocks
--   4b Act (Session B): publish_group_reservation_event('CONFIRM')
--   5  Assert: 3 journals confirmed, active_count=3, available=7
--   6  Teardown
--
-- Test identifier: 'MANUAL_RBC_ConfirmGroup'
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_ReserveByCategory_ConfirmGroup ===');
  DBMS_OUTPUT.PUT_LINE('3 seats reserved as one group, then confirmed by a single AQ event.');
  DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- Cell 0: Cleanup
-- =============================================================================

DECLARE v_n NUMBER;
BEGIN
  DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_ConfirmGroup');
  DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_ConfirmGroup');
  DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_ConfirmGroup');
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_ConfirmGroup';
  DELETE FROM ResourceInstance  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_ConfirmGroup');
  DELETE FROM AssetCapacity     WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_ConfirmGroup');
  DELETE FROM ResourceAsset     WHERE name = 'MANUAL_Asset_RBC_ConfirmGroup';
  DELETE FROM Users             WHERE name = 'MANUAL_User_RBC_ConfirmGroup';
  DELETE FROM ResourceCategory  WHERE name = 'MANUAL_RBC_Category';
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 0: Cleanup done.');
END;
/

PROMPT Cell 0 done: Cleanup

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

PROMPT Cell 1 done: Reference data

-- =============================================================================
-- Cell 2: Data Setup – category, user, asset, 10 instances, context
-- =============================================================================

DECLARE
  v_count       NUMBER;
  v_asset_id    NUMBER;
  v_category_id NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM ResourceCategory WHERE name = 'MANUAL_RBC_Category';
  IF v_count = 0 THEN ResourceManagement_Data.AddResourceCategory('MANUAL_RBC_Category', NULL, 'pool'); END IF;

  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_RBC_ConfirmGroup';
  IF v_count = 0 THEN ResourceManagement_Data.AddUser('MANUAL_User_RBC_ConfirmGroup'); END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_ConfirmGroup';
  IF v_count = 0 THEN ResourceManagement_Data.AddResourceAsset('MANUAL_Asset_RBC_ConfirmGroup', NULL, 'active'); END IF;

  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Asset_RBC_ConfirmGroup' AND c.name = 'MANUAL_RBC_Category';

  SELECT COUNT(*) INTO v_count FROM AssetCapacity WHERE asset_id = v_asset_id AND category_id = v_category_id;
  IF v_count = 0 THEN ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_category_id, 10); END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceInstance WHERE asset_id = v_asset_id;
  IF v_count = 0 THEN
    FOR i IN 1..10 LOOP
      ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'CG' || i, 'available');
    END LOOP;
  END IF;

  SELECT COUNT(*) INTO v_count FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_ConfirmGroup';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddAllocationContext(v_asset_id, 'MANUAL_RBC_ConfirmGroup', SYSDATE + 1, SYSDATE + 2);
  END IF;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data Setup complete.');
END;
/
PROMPT Cell 2 done: Data Setup

-- =============================================================================
-- Cell 3: Assert – context + capacity init
-- =============================================================================

DECLARE v_total NUMBER; v_active NUMBER;
BEGIN
  SELECT c.total_capacity, c.active_count INTO v_total, v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE ac.context_identifier = 'MANUAL_RBC_ConfirmGroup' AND rc.name = 'MANUAL_RBC_Category';
  DBMS_OUTPUT.PUT_LINE('Cell 3: total=' || v_total || ', active=' || v_active ||
    CASE WHEN v_total = 10 AND v_active = 0 THEN ' [PASS]' ELSE ' [FAIL]' END);
END;
/
PROMPT Cell 3 done

-- =============================================================================
-- Cell 4 (Session A): Act – ReserveByCategory(qty=3, timeout 5 min) – BLOCKS
-- =============================================================================
-- This call blocks for up to 5 minutes waiting for an AQ event with
-- correlation 'RESGRP_<leader>'. While it is blocked, run Cell 4b in another
-- session to publish the CONFIRM event.

DECLARE
  v_user_id     NUMBER;
  v_journal_ids SYS.ODCINUMBERLIST;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_RBC_ConfirmGroup';
  ResourceManagement.ReserveByCategory(
    p_context_identifier => 'MANUAL_RBC_ConfirmGroup',
    p_category_name      => 'MANUAL_RBC_Category',
    p_user_id            => v_user_id,
    p_quantity           => 3,
    p_timeout_minutes    => 5,
    p_new_journal_ids    => v_journal_ids
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 4: ReserveByCategory returned with ' || v_journal_ids.COUNT || ' journal(s).');
  FOR i IN 1..v_journal_ids.COUNT LOOP
    DBMS_OUTPUT.PUT_LINE('  journal_id(' || i || ') = ' || v_journal_ids(i));
  END LOOP;
END;
/
PROMPT Cell 4 done: ReserveByCategory returned (was woken by Cell 4b or timed out)

-- =============================================================================
-- Cell 4b (Session B): Act – publish_group_reservation_event('CONFIRM')
-- =============================================================================
-- Run in a separate Session B while Session A is blocked in Cell 4.

DECLARE
  v_user_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_RBC_ConfirmGroup';
  ResourceManagement.publish_group_reservation_event(
    p_context_identifier => 'MANUAL_RBC_ConfirmGroup',
    p_user_id            => v_user_id,
    p_category_name      => 'MANUAL_RBC_Category',
    p_action             => 'CONFIRM'
  );
  DBMS_OUTPUT.PUT_LINE('Cell 4b: published CONFIRM for the group.');
END;
/
PROMPT Cell 4b done: published CONFIRM event

-- =============================================================================
-- Cell 5: Assert – 3 journals confirmed, active_count=3, available=7
-- =============================================================================

DECLARE
  v_ctx_id        NUMBER;
  v_confirmed_cnt NUMBER;
  v_active        NUMBER;
  v_avail         NUMBER;
BEGIN
  SELECT id INTO v_ctx_id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_ConfirmGroup';
  SELECT COUNT(*) INTO v_confirmed_cnt
  FROM CurrentAllocations WHERE context_id = v_ctx_id AND status = 'confirmed';
  SELECT c.active_count INTO v_active FROM Capacity c
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE c.context_id = v_ctx_id AND rc.name = 'MANUAL_RBC_Category';
  v_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_RBC_ConfirmGroup', 'MANUAL_RBC_Category');

  DBMS_OUTPUT.PUT_LINE('Cell 5: confirmed=' || v_confirmed_cnt || ', active=' || v_active || ', available=' || v_avail ||
    CASE WHEN v_confirmed_cnt = 3 AND v_active = 3 AND v_avail = 7 THEN ' [PASS]' ELSE ' [FAIL]' END);
END;
/
PROMPT Cell 5 done: confirm-all assertions

-- =============================================================================
-- Cell 6: Teardown
-- =============================================================================

DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_ConfirmGroup');
DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_ConfirmGroup');
DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_ConfirmGroup');
DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_ConfirmGroup';
DELETE FROM ResourceInstance  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_ConfirmGroup');
DELETE FROM AssetCapacity     WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_ConfirmGroup');
DELETE FROM ResourceAsset     WHERE name = 'MANUAL_Asset_RBC_ConfirmGroup';
DELETE FROM Users             WHERE name = 'MANUAL_User_RBC_ConfirmGroup';
DELETE FROM ResourceCategory  WHERE name = 'MANUAL_RBC_Category';
COMMIT;
PROMPT Cell 6 done: Teardown
