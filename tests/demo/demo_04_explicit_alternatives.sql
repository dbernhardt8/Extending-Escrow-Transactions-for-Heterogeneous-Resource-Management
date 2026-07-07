-- =============================================================================
-- demo_04_explicit_alternatives.sql
-- =============================================================================
-- Interactive demo: explicit-alternative substitution offer.
--
-- 3 categories share an asset:
--   * DEMO_EXPL_Economy   (1 seat)
--   * DEMO_EXPL_Business  (2 seats)
--   * DEMO_EXPL_First     (2 seats)
-- User asks for 2 Economy seats with alternatives explicitly listed:
-- "DEMO_EXPL_Business,DEMO_EXPL_First". Since Economy has only 1 available,
-- MakeReservationWithAlternative reserves 2 Business + 2 First as an OFFER
-- group (same offer_group_id, same metadata), logs the option mapping to
-- DebugLog, and blocks on RESERVATION_EVENTS_Q with correlation
-- OFFER_<offer_group_id>.
--
-- Session B then picks ONE of the printed categories and publishes the
-- decision via publish_offer_decision. The matching seats are confirmed and
-- the rest are compensated (cancelled with metadata).
--
-- Run:    @demo_04_explicit_alternatives.sql      (in Session A)
-- =============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
SET DEFINE OFF
SET FEEDBACK ON
SET SQLBLANKLINES ON

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 04 - Type substitution: EXPLICIT alternatives
PROMPT =============================================================================
PROMPT
PROMPT  Scenario: 1 Economy, 2 Business, 2 First. Traveller asks for 2 Economy
PROMPT  but accepts Business or First. Session A reserves an OFFER GROUP and
PROMPT  blocks for the operators choice.
PROMPT
PAUSE  Press ENTER to clean up any previous demo data and start setup...

-- =============================================================================
-- Step 1: Cleanup
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_EXPL')]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_EXPL')]');
  silent_delete(q'[DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_EXPL')]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier = 'DEMO_EXPL']');
  silent_delete(q'[DELETE FROM ResourceInstance WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_EXPL_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity    WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_EXPL_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset    WHERE name = 'DEMO_EXPL_ASSET']');
  silent_delete(q'[DELETE FROM Users            WHERE name = 'DEMO_EXPL_USER']');
  silent_delete(q'[DELETE FROM CategorySubstitution
                   WHERE from_category_id IN (SELECT id FROM ResourceCategory WHERE name IN ('DEMO_EXPL_Economy','DEMO_EXPL_Business','DEMO_EXPL_First'))
                      OR to_category_id   IN (SELECT id FROM ResourceCategory WHERE name IN ('DEMO_EXPL_Economy','DEMO_EXPL_Business','DEMO_EXPL_First'))]');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name IN ('DEMO_EXPL_Economy','DEMO_EXPL_Business','DEMO_EXPL_First')]');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 1: previous demo data cleaned.');
END;
/

DELETE FROM DebugLog;
COMMIT;

-- =============================================================================
-- Step 2: Setup (3 categories, 1+2+2 seats)
-- =============================================================================
DECLARE
  v_asset_id NUMBER;
  v_eco      NUMBER;
  v_bus      NUMBER;
  v_first    NUMBER;
  v_i        NUMBER;
