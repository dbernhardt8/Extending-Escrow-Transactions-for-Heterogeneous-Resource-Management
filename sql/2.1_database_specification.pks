-- =============================================================================
-- 2_database_specification.pks
--
-- BUSINESS LOGIC LAYER - Package Specification
-- =============================================
-- This package provides business logic for resource management: reservations,
-- state transitions, capacity, substitution, and workflow integration.
-- For table CRUD use ResourceManagement_Data.
--
-- Domain: Names (CheckInUser, BoardUser, etc.) are configurable; patterns
-- (journal-based state, RESERVABLE counters, saga compensation) are generic.
-- =============================================================================

CREATE OR REPLACE PACKAGE ResourceManagement AUTHID CURRENT_USER AS

  --==============================================================================
  -- Constants (AQ queue, event envelope keys)
  --==============================================================================
  c_wf_user_events_q           CONSTANT VARCHAR2(32) := 'WF_USER_EVENTS_Q';

  ce_event_id                  CONSTANT VARCHAR2(32) := 'id';
  ce_event_source              CONSTANT VARCHAR2(32) := 'source';
  ce_event_spec_version        CONSTANT VARCHAR2(32) := 'specversion';
  ce_event_type                CONSTANT VARCHAR2(32) := 'type';
  ce_event_subject             CONSTANT VARCHAR2(32) := 'subject';
  ce_event_application_id      CONSTANT VARCHAR2(32) := 'applicationId';
  ce_event_workflow_id         CONSTANT VARCHAR2(32) := 'workflowId';
  ce_event_workflow_static_id  CONSTANT VARCHAR2(32) := 'workflowStaticId';
  ce_event_workflow_initiator  CONSTANT VARCHAR2(32) := 'workflowInitiator';
  ce_event_workflow_detail_pk  CONSTANT VARCHAR2(32) := 'workflowDetailPK';
  ce_event_activity_static_id  CONSTANT VARCHAR2(32) := 'activityStaticId';
  ce_event_collaboration_name  CONSTANT VARCHAR2(32) := 'collaborationName';
  ce_event_data                CONSTANT VARCHAR2(32) := 'data';

  ce_event_type_start_workflow CONSTANT VARCHAR2(128) := 'com.oracle.apex.workflow.StartWorkflow';
  ce_event_type_send_message   CONSTANT VARCHAR2(128) := 'com.oracle.apex.workflow.SendMessage';

  --==============================================================================
  -- Availability and capacity
  --==============================================================================
  FUNCTION GetAvailableSeatCount(p_context_identifier IN VARCHAR2, p_category_name IN VARCHAR2) RETURN NUMBER;
  FUNCTION GetCapacityReport(p_context_identifier IN VARCHAR2) RETURN SYS_REFCURSOR;
  FUNCTION GetFlightManifest(p_context_identifier IN VARCHAR2) RETURN SYS_REFCURSOR;
  PROCEDURE InitializeCapacityForContext(p_context_id IN NUMBER);

  --==============================================================================
  -- Asset and context setup
  --==============================================================================
  PROCEDURE ValidateAssetCapacity(p_asset_id IN NUMBER);
  PROCEDURE AddCompleteAssetFromJSON(p_json_data IN CLOB, p_new_asset_id OUT NUMBER);
  PROCEDURE ScheduleFlightFromJSON(p_json_data IN CLOB, p_new_context_id OUT NUMBER);

  --==============================================================================
  -- Reservation (pool / contained allocation mode)
  --==============================================================================
  PROCEDURE MakeReservation(
    p_context_identifier  IN VARCHAR2,
    p_category_name       IN VARCHAR2,
    p_user_id             IN NUMBER,
    p_quantity            IN NUMBER,
    p_timeout_minutes     IN NUMBER DEFAULT NULL,
    p_new_journal_ids     OUT SYS.ODCINUMBERLIST
  );
  PROCEDURE MakeReservationByInstanceId(
    p_context_identifier IN VARCHAR2,
    p_user_id            IN NUMBER,
    p_instance_id        IN NUMBER,
    p_timeout_minutes    IN NUMBER DEFAULT 5,
    p_new_journal_id     OUT NUMBER
  );

  --==============================================================================
  -- Type substitution (offer flow)
  --==============================================================================
  FUNCTION FindSubstitutions(
    p_context_identifier IN VARCHAR2,
    p_category_name     IN VARCHAR2
  ) RETURN SYS_REFCURSOR;
  PROCEDURE MakeReservationWithAlternative(
    p_context_identifier         IN VARCHAR2,
    p_original_category_name     IN VARCHAR2,
    p_user_id                    IN NUMBER,
    p_quantity                    IN NUMBER,
    p_alternative_category_names IN VARCHAR2 DEFAULT NULL,
    p_offer_timeout_minutes      IN NUMBER DEFAULT 5,
    p_include_partial_original   IN VARCHAR2 DEFAULT NULL,  -- 'Y' = reserve from original first when partial (e.g. seats together); NULL = only substitute categories
    p_offer_group_id             OUT VARCHAR2,
    p_offer_journal_ids          OUT SYS.ODCINUMBERLIST
  );
  -- Accept one category within the offer group: confirm all journals in that category, cancel the rest in the group.
  PROCEDURE ConfirmSubstitutionOffer(
    p_offer_group_id         IN VARCHAR2,
    p_selected_category_name IN VARCHAR2,
    p_user_id                IN NUMBER
  );
  PROCEDURE DeclineSubstitutionOffer(
    p_offer_group_id IN VARCHAR2,
    p_user_id        IN NUMBER
  );

  --==============================================================================
  -- Shared allocation (direct mode, time-overlap conflict detection)
  --==============================================================================
  PROCEDURE AllocateResourceDirect(
    p_context_identifier     IN VARCHAR2,
    p_resource_instance_id   IN NUMBER,
    p_user_id                IN NUMBER,
    p_category_id            IN NUMBER DEFAULT NULL,
    p_timeout_minutes        IN NUMBER DEFAULT 15,
    p_new_journal_id         OUT NUMBER
  );
  FUNCTION CheckResourceTimeConflict(
    p_resource_instance_id IN NUMBER,
    p_context_identifier   IN VARCHAR2
  ) RETURN NUMBER;
  FUNCTION GetResourceSchedule(p_resource_instance_id IN NUMBER) RETURN SYS_REFCURSOR;
  FUNCTION IsResourceAvailable(
    p_resource_instance_id IN NUMBER,
    p_context_identifier   IN VARCHAR2
  ) RETURN VARCHAR2;

  --==============================================================================
  -- Journal and lifecycle operations (by journal_id)
  --==============================================================================
  PROCEDURE ConfirmReservation(p_journal_id IN NUMBER);
  PROCEDURE CancelReservation(p_journal_id IN NUMBER, p_cancellation_metadata IN CLOB DEFAULT NULL);
  PROCEDURE AssignSpecificSeat(p_journal_id IN NUMBER, p_instance_identifier IN VARCHAR2);
  PROCEDURE UnconfirmReservation(p_journal_id IN NUMBER);
  PROCEDURE ReverseJournalEntry(
    p_journal_id     IN NUMBER,
    p_target_status  IN VARCHAR2,
    p_reason         IN VARCHAR2,
    p_new_journal_id OUT NUMBER
  );
  PROCEDURE CheckInUser(p_journal_id IN NUMBER);
  PROCEDURE CancelCheckIn(p_journal_id IN NUMBER);
  PROCEDURE BoardUser(p_journal_id IN NUMBER);
  PROCEDURE DeboardUser(p_journal_id IN NUMBER);
  PROCEDURE BlockResource(
    p_context_identifier     IN VARCHAR2,
    p_resource_instance_id   IN NUMBER,
    p_reason                 IN VARCHAR2 DEFAULT NULL,
    p_metadata               IN CLOB DEFAULT NULL,
    p_new_journal_id         OUT NUMBER
  );
  PROCEDURE UnblockResource(
    p_journal_id IN NUMBER,
    p_reason     IN VARCHAR2 DEFAULT NULL,
    p_new_journal_id OUT NUMBER
  );

  --==============================================================================
  -- Administrative (context, asset, mass operations)
  --==============================================================================
  PROCEDURE CancelFlight(p_context_identifier IN VARCHAR2, p_reason IN VARCHAR2);
  PROCEDURE RescheduleFlight(p_context_id IN NUMBER, p_new_start_date IN DATE, p_new_end_date IN DATE);
  PROCEDURE ChangeAircraft(p_context_id IN NUMBER, p_new_asset_id IN NUMBER);
  PROCEDURE ActivateAsset(p_asset_id IN NUMBER);
  PROCEDURE DeactivateAsset(p_asset_id IN NUMBER);

  --==============================================================================
  -- Workflow integration (Oracle AQ, collaboration)
  --==============================================================================
  PROCEDURE send_event(p_payload IN VARCHAR2);
  PROCEDURE create_collaboration(
    p_event_id           IN VARCHAR2,
    p_workflow_id        IN NUMBER,
    p_collaboration_name IN VARCHAR2,
    p_data               IN CLOB
  );
  PROCEDURE complete_collaboration(
    p_workflow_id        IN NUMBER,
    p_collaboration_name  IN VARCHAR2,
    p_activity_static_id IN VARCHAR2
  );
  PROCEDURE user_events_callback(
    context   RAW,
    reginfo   SYS.AQ$_REG_INFO,
    descr     SYS.AQ$_DESCRIPTOR,
    payload   RAW,
    payloadl  NUMBER
  );

END ResourceManagement;
/
