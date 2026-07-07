-- =============================================================================
-- MANUAL_TypeSubstitution_Partial.sql
-- =============================================================================
-- PREREQUISITE: Compile ResourceManagement first (sql/3.1_database_specification.pks
--               and sql/3.2_database_body.pkb).
--
-- This test now uses the AQ-driven "subscribing main transaction" offer flow:
--   ResourceManagement.MakeReservationWithAlternative(...)  -- BLOCKS in Session A
--   ResourceManagement.publish_offer_decision(...)          -- run from Session B
--
-- Manual test: Partial type substitution (p_include_partial_original => 'Y').
-- 4 categories (Economy, Premium, Business, First). Economy has 1 available
-- seat; request 2 seats. Alternatives are resolved automatically from the
-- CategorySubstitution table (auto_offer = 'Y'). p_include_partial_original='Y'
-- means the original Economy seat is also reserved as part of the offer; the
-- substitute batches each get LEAST(available, remaining) seats. The user
-- then picks ONE substitute category in Cell 5b -- those seats plus the
-- original Economy seat are confirmed, the rest compensated.
--
-- TWO-SESSION DEMO
-- ----------------
--   Session A: Cells 0..5 (Cell 5 blocks).
--   Session B: Cell 5b (CONFIRM) OR Cell 6b (CANCEL) OR Cell 6c (timeout).
--   Session A: Cells 7a/7b/7c (assert) + Cell 8 (teardown).
--
-- Cell index:
--   0   Cleanup
--   1   Reference data
--   2   Data Setup (categories + auto_offer substitution rules + capacities + instances)
--   3   Assert: 4 Capacity rows
--   4   Assert: Economy available=1, FindSubstitutions returns 3 rows
--   5   Session A: MakeReservationWithAlternative (BLOCKS)
--   5b  Session B: peek options + publish_offer_decision CONFIRM
--   6b  Session B: publish_offer_decision CANCEL
--   6c  Session B: leave Cell 5 to time out
--   7a/7b/7c  Assert
--   8   Teardown
--
-- Context: MANUAL_Subst_Partial
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

BEGIN
  DBMS_OUTPUT.PUT_LINE('=== MANUAL_TypeSubstitution_Partial ===');
  DBMS_OUTPUT.PUT_LINE('Partial substitution: 1 Economy available, request 2 -> offer 1 Economy + 1 per substitute (auto_offer).');
  DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- Cell 0: Cleanup
-- =============================================================================
DECLARE
  v_j NUMBER; v_aa NUMBER; v_c NUMBER; v_ctx NUMBER; v_ri NUMBER; v_ac NUMBER; v_ra NUMBER; v_u NUMBER;
  v_sub NUMBER; v_rc NUMBER;
BEGIN
  DELETE FROM ActiveAllocation
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Subst_Partial');
  v_aa := SQL%ROWCOUNT;
  DELETE FROM AllocationJournal
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Subst_Partial');
  v_j := SQL%ROWCOUNT;
  DELETE FROM Capacity
  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Subst_Partial');
  v_c := SQL%ROWCOUNT;
  DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_Subst_Partial';
  v_ctx := SQL%ROWCOUNT;
  DELETE FROM ResourceInstance
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Subst_Partial');
  v_ri := SQL%ROWCOUNT;
  DELETE FROM AssetCapacity
  WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Subst_Partial');
  v_ac := SQL%ROWCOUNT;
  DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_Subst_Partial';
  v_ra := SQL%ROWCOUNT;
  DELETE FROM Users WHERE name = 'MANUAL_User_Subst_Partial';
  v_u := SQL%ROWCOUNT;
  DELETE FROM CategorySubstitution
    WHERE from_category_id IN (SELECT id FROM ResourceCategory WHERE name IN ('MANUAL_Partial_Economy', 'MANUAL_Partial_Premium', 'MANUAL_Partial_Business', 'MANUAL_Partial_First'))
       OR to_category_id IN (SELECT id FROM ResourceCategory WHERE name IN ('MANUAL_Partial_Economy', 'MANUAL_Partial_Premium', 'MANUAL_Partial_Business', 'MANUAL_Partial_First'));
  v_sub := SQL%ROWCOUNT;
  DELETE FROM ResourceCategory WHERE name IN ('MANUAL_Partial_Economy', 'MANUAL_Partial_Premium', 'MANUAL_Partial_Business', 'MANUAL_Partial_First');
  v_rc := SQL%ROWCOUNT;
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
EXCEPTION
  WHEN DUP_VAL_ON_INDEX THEN COMMIT;
