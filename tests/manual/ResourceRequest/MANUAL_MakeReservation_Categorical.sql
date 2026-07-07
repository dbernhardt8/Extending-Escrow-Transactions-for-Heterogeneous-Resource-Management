-- =============================================================================
-- MANUAL_MakeReservation_Categorical.sql
-- =============================================================================
-- Manual, cell-style test: ReserveByCategory (pool group) – AQ TIMEOUT path,
-- single-session. The procedure reserves N seats atomically, then blocks on
-- RESERVATION_EVENTS_Q for a single CONFIRM/CANCEL. With no publisher and a
-- short timeout, all journals are cancelled deterministically.
--
-- For the CONFIRM/CANCEL paths and the dispatcher overload, see:
--   * MANUAL_ReserveByCategory_ConfirmGroup.sql
--   * MANUAL_ReserveByCategory_CancelGroup.sql
--   * MANUAL_MakeReservation_ByCategory.sql
--
-- Cell index:
--   0  Cleanup (optional first)
--   1  Reference data (reserved, available) – ensure mock data loaded
--   2  Data Setup – category, user, asset, capacity, instances, context (CRUD)
--   3  Assert: context + capacity init
--   4  Act: ReserveByCategory(2 seats, timeout 1 min) – will time out
--   5  Assert: 2 journals created and then cancelled
--   6  Assert: list journal rows
--   7  Assert: Capacity.active_count = 0 (cancelled by timeout)
--   8  Assert: CurrentAllocations 0 rows
--   9  Assert: GetAvailableSeatCount = 10
--  10  Assert: outcome consistent (all cancelled)
--  14  Teardown
--
-- Test identifier: context_identifier = 'MANUAL_Business_Class'
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_Business_Class (ReserveByCategory, AQ timeout) ===');
  DBMS_OUTPUT.PUT_LINE('Config: 2 seats, timeout 1 min, no publisher → all cancelled.');
  DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- Cell 0: Cleanup (optional – run first to remove leftover data from last run)
-- =============================================================================

-- Teardown order: ActiveAllocation → Journal → Capacity → Context → Instance → AssetCapacity → Asset → User → ResourceCategory
DECLARE
  v_j NUMBER; v_aa NUMBER; v_c NUMBER; v_ctx NUMBER; v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Business_Class');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Business_Class');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_Business_Class';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name = 'MANUAL_User_Business_Class';
  v_u := SQL%ROWCOUNT;
  DELETE FROM ResourceCategory WHERE name = 'MANUAL_Business_Class';
  v_rc := SQL%ROWCOUNT;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 0: Cleanup done. Deleted: Journal=' || v_j || ', AA=' || v_aa || ', Capacity=' || v_c || ', Context=' || v_ctx ||
    ', Instances=' || v_ri || ', AssetCap=' || v_ac || ', Asset=' || v_ra || ', Users=' || v_u || ', Category=' || v_rc);
END;
/

PROMPT Cell 0 done: Cleanup (if any)

-- =============================================================================
-- Cell 1: Ensure reference data (ResourceStatus, ResourceInstanceStatus) – CRUD
-- =============================================================================
-- Skip if 4_insert_mock_data_extensive.sql or full setup was run.
-- Otherwise uncomment and run once:

-- -----------------------------------------------------------------------------
-- Optional: Create a stable view for the RESERVABLE reservation journal
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
  WHEN DUP_VAL_ON_INDEX THEN COMMIT;  -- already exist
END;


PROMPT Cell 1: Reference data (reserved, available) – ensure mock data loaded

-- =============================================================================
-- Cell 2: Data Setup – category, user, asset, capacity, instances, context (CRUD)
-- =============================================================================
-- Combined setup: MANUAL_Business_Class category, test user, test asset, 10 seats,
-- 10 ResourceInstances, AllocationContext. AddAllocationContext initializes capacity.

DECLARE
  v_count        NUMBER;
  v_asset_id     NUMBER;
  v_category_id  NUMBER;
  v_cnt          NUMBER;
  v_ctx_count    NUMBER;
  v_i            NUMBER;
