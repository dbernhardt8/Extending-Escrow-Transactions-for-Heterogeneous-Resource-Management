-- =============================================================================
-- MANUAL_ReserveByCategory_Insufficient.sql
-- =============================================================================
-- Manual, cell-style test: ReserveByCategory – not enough capacity.
-- Asks for more seats than the category has; the data layer raises ORA-20001
-- from the RESERVABLE counter (or up-front from GetAvailableSeatCount).
-- After the failure, no journals exist and capacity is unchanged.
--
-- Cell index:
--   0  Cleanup
--   1  Reference data
--   2  Data Setup (capacity = 3 seats)
--   3  Assert: context + capacity init
--   4  Act: ReserveByCategory(qty=5) – expect ORA-20001
--   5  Assert: 0 journals, active_count=0, available=3
--   6  Teardown
--
-- Test identifier: 'MANUAL_RBC_Insufficient'
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_ReserveByCategory_Insufficient ===');
  DBMS_OUTPUT.PUT_LINE('Pool of 3 seats; request 5; expect ORA-20001 and no allocations.');
END;
/

-- =============================================================================
-- Cell 0: Cleanup
-- =============================================================================

BEGIN
  DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Insufficient');
  DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Insufficient');
  DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Insufficient');
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Insufficient';
  DELETE FROM ResourceInstance  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_Insufficient');
  DELETE FROM AssetCapacity     WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_Insufficient');
  DELETE FROM ResourceAsset     WHERE name = 'MANUAL_Asset_RBC_Insufficient';
  DELETE FROM Users             WHERE name = 'MANUAL_User_RBC_Insufficient';
  DELETE FROM ResourceCategory  WHERE name = 'MANUAL_RBC_Cat_Insufficient';
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
-- Cell 2: Data Setup – pool of 3 seats only
-- =============================================================================

DECLARE v_count NUMBER; v_asset_id NUMBER; v_category_id NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM ResourceCategory WHERE name = 'MANUAL_RBC_Cat_Insufficient';
  IF v_count = 0 THEN ResourceManagement_Data.AddResourceCategory('MANUAL_RBC_Cat_Insufficient', NULL, 'pool'); END IF;

  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_RBC_Insufficient';
  IF v_count = 0 THEN ResourceManagement_Data.AddUser('MANUAL_User_RBC_Insufficient'); END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_Insufficient';
  IF v_count = 0 THEN ResourceManagement_Data.AddResourceAsset('MANUAL_Asset_RBC_Insufficient', NULL, 'active'); END IF;

  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Asset_RBC_Insufficient' AND c.name = 'MANUAL_RBC_Cat_Insufficient';

  SELECT COUNT(*) INTO v_count FROM AssetCapacity WHERE asset_id = v_asset_id AND category_id = v_category_id;
  IF v_count = 0 THEN ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_category_id, 3); END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceInstance WHERE asset_id = v_asset_id;
  IF v_count = 0 THEN
    FOR i IN 1..3 LOOP
      ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'IS' || i, 'available');
    END LOOP;
  END IF;

  SELECT COUNT(*) INTO v_count FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Insufficient';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddAllocationContext(v_asset_id, 'MANUAL_RBC_Insufficient', SYSDATE + 1, SYSDATE + 2);
  END IF;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data Setup complete (capacity = 3).');
END;
/
PROMPT Cell 2 done

-- =============================================================================
-- Cell 3: Assert init (total=3)
-- =============================================================================

DECLARE v_total NUMBER; v_active NUMBER;
BEGIN
  SELECT c.total_capacity, c.active_count INTO v_total, v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE ac.context_identifier = 'MANUAL_RBC_Insufficient' AND rc.name = 'MANUAL_RBC_Cat_Insufficient';
  DBMS_OUTPUT.PUT_LINE('Cell 3: total=' || v_total || ', active=' || v_active ||
    CASE WHEN v_total = 3 AND v_active = 0 THEN ' [PASS]' ELSE ' [FAIL]' END);
END;
/
PROMPT Cell 3 done

-- =============================================================================
-- Cell 4: Act – ReserveByCategory(qty=5) – expect ORA-20001
-- =============================================================================

DECLARE
  v_user_id     NUMBER;
  v_journal_ids SYS.ODCINUMBERLIST;
  e_capacity_exhausted EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_capacity_exhausted, -20001);
  v_caught BOOLEAN := FALSE;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_RBC_Insufficient';
  BEGIN
    ResourceManagement.ReserveByCategory(
      p_context_identifier => 'MANUAL_RBC_Insufficient',
      p_category_name      => 'MANUAL_RBC_Cat_Insufficient',
      p_user_id            => v_user_id,
      p_quantity           => 5,
      p_timeout_minutes    => 1,
      p_new_journal_ids    => v_journal_ids
    );
  EXCEPTION
    WHEN e_capacity_exhausted THEN
      v_caught := TRUE;
      DBMS_OUTPUT.PUT_LINE('Cell 4: caught ORA-20001 as expected: ' || SUBSTR(SQLERRM, 1, 200) || ' [PASS]');
  END;
  IF NOT v_caught THEN
    DBMS_OUTPUT.PUT_LINE('Cell 4: expected ORA-20001 but call succeeded with ' ||
      CASE WHEN v_journal_ids IS NULL THEN 'NULL list' ELSE v_journal_ids.COUNT || ' journals' END || ' [FAIL]');
  END IF;
END;
/
PROMPT Cell 4 done

-- =============================================================================
-- Cell 5: Assert – no journals, no allocations, available unchanged
-- =============================================================================

DECLARE
  v_ctx_id NUMBER;
  v_aj     NUMBER;
  v_ca     NUMBER;
  v_active NUMBER;
  v_avail  NUMBER;
BEGIN
  SELECT id INTO v_ctx_id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Insufficient';
  SELECT COUNT(*) INTO v_aj FROM AllocationJournal WHERE context_id = v_ctx_id;
  SELECT COUNT(*) INTO v_ca FROM CurrentAllocations WHERE context_id = v_ctx_id;
  SELECT c.active_count INTO v_active FROM Capacity c
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE c.context_id = v_ctx_id AND rc.name = 'MANUAL_RBC_Cat_Insufficient';
  v_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_RBC_Insufficient', 'MANUAL_RBC_Cat_Insufficient');
  DBMS_OUTPUT.PUT_LINE('Cell 5: journals=' || v_aj || ', current_alloc=' || v_ca ||
    ', active=' || v_active || ', available=' || v_avail ||
    CASE WHEN v_aj = 0 AND v_ca = 0 AND v_active = 0 AND v_avail = 3 THEN ' [PASS]' ELSE ' [FAIL]' END);
END;
/
PROMPT Cell 5 done

-- =============================================================================
-- Cell 6: Teardown
-- =============================================================================

DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Insufficient');
DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Insufficient');
DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Insufficient');
DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_RBC_Insufficient';
DELETE FROM ResourceInstance  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_Insufficient');
DELETE FROM AssetCapacity     WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_RBC_Insufficient');
DELETE FROM ResourceAsset     WHERE name = 'MANUAL_Asset_RBC_Insufficient';
DELETE FROM Users             WHERE name = 'MANUAL_User_RBC_Insufficient';
DELETE FROM ResourceCategory  WHERE name = 'MANUAL_RBC_Cat_Insufficient';
COMMIT;
PROMPT Cell 6 done: Teardown
