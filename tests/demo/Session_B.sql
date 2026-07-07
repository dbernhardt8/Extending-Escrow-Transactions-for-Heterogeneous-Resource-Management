--------------------------------------- DEMO 01:
---------------------------------------
-- Show reserved states:

PROMPT === AllocationJournal entries (newest first) ===

SELECT aj.id, aj.status, ri.instance_identifier,
       JSON_VALUE(aj.metadata, '$.group_leader_journal_id') AS leader,
       JSON_VALUE(aj.metadata, '$.group_size')              AS grp_size
  FROM AllocationJournal aj
  JOIN AllocationContext ac ON aj.context_id = ac.id
  LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
 WHERE ac.context_identifier = 'DEMO_CAT'
 ORDER BY aj.id DESC;

PROMPT === Capacity now (active_count should reflect kept seats) ===

SELECT rc.name AS category, c.total_capacity, c.active_count
  FROM Capacity c
  JOIN AllocationContext ac ON c.context_id = ac.id
  JOIN ResourceCategory  rc ON c.category_id = rc.id
 WHERE ac.context_identifier = 'DEMO_CAT';

--------------------------------------
-------------------------------------- Session B: confirm the whole group 
--------------------------------------
DECLARE
  v_user_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_CAT_USER';
  ResourceManagement.publish_group_reservation_event(
    p_context_identifier => 'DEMO_CAT',
    p_user_id            => v_user_id,
    p_category_name      => 'DEMO_CAT_Business',
    p_action             => 'CONFIRM'  -- or 'CANCEL'
  );
END;
/



-- DEMO 02:

-- Show state


DECLARE
  v_user_id  NUMBER;
  v_inst_id  NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_INST_USER';
  SELECT ri.id INTO v_inst_id
    FROM ResourceInstance ri
    JOIN ResourceAsset    ra ON ri.asset_id = ra.id
   WHERE ra.name = 'DEMO_INST_ASSET'
     AND ri.instance_identifier = 'BIZ2';
  ResourceManagement.publish_reservation_event(
    p_resource_id        => v_inst_id,
    p_context_identifier => 'DEMO_INST',
    p_user_id            => v_user_id,
    p_action             => 'CONFIRM'   -- or 'CANCEL'
  );
END;
/

-- DEMO 03:
DECLARE
  v_user_id NUMBER;
  v_ids     NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_RACE_USER_B';
  ResourceManagement.MakeReservation(
    p_context_identifier => 'DEMO_RACE',
    p_user_id            => 131,
    p_category_name      => 'DEMO_RACE_Business',
    p_quantity           => 2,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_ids
  );
  DBMS_OUTPUT.PUT_LINE('Session B: SUCCESS leader=' || v_ids);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('Session B: EXPECTED FAILURE ' || SQLERRM);
END;
/




--------------------------------------------------------
-------------------------------------------------------- DEMO 04:
--------------------------------------------------------

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




----------------
---------------- CONFIRM Alternative
----------------



DECLARE
  v_user_id NUMBER;
  v_offer_group_id VARCHAR2(64);
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_EXPL_USER';
  -- Look up the open offer for this user/context:
  SELECT MAX(JSON_VALUE(aj.metadata, '$.custom.offer_group_id'))
    INTO v_offer_group_id
    FROM AllocationJournal  aj
    JOIN CurrentAllocations ca ON ca.journal_id = aj.id
    JOIN AllocationContext  ac ON ca.context_id = ac.id
   WHERE ac.context_identifier = 'DEMO_EXPL'
     AND ca.user_id = v_user_id
     AND ca.status = 'reserved';
  IF v_offer_group_id IS NULL THEN
    RAISE_APPLICATION_ERROR(-20010,
      'No open offer found. Start demo_04 in Session A and run this block while Session A is blocked.');
  END IF;
  ResourceManagement.publish_offer_decision(
    p_context_identifier     => 'DEMO_EXPL',
    p_user_id                => v_user_id,
    p_offer_group_id         => v_offer_group_id,
    p_action                 => 'CONFIRM',
    p_selected_category_name => 'DEMO_EXPL_Business'   -- or DEMO_EXPL_First / 'CANCEL'
  );
  DBMS_OUTPUT.PUT_LINE('Session B: published for offer ' || v_offer_group_id);