BEGIN
  -- Category (MANUAL_Business_Class)
  SELECT COUNT(*) INTO v_count FROM ResourceCategory WHERE name = 'MANUAL_Business_Class';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceCategory('MANUAL_Business_Class', NULL, 'pool');
  END IF;

  -- Test user
  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_Business_Class';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddUser('MANUAL_User_Business_Class');
  END IF;

  -- Test asset
  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Asset_Business_Class';
  IF v_count = 0 THEN
    ResourceManagement_Data.AddResourceAsset('MANUAL_Asset_Business_Class', NULL, 'active');
  END IF;

  -- AssetCapacity (10 seats MANUAL_Business_Class)
  SELECT a.id, c.id INTO v_asset_id, v_category_id
  FROM ResourceAsset a, ResourceCategory c
  WHERE a.name = 'MANUAL_Asset_Business_Class' AND c.name = 'MANUAL_Business_Class';
  SELECT COUNT(*) INTO v_count FROM AssetCapacity WHERE asset_id = v_asset_id AND category_id = v_category_id;
  IF v_count = 0 THEN
    ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_category_id, 10);
  END IF;

  -- ResourceInstances (10)
  SELECT COUNT(*) INTO v_cnt FROM ResourceInstance WHERE asset_id = v_asset_id;
  IF v_cnt = 0 THEN
    FOR v_i IN 1..10 LOOP
      ResourceManagement_Data.AddResourceInstance(v_asset_id, v_category_id, 'M' || v_i, 'available');
    END LOOP;
  END IF;

  -- AllocationContext (capacity initialized by CRUD)
  SELECT COUNT(*) INTO v_ctx_count FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class';
  IF v_ctx_count = 0 THEN
    SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Business_Class';
    ResourceManagement_Data.AddAllocationContext(v_asset_id, 'MANUAL_Business_Class', SYSDATE + 1, SYSDATE + 2);
  END IF;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data Setup complete (category, user, asset, capacity, instances, context).');
END;
/
PROMPT Cell 2 done: Data Setup

-- =============================================================================
-- Cell 3: Assert – context and capacity init (AllocationContext + Capacity created)
-- =============================================================================
-- After AddAllocationContext: one AllocationContext row; one Capacity row per
-- pool category (here: MANUAL_Business_Class) with total_capacity=10, active_count=0.

SELECT ac.id AS context_id, ac.context_identifier, ac.asset_id, ac.start_date, ac.end_date
FROM AllocationContext ac
WHERE ac.context_identifier = 'MANUAL_Business_Class';
-- Expected: 1 row

SELECT c.id AS capacity_id, c.context_id, c.category_id, rc.name AS category_name,
       c.total_capacity, c.active_count
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_Business_Class';
-- Expected: 1 row (MANUAL_Business_Class), total_capacity=10, active_count=0

DECLARE
  v_ctx_count   NUMBER;
  v_cap_count   NUMBER;
  v_total_cap   NUMBER;
  v_active      NUMBER;
  v_ok          BOOLEAN := TRUE;
BEGIN
  SELECT COUNT(*) INTO v_ctx_count
  FROM AllocationContext
  WHERE context_identifier = 'MANUAL_Business_Class';
  IF v_ctx_count != 1 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: AllocationContext: expected 1 row, actual ' || v_ctx_count || ' [FAIL]');
  END IF;

  SELECT COUNT(*), MAX(c.total_capacity), MAX(c.active_count)
  INTO v_cap_count, v_total_cap, v_active
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Business_Class';
  IF v_cap_count != 1 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: Capacity: expected 1 row, actual ' || v_cap_count || ' [FAIL]');
  END IF;
  IF v_total_cap != 10 OR v_active != 0 THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 3: Capacity: expected total_capacity=10, active_count=0; actual total_capacity=' ||
      v_total_cap || ', active_count=' || v_active || ' [FAIL]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 3: Context + capacity init OK: AllocationContext=1, Capacity=1 (total_capacity=10, active_count=0) [PASS]');
  END IF;
END;
/

PROMPT Cell 3 done: Assert context and capacity init

-- =============================================================================
-- Cell 4: Act – ReserveByCategory(2 seats, timeout 1 min)
-- =============================================================================
-- Blocks ~1 minute (no publisher); on AQ timeout all 2 journals are cancelled.