END;
/

PROMPT Cell 1 done

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
-- Cell 2: Data Setup – 4 categories (Economy 1, Premium 2, Business 2, First 2), 3 substitution rules Economy→Premium/Business/First (auto_offer Y)
-- =============================================================================
DECLARE
  v_count     NUMBER;
  v_eco_id    NUMBER;
  v_prem_id   NUMBER;
  v_bus_id    NUMBER;
  v_first_id  NUMBER;
  v_asset_id  NUMBER;
  v_cnt       NUMBER;
  v_ctx_count NUMBER;
  v_i         NUMBER;
BEGIN
  FOR c IN (
    SELECT 'MANUAL_Partial_Economy' AS nm FROM DUAL UNION ALL
    SELECT 'MANUAL_Partial_Premium' FROM DUAL UNION ALL
    SELECT 'MANUAL_Partial_Business' FROM DUAL UNION ALL
    SELECT 'MANUAL_Partial_First' FROM DUAL
  ) LOOP
    SELECT COUNT(*) INTO v_count FROM ResourceCategory WHERE name = c.nm;
    IF v_count = 0 THEN
      ResourceManagement_Data.AddResourceCategory(c.nm, NULL, 'pool');
    END IF;
  END LOOP;

  SELECT id INTO v_eco_id   FROM ResourceCategory WHERE name = 'MANUAL_Partial_Economy';
  SELECT id INTO v_prem_id  FROM ResourceCategory WHERE name = 'MANUAL_Partial_Premium';
  SELECT id INTO v_bus_id   FROM ResourceCategory WHERE name = 'MANUAL_Partial_Business';
  SELECT id INTO v_first_id FROM ResourceCategory WHERE name = 'MANUAL_Partial_First';
  ResourceManagement_Data.UpdateCategoryHierarchy(v_eco_id, 4, 500);
  ResourceManagement_Data.UpdateCategoryHierarchy(v_prem_id, 3, 1000);
  ResourceManagement_Data.UpdateCategoryHierarchy(v_bus_id, 2, 2500);
  ResourceManagement_Data.UpdateCategoryHierarchy(v_first_id, 1, 5000);

  -- Substitution: Economy → Premium, Business, First (all auto_offer Y)
  FOR r IN (
    SELECT v_eco_id AS from_id, v_prem_id AS to_id FROM DUAL UNION ALL
    SELECT v_eco_id, v_bus_id FROM DUAL UNION ALL
    SELECT v_eco_id, v_first_id FROM DUAL
  ) LOOP
    SELECT COUNT(*) INTO v_count FROM CategorySubstitution WHERE from_category_id = r.from_id AND to_category_id = r.to_id;
    IF v_count = 0 THEN
      ResourceManagement_Data.AddCategorySubstitution(r.from_id, r.to_id, 100, 1, 'Y', 'Y', 'N');
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO v_count FROM Users WHERE name = 'MANUAL_User_Subst_Partial';
  IF v_count = 0 THEN ResourceManagement_Data.AddUser('MANUAL_User_Subst_Partial'); END IF;

  SELECT COUNT(*) INTO v_count FROM ResourceAsset WHERE name = 'MANUAL_Asset_Subst_Partial';
  IF v_count = 0 THEN ResourceManagement_Data.AddResourceAsset('MANUAL_Asset_Subst_Partial', NULL, 'active'); END IF;
  SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Subst_Partial';

  -- Capacity: Economy 1, Premium 2, Business 2, First 2
  FOR r IN (
    SELECT v_eco_id AS cat_id, 1 AS qty FROM DUAL UNION ALL SELECT v_prem_id, 2 FROM DUAL UNION ALL SELECT v_bus_id, 2 FROM DUAL UNION ALL SELECT v_first_id, 2 FROM DUAL
  ) LOOP
    SELECT COUNT(*) INTO v_count FROM AssetCapacity WHERE asset_id = v_asset_id AND category_id = r.cat_id;
    IF v_count = 0 THEN ResourceManagement_Data.AddAssetCapacity(v_asset_id, r.cat_id, r.qty); END IF;
  END LOOP;

  -- Instances: 1 Economy (E1), 2 Premium (P1,P2), 2 Business (B1,B2), 2 First (F1,F2)
  SELECT COUNT(*) INTO v_cnt FROM ResourceInstance WHERE asset_id = v_asset_id AND category_id = v_eco_id;
  IF v_cnt = 0 THEN ResourceManagement_Data.AddResourceInstance(v_asset_id, v_eco_id, 'E1', 'available'); END IF;
  SELECT COUNT(*) INTO v_cnt FROM ResourceInstance WHERE asset_id = v_asset_id AND category_id = v_prem_id;
  IF v_cnt = 0 THEN
    FOR v_i IN 1..2 LOOP ResourceManagement_Data.AddResourceInstance(v_asset_id, v_prem_id, 'P' || v_i, 'available'); END LOOP;
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM ResourceInstance WHERE asset_id = v_asset_id AND category_id = v_bus_id;
  IF v_cnt = 0 THEN
    FOR v_i IN 1..2 LOOP ResourceManagement_Data.AddResourceInstance(v_asset_id, v_bus_id, 'B' || v_i, 'available'); END LOOP;
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM ResourceInstance WHERE asset_id = v_asset_id AND category_id = v_first_id;
  IF v_cnt = 0 THEN
    FOR v_i IN 1..2 LOOP ResourceManagement_Data.AddResourceInstance(v_asset_id, v_first_id, 'F' || v_i, 'available'); END LOOP;
  END IF;

  SELECT COUNT(*) INTO v_ctx_count FROM AllocationContext WHERE context_identifier = 'MANUAL_Subst_Partial';
  IF v_ctx_count = 0 THEN
    ResourceManagement_Data.AddAllocationContext(v_asset_id, 'MANUAL_Subst_Partial', SYSDATE + 1, SYSDATE + 2);
  END IF;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Cell 2: Data Setup complete (4 categories, Economy 1, others 2; Economy->Premium/Business/First auto_offer).');
