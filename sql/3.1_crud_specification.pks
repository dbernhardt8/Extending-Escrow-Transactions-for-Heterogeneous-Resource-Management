-- =============================================================================
-- 3.1_crud_specification.pks
--
-- DATA ACCESS LAYER - Package Specification (CRUD Operations)
-- ===========================================================
-- This package provides basic Create, Read, Update, Delete operations
-- for all database tables without complex business logic.
--
-- DOMAIN PORTABILITY:
-- This layer is fully domain-agnostic. The procedures operate on generic
-- entities (ResourceCategory, ResourceAsset, ResourceInstance, etc.) that
-- map to any temporal resource allocation domain.
--
-- Key autonomous transaction: AddAllocationJournal commits immediately
-- to ensure the audit trail is preserved regardless of outer transaction fate.
-- =============================================================================

CREATE OR REPLACE PACKAGE ResourceManagement_Data AUTHID CURRENT_USER AS

  --==============================================================================
  -- Utility Operations
  --==============================================================================
  PROCEDURE LogDebugMessage(p_message IN VARCHAR2);

  --==============================================================================
  -- Resource Category Operations
  --==============================================================================
  -- allocation_mode: 'pool' (default) for container-scoped resources (e.g., flight seats)
  --                  'direct' for shared resources with time-overlap checking (e.g., meeting attendees)
  PROCEDURE AddResourceCategory(p_name IN VARCHAR2, p_description IN VARCHAR2, p_allocation_mode IN VARCHAR2 DEFAULT 'pool', p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE UpdateResourceCategory(p_id IN NUMBER, p_name IN VARCHAR2, p_description IN VARCHAR2, p_allocation_mode IN VARCHAR2 DEFAULT NULL, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE DeleteResourceCategory(p_id IN NUMBER);

  FUNCTION GetResourceCategory(p_id IN NUMBER) RETURN SYS_REFCURSOR;
  FUNCTION GetCategoryAllocationMode(p_category_id IN NUMBER) RETURN VARCHAR2;

  --==============================================================================
  -- Resource Status Operations
  --==============================================================================
  PROCEDURE AddResourceStatus(p_name IN VARCHAR2, p_description IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE UpdateResourceStatus(p_name IN VARCHAR2, p_description IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE DeleteResourceStatus(p_name IN VARCHAR2);

  FUNCTION GetResourceStatus(p_name IN VARCHAR2) RETURN SYS_REFCURSOR;

  --==============================================================================
  -- Resource Instance Status Operations
  --==============================================================================
  PROCEDURE AddResourceInstanceStatus(p_name IN VARCHAR2, p_description IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE UpdateResourceInstanceStatus(p_name IN VARCHAR2, p_description IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE DeleteResourceInstanceStatus(p_name IN VARCHAR2);

  FUNCTION GetResourceInstanceStatus(p_name IN VARCHAR2) RETURN SYS_REFCURSOR;

  --==============================================================================
  -- User Operations
  --==============================================================================
  PROCEDURE AddUser(p_name IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE UpdateUser(p_id IN NUMBER, p_name IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE DeleteUser(p_id IN NUMBER);

  FUNCTION GetUser(p_id IN NUMBER) RETURN SYS_REFCURSOR;
  FUNCTION GetUserByName(p_name IN VARCHAR2) RETURN SYS_REFCURSOR;

  --==============================================================================
  -- Resource Asset Operations
  --==============================================================================
  PROCEDURE AddResourceAsset(p_name IN VARCHAR2, p_description IN VARCHAR2, p_status IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL); 
  PROCEDURE UpdateResourceAsset(p_asset_id IN NUMBER, p_name IN VARCHAR2, p_description IN VARCHAR2, p_status IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE DeleteResourceAsset(p_asset_id IN NUMBER);
  
  FUNCTION GetResourceAsset(p_asset_id IN NUMBER) RETURN SYS_REFCURSOR;
  
  --==============================================================================
  -- Asset Capacity Operations
  --==============================================================================
  PROCEDURE AddAssetCapacity(p_asset_id IN NUMBER, p_category_id IN NUMBER, p_quantity IN NUMBER, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE UpdateAssetCapacity(p_capacity_id IN NUMBER, p_asset_id IN NUMBER, p_category_id IN NUMBER, p_quantity IN NUMBER, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE DeleteAssetCapacity(p_capacity_id IN NUMBER);
  
  FUNCTION GetAssetCapacity(p_asset_id IN NUMBER) RETURN SYS_REFCURSOR;

  --==============================================================================
  -- Resource Instance Operations
  --==============================================================================
  PROCEDURE AddResourceInstance(p_asset_id IN NUMBER, p_category_id IN NUMBER, p_instance_identifier IN VARCHAR2, p_status IN VARCHAR2 DEFAULT 'available', p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE UpdateResourceInstance(p_id IN NUMBER, p_asset_id IN NUMBER, p_category_id IN NUMBER, p_instance_identifier IN VARCHAR2, p_status IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE DeleteResourceInstance(p_id IN NUMBER);
  
  FUNCTION GetResourceInstance(p_id IN NUMBER) RETURN SYS_REFCURSOR;
  FUNCTION GetResourceInstancesByAsset(p_asset_id IN NUMBER) RETURN SYS_REFCURSOR;

  --==============================================================================
  -- Allocation Context Operations
  --==============================================================================
  -- asset_id: Required for contained allocation (determines available resources)
  --           Optional (NULL) for shared allocation (resources specified explicitly)
  PROCEDURE AddAllocationContext(p_asset_id IN NUMBER, p_context_identifier IN VARCHAR2, p_start_date IN DATE, p_end_date IN DATE, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE AddDirectAllocationContext(p_context_identifier IN VARCHAR2, p_start_date IN DATE, p_end_date IN DATE, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE UpdateAllocationContext(p_context_id IN NUMBER, p_asset_id IN NUMBER, p_context_identifier IN VARCHAR2, p_start_date IN DATE, p_end_date IN DATE, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE DeleteAllocationContext(p_context_id IN NUMBER);
  
  FUNCTION GetAllocationContext(p_context_identifier IN VARCHAR2) RETURN SYS_REFCURSOR;
  FUNCTION GetContextTimeInterval(p_context_id IN NUMBER, p_start_date OUT DATE, p_end_date OUT DATE) RETURN BOOLEAN;
  
  --==============================================================================
  -- Time-Based Availability Operations (for Shared Allocation)
  --==============================================================================
  -- Checks if a resource has any active allocation in contexts with overlapping time intervals
  FUNCTION IsResourceAvailableForInterval(
    p_resource_instance_id IN NUMBER,
    p_start_date IN DATE,
    p_end_date IN DATE,
    p_exclude_context_id IN NUMBER DEFAULT NULL
  ) RETURN VARCHAR2;  -- 'Y' if available, 'N' if conflict exists
  
  -- Returns the conflicting context_id if resource is not available, NULL otherwise
  FUNCTION GetResourceTimeConflict(
    p_resource_instance_id IN NUMBER,
    p_start_date IN DATE,
    p_end_date IN DATE,
    p_exclude_context_id IN NUMBER DEFAULT NULL
  ) RETURN NUMBER;

  --==============================================================================
  -- Capacity Operations (Lock-Free Counters)
  --==============================================================================
  PROCEDURE AddCapacity(
    p_context_id IN NUMBER,
    p_category_id IN NUMBER,
    p_total_capacity IN NUMBER,
    p_active_count IN NUMBER DEFAULT 0,
    p_metadata IN CLOB DEFAULT NULL
  );
  
  PROCEDURE UpdateCapacity(
    p_id IN NUMBER,
    p_active_count IN NUMBER,
    p_metadata IN CLOB DEFAULT NULL
  );
  
  PROCEDURE IncrementCapacityCounter(
    p_context_id IN NUMBER,
    p_category_id IN NUMBER,
    p_active_delta IN NUMBER
  );
  
  PROCEDURE DeleteCapacity(p_id IN NUMBER);
  
  FUNCTION GetCapacity(p_context_id IN NUMBER, p_category_id IN NUMBER) RETURN SYS_REFCURSOR;
  
  FUNCTION GetCapacityById(p_id IN NUMBER) RETURN SYS_REFCURSOR;
  
  FUNCTION GetAvailableCapacity(p_context_id IN NUMBER, p_category_id IN NUMBER) RETURN NUMBER;

  --==============================================================================
  -- Allocation Journal Operations (Autonomous for Permanent Audit Trail)
  --==============================================================================
  PROCEDURE AddAllocationJournal(
    p_context_id IN NUMBER, 
    p_category_id IN NUMBER, 
    p_user_id IN NUMBER, 
    p_resource_instance_id IN NUMBER, 
    p_status IN VARCHAR2, 
    p_metadata IN CLOB DEFAULT NULL,
    p_journal_id OUT NUMBER
  );
  PROCEDURE UpdateAllocationJournal(p_id IN NUMBER, p_context_id IN NUMBER, p_category_id IN NUMBER, p_user_id IN NUMBER, p_resource_instance_id IN NUMBER, p_status IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE DeleteAllocationJournal(p_id IN NUMBER);
  
  FUNCTION GetAllocationJournal(p_id IN NUMBER) RETURN SYS_REFCURSOR;
  FUNCTION GetAllocationJournalByContext(p_context_id IN NUMBER) RETURN SYS_REFCURSOR;

  --==============================================================================
  -- Workflow Log Operations
  --==============================================================================
  PROCEDURE AddWorkflowLog(p_event_id IN VARCHAR2, p_workflow_id IN NUMBER, p_wf_static_id IN VARCHAR2, p_act_static_id IN VARCHAR2, p_message IN VARCHAR2, p_status IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE UpdateWorkflowLog(p_id IN NUMBER, p_event_id IN VARCHAR2, p_workflow_id IN NUMBER, p_wf_static_id IN VARCHAR2, p_act_static_id IN VARCHAR2, p_message IN VARCHAR2, p_status IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE DeleteWorkflowLog(p_id IN NUMBER);
  
  FUNCTION GetWorkflowLog(p_id IN NUMBER) RETURN SYS_REFCURSOR;
  FUNCTION GetWorkflowLogByWorkflowId(p_workflow_id IN NUMBER) RETURN SYS_REFCURSOR;

  --==============================================================================
  -- Workflow Collaboration Operations
  --==============================================================================
  PROCEDURE AddWorkflowCollaboration(p_event_id IN VARCHAR2, p_workflow_id IN NUMBER, p_collaboration_name IN VARCHAR2, p_event_data IN CLOB, p_state IN VARCHAR2, p_activity_static_id IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE UpdateWorkflowCollaboration(p_id IN NUMBER, p_event_id IN VARCHAR2, p_workflow_id IN NUMBER, p_collaboration_name IN VARCHAR2, p_event_data IN CLOB, p_state IN VARCHAR2, p_activity_static_id IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE DeleteWorkflowCollaboration(p_id IN NUMBER);
  
  FUNCTION GetWorkflowCollaboration(p_id IN NUMBER) RETURN SYS_REFCURSOR;
  FUNCTION GetWorkflowCollaborationByWorkflowId(p_workflow_id IN NUMBER) RETURN SYS_REFCURSOR;

  --==============================================================================
  -- Debug Log Operations
  --==============================================================================
  PROCEDURE AddDebugLog(p_message IN VARCHAR2, p_metadata IN CLOB DEFAULT NULL);
  PROCEDURE DeleteDebugLog(p_id IN NUMBER);
  
  FUNCTION GetDebugLog(p_id IN NUMBER) RETURN SYS_REFCURSOR;
  FUNCTION GetRecentDebugLogs(p_limit IN NUMBER DEFAULT 100) RETURN SYS_REFCURSOR;
  
  PROCEDURE ClearDebugLogs;

  --==============================================================================
  -- Category Hierarchy Operations
  --==============================================================================
  PROCEDURE UpdateCategoryHierarchy(
    p_category_id IN NUMBER,
    p_hierarchy_level IN NUMBER,
    p_base_price IN NUMBER DEFAULT NULL
  );

  --==============================================================================
  -- Category Substitution Operations
  --==============================================================================
  PROCEDURE AddCategorySubstitution(
    p_from_category_id IN NUMBER,
    p_to_category_id IN NUMBER,
    p_cost_adjustment IN NUMBER DEFAULT 0,
    p_priority IN NUMBER DEFAULT 1,
    p_is_allowed IN VARCHAR2 DEFAULT 'Y',
    p_auto_offer IN VARCHAR2 DEFAULT 'N',
    p_requires_approval IN VARCHAR2 DEFAULT 'N',
    p_metadata IN CLOB DEFAULT NULL
  );
  
  PROCEDURE UpdateCategorySubstitution(
    p_id IN NUMBER,
    p_cost_adjustment IN NUMBER,
    p_priority IN NUMBER,
    p_is_allowed IN VARCHAR2,
    p_auto_offer IN VARCHAR2,
    p_requires_approval IN VARCHAR2,
    p_metadata IN CLOB DEFAULT NULL
  );
  
  PROCEDURE DeleteCategorySubstitution(p_id IN NUMBER);
  
  FUNCTION GetCategorySubstitutions(p_from_category_id IN NUMBER) RETURN SYS_REFCURSOR;
  
  FUNCTION GetAvailableSubstitutionsForContext(
    p_context_id IN NUMBER,
    p_from_category_id IN NUMBER
  ) RETURN SYS_REFCURSOR;

END ResourceManagement_Data;
/