END;
/

-- DEMO 05:
DECLARE
  v_user_id NUMBER;
  v_offer_group_id VARCHAR2(64);
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_PART_USER';
  SELECT MAX(JSON_VALUE(aj.metadata, '$.custom.offer_group_id'))
    INTO v_offer_group_id
    FROM AllocationJournal  aj
    JOIN CurrentAllocations ca ON ca.journal_id = aj.id
    JOIN AllocationContext  ac ON ca.context_id = ac.id
   WHERE ac.context_identifier = 'DEMO_PART'
     AND ca.user_id = v_user_id
     AND ca.status = 'reserved';
  IF v_offer_group_id IS NULL THEN
    RAISE_APPLICATION_ERROR(-20010,
      'No open offer found. Start demo_05 in Session A and run this block while Session A is blocked.');
  END IF;
  ResourceManagement.publish_offer_decision(
    p_context_identifier     => 'DEMO_PART',
    p_user_id                => v_user_id,
    p_offer_group_id         => v_offer_group_id,
    p_action                 => 'CONFIRM',
    p_selected_category_name => 'DEMO_PART_Business' -- or DEMO_PART_Premium / DEMO_PART_First
  );
  DBMS_OUTPUT.PUT_LINE('Session B: published for offer ' || v_offer_group_id);
END;
/

-- =============================================================================
-- DEMO 06: double-book same instance (M3) in context DEMO_DBL
-- =============================================================================
-- While Session A is parked in its AQ dequeue (USER_A holds M3 as 'reserved'),
-- run the FIRST block below to show that USER_B cannot grab M3 -> ORA-20604
-- (the check fires synchronously, before any AQ wait, against the
-- autonomously-committed reservation made by Session A).
-- Then run the SECOND block to confirm Session A's reservation and unblock it.