END;
/

PROMPT Cell 2 done

-- =============================================================================
-- Cell 3: Assert – 4 Capacity rows (Economy 1/0, Premium 2/0, Business 2/0, First 2/0)
-- =============================================================================
SELECT c.context_id, rc.name, c.total_capacity, c.active_count
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'MANUAL_Subst_Partial'
ORDER BY rc.name;

DECLARE
  v_cap_count NUMBER;
  v_eco_avail NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_cap_count FROM Capacity c JOIN AllocationContext ac ON c.context_id = ac.id WHERE ac.context_identifier = 'MANUAL_Subst_Partial';
  v_eco_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_Subst_Partial', 'MANUAL_Partial_Economy');
  IF v_cap_count = 4 AND v_eco_avail = 1 THEN
    DBMS_OUTPUT.PUT_LINE('Cell 3: 4 Capacity rows, Economy available=1 [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 3: cap_count=' || v_cap_count || ', Economy avail=' || v_eco_avail || ' [CHECK]');
  END IF;
END;
/

PROMPT Cell 3 done

-- =============================================================================
-- Cell 4: Assert – Economy available=1; FindSubstitutions returns 3 rows (Premium, Business, First)
-- =============================================================================
DECLARE
  v_eco_avail NUMBER;
  v_rc       SYS_REFCURSOR;
  v_dummy    NUMBER; v_d2 NUMBER; v_d3 VARCHAR2(100); v_d4 NUMBER; v_d5 VARCHAR2(100); v_d6 VARCHAR2(20);
  v_d7 NUMBER; v_d8 NUMBER; v_d9 VARCHAR2(1); v_d10 VARCHAR2(1); v_d11 NUMBER; v_d12 NUMBER;
  v_rows     NUMBER := 0;
