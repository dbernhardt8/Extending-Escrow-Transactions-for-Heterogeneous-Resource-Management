-- =============================================================================
-- MANUAL_ReserveByCategory_Timeout.sql
-- =============================================================================
-- Manual, cell-style test: ReserveByCategory (pool group) – AQ TIMEOUT path.
-- Single session: caller blocks for p_timeout_minutes with no publisher; on
-- e_aq_timeout (-25228) all N journals are cancelled in lock-step.
--
-- Cell index:
--   0  Cleanup
--   1  Reference data
--   2  Data Setup
--   3  Assert: context + capacity init
--   4  Act: ReserveByCategory(qty=2, timeout 1 min) – will time out
--   5  Assert: 2 journals cancelled, active_count=0, available=10
--   6  Teardown
--
-- Test identifier: 'MANUAL_RBC_Timeout'
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_ReserveByCategory_Timeout ===');
  DBMS_OUTPUT.PUT_LINE('2 seats reserved; no publisher; AQ timeout (1 min) cancels all.');
END;
/

-- =============================================================================
-- Cell 0: Cleanup
-- =============================================================================

BEGIN
  DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Timeout');
  DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Timeout');
  DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Timeout');
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Timeout';
  DELETE FROM ResourceInstance  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_Timeout');
  DELETE FROM AssetCapacity     WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_Timeout');
  DELETE FROM ResourceAsset     WHERE name = 'MANUAL_Asset_RBC_Timeout';
  DELETE FROM Users             WHERE name = 'MANUAL_User_RBC_Timeout';
  DELETE FROM ResourceCategory  WHERE name = 'MANUAL_RBC_Cat_Timeout';
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
  SELECT COUNT(*) INTO v_count FROM ResourceCategory WHERE name = 'MANUAL_RBC_Cat_Timeout';
  IF v_count = 0 THEN ResourceManagement_Data.AddResourceCategory('MANUAL_RBC_Cat_Timeout', NULL, 'pool'); END IF;

  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_RBC_Timeout';
  IF v_count = 0 THEN ResourceManagement_Data.AddUser('MANUAL_User_RBC_Timeout'); END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_Timeout';
  IF v_count = 0 THEN ResourceManagement_Data.AddResourceAsset('MANUAL_Asset_RBC_Timeout', NULL, 'active'); END IF;

  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Asset_RBC_Timeout' AND c.name = 'MANUAL_RBC_Cat_Timeout';

  SELECT COUNT(*) INTO v_count FROM AssetCapacity WHERE asset_id = v_asset_id AND category_id = v_category_id;
  IF v_count = 0 THEN ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_category_id, 10); END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceInstance WHERE asset_id = v_asset_id;
  IF v_count = 0 THEN
    FOR i IN 1..10 LOOP
      ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'TO' || i, 'available');
    END LOOP;
  END IF;

  SELECT COUNT(*) INTO v_count FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Timeout';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddAllocationContext(v_asset_id, 'MANUAL_RBC_Timeout', SYSDATE + 1, SYSDATE + 2);
  END IF;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data Setup complete.');
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
  WHERE ac.context_identifier = 'MANUAL_RBC_Timeout' AND rc.name = 'MANUAL_RBC_Cat_Timeout';
  DBMS_OUTPUT.PUT_LINE('Cell 3: total=' || v_total || ', active=' || v_active ||
    CASE WHEN v_total = 10 AND v_active = 0 THEN ' [PASS]' ELSE ' [FAIL]' END);
END;
/
PROMPT Cell 3 done

-- =============================================================================
-- Cell 4: Act – ReserveByCategory(qty=2, timeout 1 min)
-- =============================================================================
-- Blocks ~1 minute (no publisher). On timeout, all 2 journals are cancelled.

DECLARE
  v_user_id     NUMBER;
  v_journal_ids SYS.ODCINUMBERLIST;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_RBC_Timeout';
  ResourceManagement.ReserveByCategory(
    p_context_identifier => 'MANUAL_RBC_Timeout',
    p_category_name      => 'MANUAL_RBC_Cat_Timeout',
    p_user_id            => v_user_id,
    p_quantity           => 2,
    p_timeout_minutes    => 1,
    p_new_journal_ids    => v_journal_ids
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 4: returned with ' || v_journal_ids.COUNT || ' journal(s) (cancelled by timeout).');
END;
/
PROMPT Cell 4 done

-- =============================================================================
-- Cell 5: Assert – all cancelled, active=0, available=10
-- =============================================================================

DECLARE
  v_ctx_id   NUMBER;
  v_ca       NUMBER;
  v_active   NUMBER;
  v_avail    NUMBER;
  v_cancel   NUMBER;
BEGIN
  SELECT id INTO v_ctx_id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Timeout';
  SELECT COUNT(*) INTO v_ca FROM CurrentAllocations WHERE context_id = v_ctx_id;
  SELECT COUNT(*) INTO v_cancel FROM AllocationJournal WHERE context_id = v_ctx_id AND status = 'cancelled';
  SELECT c.active_count INTO v_active FROM Capacity c
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE c.context_id = v_ctx_id AND rc.name = 'MANUAL_RBC_Cat_Timeout';
  v_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_RBC_Timeout', 'MANUAL_RBC_Cat_Timeout');
  DBMS_OUTPUT.PUT_LINE('Cell 5: cancelled=' || v_cancel || ', current_alloc=' || v_ca ||
    ', active=' || v_active || ', available=' || v_avail ||
    CASE WHEN v_cancel >= 2 AND v_ca = 0 AND v_active = 0 AND v_avail = 10 THEN ' [PASS]' ELSE ' [FAIL]' END);
END;
/
PROMPT Cell 5 done

-- =============================================================================
-- Cell 6: Teardown
-- =============================================================================

DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Timeout');
DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Timeout');
DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Timeout');
DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Timeout';
DELETE FROM ResourceInstance  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_Timeout');
DELETE FROM AssetCapacity     WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_Timeout');
DELETE FROM ResourceAsset     WHERE name = 'MANUAL_Asset_RBC_Timeout';
DELETE FROM Users             WHERE name = 'MANUAL_User_RBC_Timeout';
DELETE FROM ResourceCategory  WHERE name = 'MANUAL_RBC_Cat_Timeout';
COMMIT;
PROMPT Cell 6 done: Teardown