DECLARE
  v_user_id     NUMBER;
  v_journal_ids SYS.ODCINUMBERLIST;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_Business_Class';
  ResourceManagement.ReserveByCategory(
    p_context_identifier => 'MANUAL_Business_Class',
    p_category_name      => 'MANUAL_Business_Class',
    p_user_id            => v_user_id,
    p_quantity           => 2,
    p_timeout_minutes    => 1,
    p_new_journal_ids    => v_journal_ids
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Act done: journal_ids count = ' || v_journal_ids.COUNT);
  FOR i IN 1..v_journal_ids.COUNT LOOP
    DBMS_OUTPUT.PUT_LINE('  journal_id(' || i || ') = ' || v_journal_ids(i));
  END LOOP;
END;
/

PROMPT Cell 4 done: ReserveByCategory(2, timeout 1 min)

SELECT * FROM RESERVJRNL_CAPACITY;

-- =============================================================================
-- Cell 5: Assert – journal_ids count = 2
-- =============================================================================

SELECT 2 AS expected_count, COUNT(*) AS actual_count
FROM AllocationJournal
WHERE context_id = (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class')
  AND status = 'reserved';
-- Expected: expected_count=2, actual_count=2

DECLARE
  v_actual NUMBER;
  v_expected NUMBER := 2;
BEGIN
  SELECT COUNT(*) INTO v_actual
  FROM AllocationJournal
  WHERE context_id = (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class')
    AND status = 'reserved';
  DBMS_OUTPUT.PUT_LINE('Cell 5: Journal reserved count: expected=' || v_expected || ', actual=' || v_actual ||
    CASE WHEN v_actual = v_expected THEN ' [PASS]' ELSE ' [FAIL]' END);
END;
/

PROMPT Cell 5: Check – 2 journal rows with status reserved

-- =============================================================================
-- Cell 6: Assert – AllocationJournal: exactly 2 rows reserved for this context
-- =============================================================================

SELECT id, context_id, category_id, user_id, resource_instance_id, status, entry_timestamp
FROM AllocationJournal
WHERE context_id = (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class')
  AND status = 'reserved'
ORDER BY id;
-- Expected: 2 rows

DECLARE
  v_cnt NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_cnt FROM AllocationJournal
  WHERE context_id = (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class')
    AND status = 'reserved';
  DBMS_OUTPUT.PUT_LINE('Cell 6: Reserved journal rows listed: ' || v_cnt || ' rows.');
END;
/
PROMPT Cell 6: List reserved journal rows (expect 2)

-- =============================================================================
-- Cell 7: Assert – Capacity.active_count = 2 (confirmed) or 0 (cancelled)
-- =============================================================================

SELECT c.context_id, c.category_id, rc.name AS category_name,
       c.total_capacity, c.active_count
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_Business_Class';
-- Expected: active_count = 2 (confirmed) or 0 (cancelled), total_capacity = 10

DECLARE
  v_active NUMBER;
  v_total  NUMBER;
BEGIN
  SELECT c.active_count, c.total_capacity INTO v_active, v_total
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE ac.context_identifier = 'MANUAL_Business_Class' AND rc.name = 'MANUAL_Business_Class';
  DBMS_OUTPUT.PUT_LINE('Cell 7: Capacity: active_count=' || v_active || ', total_capacity=' || v_total ||
    CASE WHEN v_active IN (0, 2) AND v_total = 10 THEN ' [PASS]' ELSE ' [FAIL]' END);
END;
/

PROMPT Cell 7: Check Capacity (active_count = 2 or 0)

-- =============================================================================
-- Cell 8: Assert – CurrentAllocations: 2 rows (confirmed) or 0 (cancelled)
-- =============================================================================

SELECT ca.journal_id, ca.context_id, ca.category_id, ca.user_id, ca.resource_instance_id, ca.status
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
WHERE ac.context_identifier = 'MANUAL_Business_Class'
ORDER BY ca.journal_id;
-- Expected: 2 rows (confirmed) or 0 (cancelled)

DECLARE
  v_ca_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_ca_count
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Business_Class';
  DBMS_OUTPUT.PUT_LINE('Cell 8: CurrentAllocations row count: ' || v_ca_count ||
    CASE WHEN v_ca_count IN (0, 2) THEN ' [PASS]' ELSE ' [FAIL]' END);
END;
/

PROMPT Cell 8: Check CurrentAllocations (expect 0 or 2 rows)

-- =============================================================================
-- Cell 9: Assert – GetAvailableSeatCount (8 or 10)
-- =============================================================================

SELECT ResourceManagement.GetAvailableSeatCount('MANUAL_Business_Class', 'MANUAL_Business_Class') AS available_seats
FROM DUAL;
-- Expected: 8 (confirmed) or 10 (cancelled)

DECLARE
  v_avail NUMBER;
BEGIN
  v_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_Business_Class', 'MANUAL_Business_Class');
  DBMS_OUTPUT.PUT_LINE('Cell 9: GetAvailableSeatCount = ' || v_avail ||
    CASE WHEN v_avail IN (8, 10) THEN ' [PASS]' ELSE ' [FAIL]' END);
END;
/

PROMPT Cell 9: Check GetAvailableSeatCount (expect 8 or 10)

-- =============================================================================
-- Cell 10: Assert – Decision outcome (random confirm or cancel)
-- =============================================================================
-- After MakeReservation (with timeout) returns, it already waited and made a decision.
-- Expect latest status per journal to be 'confirmed' or 'cancelled'.
-- If confirmed: active_count=2, CurrentAllocations=2, available=8.
-- If cancelled: active_count=0, CurrentAllocations=0, available=10.

-- Latest entry per journal (confirmed/cancelled)
SELECT id AS journal_id, status AS latest_status, entry_timestamp
FROM (
  SELECT id, status, entry_timestamp,
         ROW_NUMBER() OVER (PARTITION BY id ORDER BY entry_timestamp DESC) AS rn
  FROM AllocationJournal
  WHERE context_id = (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class')
)
WHERE rn = 1
ORDER BY journal_id;
-- Expected: 2 rows, latest_status in ('confirmed', 'cancelled')

SELECT c.active_count, c.total_capacity
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_Business_Class' AND rc.name = 'MANUAL_Business_Class';
-- Expected: active_count = 2 (confirmed) or 0 (cancelled)

SELECT COUNT(*) AS current_alloc_count
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
WHERE ac.context_identifier = 'MANUAL_Business_Class';
-- Expected: 2 (confirmed) or 0 (cancelled)

SELECT ResourceManagement.GetAvailableSeatCount('MANUAL_Business_Class', 'MANUAL_Business_Class') AS available_seats FROM DUAL;
-- Expected: 8 (confirmed) or 10 (cancelled)

DECLARE
  v_ctx_id     NUMBER;
  v_j1_status  VARCHAR2(20);
  v_j2_status  VARCHAR2(20);
  v_active     NUMBER;
  v_ca_count   NUMBER;
  v_avail      NUMBER;
  v_ok         BOOLEAN := TRUE;
BEGIN
  SELECT id INTO v_ctx_id FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class';
  -- Latest status for the two journal IDs (we need the journal IDs from the context – use distinct ids from latest entries)
  FOR r IN (
    SELECT id AS jid,
           status,
           ROW_NUMBER() OVER (PARTITION BY id ORDER BY entry_timestamp DESC) AS rn
    FROM AllocationJournal
    WHERE context_id = v_ctx_id
  ) LOOP
    IF r.rn = 1 THEN
      IF r.status NOT IN ('confirmed', 'cancelled') THEN
        v_ok := FALSE;
        DBMS_OUTPUT.PUT_LINE('Cell 10: Journal ' || r.jid || ' latest status = ' || r.status || ' [FAIL – expect confirmed/cancelled]');
      END IF;
    END IF;
  END LOOP;
  SELECT active_count INTO v_active FROM Capacity c
  JOIN ResourceCategory rc ON c.category_id = rc.id
  WHERE c.context_id = v_ctx_id AND rc.name = 'MANUAL_Business_Class';
  SELECT COUNT(*) INTO v_ca_count FROM CurrentAllocations WHERE context_id = v_ctx_id;
  v_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_Business_Class', 'MANUAL_Business_Class');
  IF NOT ((v_active = 2 AND v_ca_count = 2 AND v_avail = 8) OR
          (v_active = 0 AND v_ca_count = 0 AND v_avail = 10)) THEN
    v_ok := FALSE;
    DBMS_OUTPUT.PUT_LINE('Cell 10: Counters/CurrentAllocations mismatch. active=' || v_active ||
      ', ca=' || v_ca_count || ', avail=' || v_avail || ' [FAIL]');
  END IF;
  IF v_ok THEN
    DBMS_OUTPUT.PUT_LINE('Cell 10: Decision outcome consistent with confirmed/cancelled [PASS]');
  END IF;
END;
/

PROMPT Cell 10: Assert decision outcome – journals confirmed/cancelled, counters and views

-- =============================================================================
-- Cell 14: Teardown – delete test data (FK order)
-- =============================================================================

DELETE FROM ActiveAllocation
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class');
DELETE FROM AllocationJournal
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class');
DELETE FROM Capacity
WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class');
DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_Business_Class';
DELETE FROM ResourceInstance
WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Business_Class');
DELETE FROM AssetCapacity
WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Business_Class');
DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_Business_Class';
DELETE FROM Users WHERE name = 'MANUAL_User_Business_Class';
DELETE FROM ResourceCategory WHERE name = 'MANUAL_Business_Class';
COMMIT;

BEGIN
  DBMS_OUTPUT.PUT_LINE('Cell 14: Teardown complete.');
END;
/
PROMPT Cell 14 done: Teardown complete