BEGIN
  v_eco_avail := ResourceManagement.GetAvailableSeatCount('MANUAL_Subst_Partial', 'MANUAL_Partial_Economy');
  v_rc := ResourceManagement.FindSubstitutions('MANUAL_Subst_Partial', 'MANUAL_Partial_Economy');
  LOOP
    FETCH v_rc INTO v_dummy, v_d2, v_d3, v_d4, v_d5, v_d6, v_d7, v_d8, v_d9, v_d10, v_d11, v_d12;
    EXIT WHEN v_rc%NOTFOUND;
    v_rows := v_rows + 1;
  END LOOP;
  CLOSE v_rc;
  DBMS_OUTPUT.PUT_LINE('Cell 4: Economy available=' || v_eco_avail || ', FindSubstitutions rows=' || v_rows || ' (expect 3)');
END;
/

PROMPT Cell 4 done

SELECT * FROM RESERVJRNL_CAPACITY;

-- =============================================================================
-- Cell 5 [SESSION A]: Act – MakeReservationWithAlternative(Economy, 2)
--   alternatives = NULL (auto-resolved from CategorySubstitution)
--   p_include_partial_original = 'Y' (reserve the lone Economy seat in the
--                                     offer; substitutes fill the rest)
-- THIS CALL BLOCKS for up to p_offer_timeout_minutes minutes waiting for an
-- AQ event from publish_offer_decision (correlation OFFER_<offer_group_id>).
-- ACTION: open a SECOND SQL session and run Cell 5b (CONFIRM) or Cell 6b
-- (CANCEL) while this cell is blocked.
-- =============================================================================
PROMPT *** Cell 5 is about to BLOCK. From a SECOND session run Cell 5b or 6b. ***
DECLARE
  v_user_id           NUMBER;
  v_offer_group_id    VARCHAR2(100);
  v_offer_journal_ids SYS.ODCINUMBERLIST;
  v_jid               NUMBER;
  v_cat_name          VARCHAR2(100);
  i                   PLS_INTEGER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_Subst_Partial';
  DBMS_OUTPUT.PUT_LINE('Cell 5: calling MakeReservationWithAlternative -- blocks until decision...');
  ResourceManagement.MakeReservationWithAlternative(
    p_context_identifier         => 'MANUAL_Subst_Partial',
    p_original_category_name     => 'MANUAL_Partial_Economy',
    p_user_id                    => v_user_id,
    p_quantity                   => 2,
    p_alternative_category_names => NULL,
    p_offer_timeout_minutes      => 5,
    p_include_partial_original   => 'Y',
    p_offer_group_id             => v_offer_group_id,
    p_offer_journal_ids          => v_offer_journal_ids
  );
  DBMS_OUTPUT.PUT_LINE('Cell 5: returned offer_group_id=' || NVL(v_offer_group_id, 'NULL') ||
                       ' journals=' || NVL(v_offer_journal_ids.COUNT, 0));
  IF v_offer_journal_ids IS NOT NULL THEN
    FOR i IN 1..v_offer_journal_ids.COUNT LOOP
      v_jid := v_offer_journal_ids(i);
      BEGIN
        SELECT rc.name INTO v_cat_name
          FROM AllocationJournal aj
          JOIN ResourceInstance  ri ON aj.resource_instance_id = ri.id
          JOIN ResourceCategory  rc ON ri.category_id = rc.id
         WHERE aj.id = v_jid;
        DBMS_OUTPUT.PUT_LINE('  journal_id=' || v_jid || ' category=' || v_cat_name);
      EXCEPTION
        WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE('  journal_id=' || v_jid || ' (category lookup failed: ' || SQLERRM || ')');
      END;
    END LOOP;
  END IF;
END;
/

PROMPT Cell 5 done

-- =============================================================================
-- Cell 5b [SESSION B]: Peek the offer options that Session A logged, then
-- publish a CONFIRM for one of them.
-- =============================================================================
PROMPT *** Cell 5b: peek the offer options Session A logged. ***
SELECT id, message
  FROM DebugLogSorted
 WHERE message LIKE '[OFFER %'
 FETCH FIRST 12 ROWS ONLY;