-- DEMO 06a: USER_B tries to grab M3 too -> expected ORA-20604 synchronously
DECLARE
  v_user_id    NUMBER;
  v_inst_id    NUMBER;
  v_journal_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_DBL_USER_B';
  SELECT ri.id INTO v_inst_id
    FROM ResourceInstance ri
    JOIN ResourceAsset    ra ON ri.asset_id = ra.id
   WHERE ra.name = 'DEMO_DBL_ASSET'
     AND ri.instance_identifier = 'M3';

  ResourceManagement.MakeReservation(
    p_context_identifier => 'DEMO_DBL',
    p_user_id            => v_user_id,
    p_instance_id        => v_inst_id-1,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_journal_id
  );
  DBMS_OUTPUT.PUT_LINE('Session B: UNEXPECTED - MakeReservation did NOT raise.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -20604 THEN
      DBMS_OUTPUT.PUT_LINE('Session B: EXPECTED ORA-20604 - ' || SUBSTR(SQLERRM, 1, 200));
    ELSE
      DBMS_OUTPUT.PUT_LINE('Session B: Unexpected ' || SQLCODE || ' - ' || SQLERRM);
    END IF;
END;
/

-- DEMO 06b: confirm USER_A's reservation of M3 -> unblocks Session A
DECLARE
  v_user_id NUMBER;
  v_inst_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_DBL_USER_A';
  SELECT ri.id INTO v_inst_id
    FROM ResourceInstance ri
    JOIN ResourceAsset    ra ON ri.asset_id = ra.id
   WHERE ra.name = 'DEMO_DBL_ASSET'
     AND ri.instance_identifier = 'M3';
  ResourceManagement.publish_reservation_event(
    p_resource_id        => v_inst_id,
    p_context_identifier => 'DEMO_DBL',
    p_user_id            => 141,
    p_action             => 'CONFIRM'   -- or 'CANCEL'
  );
END;
/

-- =============================================================================
-- DEMO 07: shared resource time conflict (ROOM_42)
-- =============================================================================
-- While Session A is parked in its AQ dequeue (USER_A holds ROOM_42 for
-- Meeting1), run the FIRST block below to show that USER_B cannot book
-- ROOM_42 for the overlapping Meeting2 -> ORA-20703 (time-conflict check
-- fires synchronously before the AQ wait).
-- Then run the SECOND block to confirm Session A's reservation and unblock it.

-- DEMO 07a: USER_B tries the overlapping Meeting2 -> expected ORA-20703 synchronously
DECLARE
  v_user_id    NUMBER;
  v_inst_id    NUMBER;
  v_journal_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_TC_USER_B';
  SELECT ri.id INTO v_inst_id
    FROM ResourceInstance ri
    JOIN ResourceAsset    ra ON ri.asset_id = ra.id
   WHERE ra.name = 'DEMO_TC_ASSET'
     AND ri.instance_identifier = 'ROOM_42';

  ResourceManagement.MakeReservation(
    p_context_identifier => 'DEMO_TC_Meeting2',
    p_user_id            => v_user_id,
    p_instance_id        => v_inst_id,
    p_timeout_minutes    => 5,
    p_new_journal_id     => v_journal_id
  );
  DBMS_OUTPUT.PUT_LINE('Session B: UNEXPECTED - MakeReservation did NOT raise.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -20703 THEN
      DBMS_OUTPUT.PUT_LINE('Session B: EXPECTED ORA-20703 - ' || SUBSTR(SQLERRM, 1, 200));
    ELSE
      DBMS_OUTPUT.PUT_LINE('Session B: Unexpected ' || SQLCODE || ' - ' || SQLERRM);
    END IF;
END;
/

-- DEMO 07b: confirm USER_A's booking of ROOM_42 for Meeting1 -> unblocks Session A
DECLARE
  v_user_id NUMBER;
  v_inst_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_TC_USER_A';
  SELECT ri.id INTO v_inst_id
    FROM ResourceInstance ri
    JOIN ResourceAsset    ra ON ri.asset_id = ra.id
   WHERE ra.name = 'DEMO_TC_ASSET'
     AND ri.instance_identifier = 'ROOM_42';
  ResourceManagement.publish_reservation_event(
    p_resource_id        => v_inst_id,
    p_context_identifier => 'DEMO_TC_Meeting1',
    p_user_id            => v_user_id,
    p_action             => 'CONFIRM'   -- or 'CANCEL'
  );
END;
/

-- =============================================================================
-- DEMO 09: maintenance overlap (contained / category) - confirm group on Flight A
-- =============================================================================
-- While Session A is blocked in demo_09_maintenance_overlap_contained.sql Step 4:
DECLARE
  v_user_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_MAINT_USER';
  ResourceManagement.publish_group_reservation_event(
    p_context_identifier => 'DEMO_MAINT_Flight_A',
    p_user_id            => v_user_id,
    p_category_name      => 'DEMO_MAINT_Business',
    p_action             => 'CONFIRM'   -- or 'CANCEL'
  );
END;
/

-- DEMO 08 (OPTIONAL): early decision before the 1-min AQ timeout fires.
-- Skip this block to demonstrate the natural timeout/auto-cancel.
DECLARE
  v_user_id NUMBER;
BEGIN
  SELECT id INTO v_user_id FROM Users WHERE name = 'DEMO_TO_USER';
  ResourceManagement.publish_group_reservation_event(
    p_context_identifier => 'DEMO_TO',
    p_user_id            => v_user_id,
    p_category_name      => 'DEMO_TO_Business',
    p_action             => 'CANCEL'   -- or 'CONFIRM'
  );
END;
/