BEGIN
  BEGIN ResourceManagement_Data.AddResourceStatus('reserved',  'Held');      EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('confirmed', 'Confirmed'); EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceStatus('cancelled', 'Cancelled'); EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;
  BEGIN ResourceManagement_Data.AddResourceInstanceStatus('available', 'Available'); EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL; END;

  ResourceManagement_Data.AddResourceCategory('DEMO_EXPL_Economy',  NULL, 'pool');
  ResourceManagement_Data.AddResourceCategory('DEMO_EXPL_Business', NULL, 'pool');
  ResourceManagement_Data.AddResourceCategory('DEMO_EXPL_First',    NULL, 'pool');
  SELECT id INTO v_eco   FROM ResourceCategory WHERE name = 'DEMO_EXPL_Economy';
  SELECT id INTO v_bus   FROM ResourceCategory WHERE name = 'DEMO_EXPL_Business';
  SELECT id INTO v_first FROM ResourceCategory WHERE name = 'DEMO_EXPL_First';
  ResourceManagement_Data.UpdateCategoryHierarchy(v_eco,   4, 500);
  ResourceManagement_Data.UpdateCategoryHierarchy(v_bus,   2, 2500);
  ResourceManagement_Data.UpdateCategoryHierarchy(v_first, 1, 5000);

  ResourceManagement_Data.AddUser('DEMO_EXPL_USER');
  ResourceManagement_Data.AddResourceAsset('DEMO_EXPL_ASSET', NULL, 'active');
  SELECT id INTO v_asset_id FROM ResourceAsset WHERE name = 'DEMO_EXPL_ASSET';

  ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_eco,   1);
  ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_bus,   2);
  ResourceManagement_Data.AddAssetCapacity(v_asset_id, v_first, 2);

  ResourceManagement_Data.AddResourceInstance(v_asset_id, v_eco, 'E1', 'available');
  FOR v_i IN 1..2 LOOP ResourceManagement_Data.AddResourceInstance(v_asset_id, v_bus,   'B' || v_i, 'available'); END LOOP;
  FOR v_i IN 1..2 LOOP ResourceManagement_Data.AddResourceInstance(v_asset_id, v_first, 'F' || v_i, 'available'); END LOOP;

  ResourceManagement_Data.AddAllocationContext(v_asset_id, 'DEMO_EXPL', SYSDATE + 1, SYSDATE + 2);
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 2: setup complete (Economy 1, Business 2, First 2).');
END;
/

PROMPT
PAUSE  Press ENTER to inspect the initial state...

-- =============================================================================
-- Step 3: Pre-state
-- =============================================================================
PROMPT === Capacity ===
SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_EXPL'
 ORDER BY rc.name;

PROMPT === Resource instances ===
SELECT ri.id, ri.instance_identifier, rc.name AS category
  FROM ResourceInstance ri
  JOIN ResourceAsset    ra ON ri.asset_id = ra.id
  JOIN ResourceCategory rc ON ri.category_id = rc.id
 WHERE ra.name = 'DEMO_EXPL_ASSET'
 ORDER BY rc.name, ri.id;

PROMPT
PAUSE  Press ENTER to see the ReservationRequest (Session A will block soon)...

-- =============================================================================
-- Step 4: Session B block + blocking offer
-- =============================================================================
PROMPT
PROMPT ResourceManagement.MakeReservationWithAlternative(
PROMPT    p_context_identifier         => 'DEMO_EXPL',
PROMPT    p_original_category_name     => 'DEMO_EXPL_Economy',
PROMPT    p_user_id                    => v_user_id,
PROMPT    p_quantity                   => 2,
PROMPT    p_alternative_category_names => 'DEMO_EXPL_Business, DEMO_EXPL_First',
PROMPT    p_offer_timeout_minutes      => 1,
PROMPT    p_include_partial_original   => NULL,
PROMPT    p_offer_group_id             => v_offer_group_id,
PROMPT    p_offer_journal_ids          => v_offer_journal_ids);
PROMPT
PROMPT   -----------------------------------------------------------------------
PROMPT
PAUSE  Session B ready? Press ENTER -- THIS WILL BLOCK on the offer queue.

PROMPT
PROMPT  *** Session A: calling MakeReservationWithAlternative. Blocking... ***
PROMPT

DECLARE
  v_user_id            NUMBER;
  v_offer_group_id     VARCHAR2(64);
  v_offer_journal_ids  SYS.ODCINUMBERLIST;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_EXPL_USER';
  ResourceManagement.MakeReservationWithAlternative(
    p_context_identifier         => 'DEMO_EXPL',
    p_original_category_name     => 'DEMO_EXPL_Economy',
    p_user_id                    => v_user_id,
    p_quantity                   => 2,
    p_alternative_category_names => 'DEMO_EXPL_Business,DEMO_EXPL_First',
    p_offer_timeout_minutes      => 1,
    p_include_partial_original   => NULL,
    p_offer_group_id             => v_offer_group_id,
    p_offer_journal_ids          => v_offer_journal_ids
  );
  DBMS_OUTPUT.PUT_LINE('Step 4: returned offer_group_id=' || NVL(v_offer_group_id, 'NULL') ||
                       ' offered_seats=' || NVL(v_offer_journal_ids.COUNT, 0));