SELECT JSON_VALUE(aj.metadata, '$.custom.offer_group_id') AS offer_group_id,
       JSON_VALUE(aj.metadata, '$.custom.to_category_name') AS to_category_name,
       aj.id AS journal_id,
       ca.status
  FROM AllocationJournal aj
  JOIN CurrentAllocations ca ON ca.journal_id = aj.id
  JOIN AllocationContext  ac ON ca.context_id = ac.id
  JOIN Users               u ON ca.user_id    = u.id
 WHERE ac.context_identifier = 'MANUAL_Subst_Partial'
   AND u.name                = 'MANUAL_User_Subst_Partial'
   AND JSON_VALUE(aj.metadata, '$.custom.offer_group_id') IS NOT NULL
   AND ca.status = 'reserved'
 ORDER BY aj.id;

DECLARE
  v_user_id                NUMBER;
  v_offer_group_id         VARCHAR2(100) := 'PASTE_OFFER_GROUP_ID_FROM_LOG';
  v_selected_category_name VARCHAR2(100) := 'MANUAL_Partial_Business'; -- or MANUAL_Partial_Premium / MANUAL_Partial_First
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_Subst_Partial';
  IF v_offer_group_id = 'PASTE_OFFER_GROUP_ID_FROM_LOG' THEN
    RAISE_APPLICATION_ERROR(-20010, 'Paste offer_group_id from DebugLog into v_offer_group_id.');
  END IF;
  ResourceManagement.publish_offer_decision(
    p_context_identifier     => 'MANUAL_Subst_Partial',
    p_user_id                => v_user_id,
    p_offer_group_id         => v_offer_group_id,
    p_action                 => 'CONFIRM',
    p_selected_category_name => v_selected_category_name
  );
  DBMS_OUTPUT.PUT_LINE('Cell 5b: CONFIRM published for offer=' || v_offer_group_id ||
                       ' category=' || v_selected_category_name);
END;
/

PROMPT Cell 5b done

-- =============================================================================
-- Cell 6b [SESSION B]: Decline all -- publish CANCEL for the offer group.
-- =============================================================================
DECLARE
  v_user_id        NUMBER;
  v_offer_group_id VARCHAR2(100) := 'PASTE_OFFER_GROUP_ID_FROM_LOG';
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_Subst_Partial';
  IF v_offer_group_id = 'PASTE_OFFER_GROUP_ID_FROM_LOG' THEN
    RAISE_APPLICATION_ERROR(-20010, 'Paste offer_group_id from DebugLog into v_offer_group_id.');
  END IF;
  ResourceManagement.publish_offer_decision(
    p_context_identifier => 'MANUAL_Subst_Partial',
    p_user_id            => v_user_id,
    p_offer_group_id     => v_offer_group_id,
    p_action             => 'CANCEL'
  );
  DBMS_OUTPUT.PUT_LINE('Cell 6b: CANCEL published for offer=' || v_offer_group_id);
END;
/

PROMPT Cell 6b done

-- =============================================================================
-- Cell 6c [SESSION B]: Timeout -- do nothing here. Re-run Cell 5 with a short
-- p_offer_timeout_minutes (e.g. 1) and skip 5b/6b. Session A will time out
-- and DeclineSubstitutionOffer is invoked automatically.
-- =============================================================================
PROMPT *** Cell 6c: run Cell 5 with p_offer_timeout_minutes=>1 and skip 5b/6b. ***

-- =============================================================================
-- Cell 7a: Assert after Cell 5b (CONFIRM) -- user has 2 confirmed allocations
-- (1 Economy + 1 from the selected substitute since partial-original is ON).
-- =============================================================================
DECLARE
  v_total NUMBER;
  v_user_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'MANUAL_User_Subst_Partial';
  SELECT COUNT(*) INTO v_total
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  WHERE ac.context_identifier = 'MANUAL_Subst_Partial'
    AND ca.user_id = v_user_id
    AND ca.status = 'confirmed';
  IF v_total = 2 THEN
    DBMS_OUTPUT.PUT_LINE('Cell 7a: Accept path -- 2 confirmed allocations (1 Economy + 1 substitute) [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 7a: Expected 2 confirmed, actual ' || v_total || ' [FAIL]');
  END IF;
END;
/

PROMPT Cell 7a done

-- =============================================================================
-- Cell 7b: Assert after Cell 6b (CANCEL) -- all available restored.
-- =============================================================================
DECLARE
  v_eco NUMBER; v_prem NUMBER; v_bus NUMBER; v_first NUMBER;
BEGIN
  v_eco   := ResourceManagement.GetAvailableSeatCount('MANUAL_Subst_Partial', 'MANUAL_Partial_Economy');
  v_prem  := ResourceManagement.GetAvailableSeatCount('MANUAL_Subst_Partial', 'MANUAL_Partial_Premium');
  v_bus   := ResourceManagement.GetAvailableSeatCount('MANUAL_Subst_Partial', 'MANUAL_Partial_Business');
  v_first := ResourceManagement.GetAvailableSeatCount('MANUAL_Subst_Partial', 'MANUAL_Partial_First');
  IF v_eco = 1 AND v_prem = 2 AND v_bus = 2 AND v_first = 2 THEN
    DBMS_OUTPUT.PUT_LINE('Cell 7b: Decline path -- all available restored [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 7b: Economy=' || v_eco || ' Premium=' || v_prem || ' Business=' || v_bus || ' First=' || v_first);
  END IF;
END;
/

PROMPT Cell 7b done

-- =============================================================================
-- Cell 7c: Assert after Cell 6c (timeout) -- same end-state as decline.
-- =============================================================================
DECLARE
  v_eco NUMBER; v_prem NUMBER; v_bus NUMBER; v_first NUMBER;
BEGIN
  v_eco   := ResourceManagement.GetAvailableSeatCount('MANUAL_Subst_Partial', 'MANUAL_Partial_Economy');
  v_prem  := ResourceManagement.GetAvailableSeatCount('MANUAL_Subst_Partial', 'MANUAL_Partial_Premium');
  v_bus   := ResourceManagement.GetAvailableSeatCount('MANUAL_Subst_Partial', 'MANUAL_Partial_Business');
  v_first := ResourceManagement.GetAvailableSeatCount('MANUAL_Subst_Partial', 'MANUAL_Partial_First');
  IF v_eco = 1 AND v_prem = 2 AND v_bus = 2 AND v_first = 2 THEN
    DBMS_OUTPUT.PUT_LINE('Cell 7c: Timeout path -- all available restored [PASS]');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Cell 7c: Economy=' || v_eco || ' Premium=' || v_prem || ' Business=' || v_bus || ' First=' || v_first);
  END IF;
END;
/

PROMPT Cell 7c done

-- =============================================================================
-- Cell 8: Teardown
-- =============================================================================
DELETE FROM ActiveAllocation WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Subst_Partial');
DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Subst_Partial');
DELETE FROM Capacity WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'MANUAL_Subst_Partial');
DELETE FROM AllocationContext WHERE context_identifier = 'MANUAL_Subst_Partial';
DELETE FROM ResourceInstance WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Subst_Partial');
DELETE FROM AssetCapacity WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'MANUAL_Asset_Subst_Partial');
DELETE FROM ResourceAsset WHERE name = 'MANUAL_Asset_Subst_Partial';
DELETE FROM Users WHERE name = 'MANUAL_User_Subst_Partial';
DELETE FROM CategorySubstitution
  WHERE from_category_id IN (SELECT id FROM ResourceCategory WHERE name IN ('MANUAL_Partial_Economy', 'MANUAL_Partial_Premium', 'MANUAL_Partial_Business', 'MANUAL_Partial_First'))
     OR to_category_id IN (SELECT id FROM ResourceCategory WHERE name IN ('MANUAL_Partial_Economy', 'MANUAL_Partial_Premium', 'MANUAL_Partial_Business', 'MANUAL_Partial_First'));
DELETE FROM ResourceCategory WHERE name IN ('MANUAL_Partial_Economy', 'MANUAL_Partial_Premium', 'MANUAL_Partial_Business', 'MANUAL_Partial_First');
COMMIT;
BEGIN DBMS_OUTPUT.PUT_LINE('Cell 8: Teardown complete.'); END;
/
PROMPT Cell 8 done