END;
/

PROMPT
PAUSE  Unblocked. Press ENTER to inspect the final state...

-- =============================================================================
-- Step 5: Post-state
-- =============================================================================
PROMPT === AllocationJournal entries (offer journals) ===
SELECT aj.id, aj.status,
       JSON_VALUE(aj.metadata, '$.custom.offer_group_id')     AS offer_group_id,
       JSON_VALUE(aj.metadata, '$.custom.to_category_name')   AS to_category,
       JSON_VALUE(aj.metadata, '$.custom.compensation_reason') AS comp_reason
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
 WHERE ac.context_identifier = 'DEMO_EXPL'
 ORDER BY aj.id;

PROMPT === CurrentAllocations (final live state) ===
SELECT ca.status, rc.name AS category, ri.instance_identifier, ca.journal_id
  FROM CurrentAllocations ca
  JOIN AllocationContext ac ON ca.context_id = ac.id
  JOIN ResourceCategory  rc ON ca.category_id = rc.id
  LEFT JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_EXPL'
 ORDER BY rc.name, ri.instance_identifier;

PROMPT === Capacity ===
SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_EXPL'
 ORDER BY rc.name;

PROMPT === Recent DebugLog (offer / publish events) ===
SELECT id, SUBSTR(message, 1, 150) AS message
  FROM DebugLogSorted
 WHERE message LIKE '[OFFER %'
    OR message LIKE '%PublishOfferDecision%'
    OR message LIKE '%MakeReservationWithAlternative%'
 FETCH FIRST 15 ROWS ONLY;

PROMPT
PAUSE  Press ENTER to tear down the demo data...

-- =============================================================================
-- Step 6: Teardown
-- =============================================================================
DECLARE
  PROCEDURE silent_delete(p_sql IN VARCHAR2) IS
  BEGIN EXECUTE IMMEDIATE p_sql; EXCEPTION WHEN OTHERS THEN NULL; END;
BEGIN
  silent_delete(q'[DELETE FROM ActiveAllocation  WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_EXPL')]');
  silent_delete(q'[DELETE FROM AllocationJournal WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_EXPL')]');
  silent_delete(q'[DELETE FROM Capacity         WHERE context_id IN (SELECT id FROM AllocationContext WHERE context_identifier = 'DEMO_EXPL')]');
  silent_delete(q'[DELETE FROM AllocationContext WHERE context_identifier = 'DEMO_EXPL']');
  silent_delete(q'[DELETE FROM ResourceInstance WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_EXPL_ASSET')]');
  silent_delete(q'[DELETE FROM AssetCapacity    WHERE asset_id IN (SELECT id FROM ResourceAsset WHERE name = 'DEMO_EXPL_ASSET')]');
  silent_delete(q'[DELETE FROM ResourceAsset    WHERE name = 'DEMO_EXPL_ASSET']');
  silent_delete(q'[DELETE FROM Users            WHERE name = 'DEMO_EXPL_USER']');
  silent_delete(q'[DELETE FROM CategorySubstitution
                   WHERE from_category_id IN (SELECT id FROM ResourceCategory WHERE name IN ('DEMO_EXPL_Economy','DEMO_EXPL_Business','DEMO_EXPL_First'))
                      OR to_category_id   IN (SELECT id FROM ResourceCategory WHERE name IN ('DEMO_EXPL_Economy','DEMO_EXPL_Business','DEMO_EXPL_First'))]');
  silent_delete(q'[DELETE FROM ResourceCategory WHERE name IN ('DEMO_EXPL_Economy','DEMO_EXPL_Business','DEMO_EXPL_First')]');
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Step 6: teardown complete.');
END;
/

PROMPT
PROMPT =============================================================================
PROMPT  DEMO 04 finished.
PROMPT =============================================================================
