-- =============================================================================
-- 1_database_model.sql
--
-- GENERAL-PURPOSE RESOURCE ALLOCATION FRAMEWORK
-- =============================================
-- This script creates the complete database schema for the Resource Planning
-- System. The architecture supports any temporal resource allocation domain
-- through two allocation modes:
--
-- ALLOCATION MODES:
-- +-----------+------------------------------------------------------------------+
-- | Mode      | Description                                                      |
-- +-----------+------------------------------------------------------------------+
-- | pool      | Contained allocation: Resources selected from a context's asset  |
-- |           | (e.g., flight seats). Availability checked within context;      |
-- |           | capacity counters apply.                                          |
-- +-----------+------------------------------------------------------------------+
-- | direct    | Shared allocation: Specific resources allocated directly         |
-- |           | (e.g., meeting attendees). Availability checked across ALL      |
-- |           | time-overlapping contexts.                                       |
-- +-----------+------------------------------------------------------------------+
--
-- DOMAIN MAPPING EXAMPLES:
-- +-----------------+-------------+-------------+-------------+-------------+
-- | Concept         | Airline     | Hotel       | Meeting     | Equipment   |
-- +-----------------+-------------+-------------+-------------+-------------+
-- | ResourceCategory| Economy/Biz | Suite/Std   | Attendee    | Laptop/Proj |
-- | ResourceAsset   | Aircraft    | Hotel       | Team/Dept   | Inventory   |
-- | ResourceInstance| Seat 14A    | Room 101    | Person X    | MacBook #1  |
-- | AllocationContext| Flight     | Night       | Meeting     | Loan Period |
-- | Users (Allocatee)| Passenger  | Guest       | Organizer   | Employee    |
-- | Allocation Mode | pool        | pool        | direct      | pool/direct |
-- +-----------------+-------------+-------------+-------------+-------------+
--
-- DOMAIN-SPECIFIC CONFIGURATION:
-- - ResourceStatus: Allocation lifecycle states (domain-specific)
--   * Airline: reserved, confirmed, checked-in, boarded, cancelled, completed, blocked
--   * Hotel: reserved, confirmed, checked-in, checked-out, cancelled
--   * Meeting: invited, confirmed, attended, cancelled
--   * Equipment: requested, approved, issued, returned, cancelled
--
-- NOTE: This script does NOT drop existing objects. Use @sql/0_cleanup_all.sql
--       to clean up before running this script.
-- =============================================================================

SET SERVEROUTPUT ON;

-- -----------------------------------------------------------------------------
-- Step 1: Create Sequences
-- -----------------------------------------------------------------------------
CREATE SEQUENCE ResourceCategory_seq START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE Users_seq START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE ResourceAsset_seq START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE AssetCapacity_seq START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE AllocationContext_seq START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE AllocationJournal_seq START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE ResourceStatus_seq START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE ResourceInstance_seq START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE DebugLog_seq START WITH 1 INCREMENT BY 1 NOCACHE;
CREATE SEQUENCE CategorySubstitution_seq START WITH 1 INCREMENT BY 1 NOCACHE;

-- -----------------------------------------------------------------------------
-- Step 2: Create Tables
-- -----------------------------------------------------------------------------

-- ResourceCategory: Types/classes of resources within the system
-- Examples: First Class, Business, Economy (airline) | Suite, Standard (hotel)
-- 
-- ALLOCATION_MODE determines how resources of this category are allocated:
--   'pool'   - Contained allocation: Resources are selected from a context's asset pool
--              (e.g., airline seats). Availability is checked within the context's asset;
--              capacity counters apply.
--   'direct' - Shared allocation: Specific resources are allocated directly
--              (e.g., people in meetings). Availability is checked across ALL contexts
--              with overlapping time intervals.
CREATE TABLE ResourceCategory(
    id NUMBER PRIMARY KEY,
    name VARCHAR2(50) NOT NULL,
    description VARCHAR2 (200),
    allocation_mode VARCHAR2(10) DEFAULT 'pool' NOT NULL,
    hierarchy_level NUMBER DEFAULT 999,
    base_price NUMBER DEFAULT 0,
    metadata CLOB CHECK (metadata IS JSON),
    CONSTRAINT chk_allocation_mode CHECK (allocation_mode IN ('pool', 'direct'))
);

-- ResourceStatus: Allocation lifecycle states (DOMAIN-SPECIFIC)
-- These states define the progression of an allocation from request to completion.
-- Current implementation uses airline states; other domains would define different values.
CREATE TABLE ResourceStatus(
    name VARCHAR2(20) PRIMARY KEY,
    description VARCHAR2(100),
    metadata CLOB CHECK (metadata IS JSON)
);

-- ResourceInstanceStatus: Intrinsic/physical states of resource instances
-- Represents physical availability independent of allocation state.
-- Examples: available, maintenance, blocked, retired
CREATE TABLE ResourceInstanceStatus(
    name VARCHAR2(20) PRIMARY KEY,
    description VARCHAR2(100),
    metadata CLOB CHECK (metadata IS JSON)
);

-- ResourceAsset: Physical containers holding multiple resource instances
-- Examples: Aircraft D-AIHE (airline) | Hotel Building (hotel) | Fleet Depot (rental)
CREATE TABLE ResourceAsset(
    id NUMBER PRIMARY KEY,
    name VARCHAR2(50) NOT NULL,
    description VARCHAR2(200),
    status VARCHAR2(20) DEFAULT 'not active' NOT NULL,
    metadata CLOB CHECK (metadata IS JSON),
    CONSTRAINT chk_asset_status CHECK (status IN ('active', 'not active'))
);

-- AssetCapacity: Defines how many instances of each category an asset contains
-- Examples: Aircraft has 8 First Class, 42 Business, 200 Economy seats
CREATE TABLE AssetCapacity(
    id NUMBER PRIMARY KEY,
    asset_id NUMBER NOT NULL,
    category_id NUMBER NOT NULL,
    quantity NUMBER NOT NULL,
    metadata CLOB CHECK (metadata IS JSON),
    FOREIGN KEY (asset_id) REFERENCES ResourceAsset(id),
    FOREIGN KEY (category_id) REFERENCES ResourceCategory(id),
    UNIQUE(asset_id, category_id)
);

-- ResourceInstance: Individual allocatable units with unique identifiers
-- Examples: Seat 14A (airline) | Room 101 (hotel) | Vehicle ABC-123 (rental)
-- The instance_identifier is domain-specific (seat number, room number, license plate)
CREATE TABLE ResourceInstance(
    id NUMBER PRIMARY KEY,
    asset_id NUMBER NOT NULL,
    category_id NUMBER NOT NULL,
    instance_identifier VARCHAR2(50), -- Domain-specific: '14A', 'Room 101', 'ABC-123'
    status VARCHAR2(20) DEFAULT 'available' NOT NULL,
    metadata CLOB CHECK (metadata IS JSON),
    FOREIGN KEY (asset_id) REFERENCES ResourceAsset(id),
    FOREIGN KEY (category_id) REFERENCES ResourceCategory(id),
    FOREIGN KEY (status) REFERENCES ResourceInstanceStatus(name),
    UNIQUE(asset_id, instance_identifier)
);

-- Users: Entities that receive resource allocations (Allocatees)
-- Examples: Passenger (airline) | Guest (hotel) | Customer (rental) | Employee (equipment)
-- Note: In a fully generalized system, this could be renamed to "Allocatee" and support
-- allocation to tasks, projects, or other resources rather than just persons.
CREATE TABLE Users(
    id NUMBER PRIMARY KEY,
    name VARCHAR2(50) NOT NULL,
    metadata CLOB CHECK (metadata IS JSON)
);

-- AllocationContext: Temporal binding that defines when resources are available
-- Creates the time dimension for allocations.
-- Examples: Flight LH710 on Mar 15 | Hotel night Mar 15 | Rental period Mar 15-20
--
-- ASSET_ID is optional:
--   - For contained allocation (flights, hotels): Required. Determines which resources are available.
--   - For shared allocation (meetings, shared resources): Optional. The context represents
--     a time interval during which specific resources (from any asset) can be allocated.
CREATE TABLE AllocationContext(
    id NUMBER PRIMARY KEY,
    asset_id NUMBER,  -- Nullable for shared allocation contexts
    context_identifier VARCHAR2(100) NOT NULL, -- Domain-specific: 'LH710', 'MEETING-2025-03-15-10:00'
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    metadata CLOB CHECK (metadata IS JSON),
    FOREIGN KEY (asset_id) REFERENCES ResourceAsset(id)
);

-- Capacity: Real-time capacity tracking with lock-free counters
-- Uses Oracle's RESERVABLE columns for high-concurrency counter updates.
-- Counters are domain-agnostic and track capacity availability only.
CREATE TABLE Capacity(
    id NUMBER PRIMARY KEY,
    context_id NUMBER NOT NULL,
    category_id NUMBER NOT NULL,
    total_capacity NUMBER NOT NULL CONSTRAINT check_total_capacity CHECK (total_capacity >= 0),
    active_count NUMBER RESERVABLE DEFAULT 0 NOT NULL CONSTRAINT check_active_count CHECK (active_count >= 0),
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    metadata CLOB CHECK (metadata IS JSON),
    FOREIGN KEY (context_id) REFERENCES AllocationContext(id),
    FOREIGN KEY (category_id) REFERENCES ResourceCategory(id),
    UNIQUE(context_id, category_id),
    CONSTRAINT chk_capacity_valid CHECK (active_count <= total_capacity) DEFERRABLE INITIALLY DEFERRED
);
CREATE SEQUENCE Capacity_seq START WITH 1 INCREMENT BY 1 NOCACHE;

-- AllocationJournal: Immutable append-only log of all allocation state changes
-- This is the authoritative source for allocation history (event sourcing pattern).
-- Current state is derived via the CurrentAllocations materialized view.
-- Partitioned by context_id for:
-- - Performance: Queries for a specific context only scan one partition
-- - Isolation: Each context's journal is physically separated
-- - Maintenance: Can archive/purge old contexts independently
-- - Scalability: Parallel operations on different contexts
-- The 'status' column contains domain-specific allocation states.
CREATE TABLE AllocationJournal(
    id NUMBER PRIMARY KEY,
    context_id NUMBER NOT NULL,
    category_id NUMBER NOT NULL,
    user_id NUMBER,
    resource_instance_id NUMBER, -- New column to link to a specific instance
    status VARCHAR2(20) NOT NULL, -- e.g., 'reserved', 'confirmed', 'cancelled'
    entry_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata CLOB CHECK (metadata IS JSON),
    CONSTRAINT fk_journal_context FOREIGN KEY (context_id) REFERENCES AllocationContext(id),
    CONSTRAINT fk_journal_category FOREIGN KEY (category_id) REFERENCES ResourceCategory(id),
    CONSTRAINT fk_journal_user FOREIGN KEY (user_id) REFERENCES Users(id),
    CONSTRAINT fk_journal_instance FOREIGN KEY (resource_instance_id) REFERENCES ResourceInstance(id),
    CONSTRAINT fk_journal_status FOREIGN KEY (status) REFERENCES ResourceStatus(name),
    CONSTRAINT chk_journal_user_blocked CHECK (
        (status = 'blocked' AND user_id IS NULL) OR
        (status <> 'blocked' AND user_id IS NOT NULL)
    )
)
PARTITION BY LIST (context_id)
(
    PARTITION journal_default VALUES (DEFAULT)
)
ENABLE ROW MOVEMENT;

-- Note: New partitions are automatically created when inserting new context_id values
-- due to automatic list partitioning (Oracle 12c+) or can be manually added:
-- ALTER TABLE AllocationJournal ADD PARTITION journal_ctx_<id> VALUES (<context_id>);

-- AllocationJournal_seq already created above

-- Workflow Tables
CREATE TABLE WorkflowLog (
    id NUMBER PRIMARY KEY,
    event_id VARCHAR2(255),
    workflow_id NUMBER,
    wf_static_id VARCHAR2(255),
    act_static_id VARCHAR2(255),
    message VARCHAR2(4000),
    message_ts TIMESTAMP,
    status VARCHAR2(255),
    metadata CLOB CHECK (metadata IS JSON)
);
CREATE SEQUENCE WorkflowLog_seq;

CREATE TABLE WorkflowCollaboration (
    id NUMBER PRIMARY KEY,
    event_id VARCHAR2(255),
    workflow_id NUMBER,
    collaboration_name VARCHAR2(255),
    collaboration_start TIMESTAMP,
    collaboration_end TIMESTAMP,
    event_data CLOB,
    state VARCHAR2(255),
    activity_static_id VARCHAR2(255),
    metadata CLOB CHECK (metadata IS JSON)
);
CREATE SEQUENCE WorkflowCollaboration_seq;

-- Simple Debugging Table
CREATE TABLE DebugLog (
    id NUMBER PRIMARY KEY,
    message VARCHAR2(4000),
    log_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata CLOB CHECK (metadata IS JSON)
);

-- CategorySubstitution: Defines allowed substitutions between categories with cost adjustments
-- Enables offering alternative resource categories when requested category is unavailable.
-- Supports hierarchy-based upgrades/downgrades with cost adjustments.
-- hierarchy_level: 1 = highest tier (e.g., First Class), higher numbers = lower tiers
CREATE TABLE CategorySubstitution(
    id NUMBER PRIMARY KEY,
    from_category_id NUMBER NOT NULL,
    to_category_id NUMBER NOT NULL,
    cost_adjustment NUMBER DEFAULT 0,
    priority NUMBER DEFAULT 1,
    is_allowed VARCHAR2(1) DEFAULT 'Y' NOT NULL,
    auto_offer VARCHAR2(1) DEFAULT 'N' NOT NULL,
    requires_approval VARCHAR2(1) DEFAULT 'N' NOT NULL,
    valid_from DATE DEFAULT SYSDATE,
    valid_until DATE,
    metadata CLOB CHECK (metadata IS JSON),
    CONSTRAINT fk_sub_from_category FOREIGN KEY (from_category_id) REFERENCES ResourceCategory(id),
    CONSTRAINT fk_sub_to_category FOREIGN KEY (to_category_id) REFERENCES ResourceCategory(id),
    CONSTRAINT uq_category_substitution UNIQUE(from_category_id, to_category_id),
    CONSTRAINT chk_sub_allowed CHECK (is_allowed IN ('Y', 'N')),
    CONSTRAINT chk_sub_auto_offer CHECK (auto_offer IN ('Y', 'N')),
    CONSTRAINT chk_sub_approval CHECK (requires_approval IN ('Y', 'N')),
    CONSTRAINT chk_sub_not_same CHECK (from_category_id != to_category_id)
);

-- -----------------------------------------------------------------------------
-- Step 3: Create Views for Querying Current State
-- -----------------------------------------------------------------------------

-- ActiveAllocation: Real-time lock table enforcing one active allocation per
-- (context_id, resource_instance_id). Maintained by AddAllocationJournal:
--   - INSERT when a new active status is written (reserved, confirmed, etc.)
--   - DELETE when cancelled or completed.
-- The UNIQUE constraint fires inside the autonomous transaction, providing
-- real-time duplicate prevention (unlike a MATERIALIZED VIEW unique index,
-- which only fires during DBMS_MVIEW.REFRESH).
CREATE TABLE ActiveAllocation (
    context_id           NUMBER NOT NULL,
    resource_instance_id NUMBER NOT NULL,
    journal_id           NUMBER NOT NULL,
    CONSTRAINT uq_active_allocation UNIQUE (context_id, resource_instance_id),
    CONSTRAINT fk_aa_context  FOREIGN KEY (context_id)           REFERENCES AllocationContext(id),
    CONSTRAINT fk_aa_instance FOREIGN KEY (resource_instance_id) REFERENCES ResourceInstance(id)
);

-- View to get the current (latest) allocation status for each resource instance.
-- Exactly one row per (context_id, resource_instance_id): the latest journal row
-- by insert order (id DESC), so that a subsequent 'cancelled' or 'completed' entry
-- is always the one considered. Those rows are then excluded so the resource
-- appears available again.
CREATE OR REPLACE VIEW CurrentAllocations AS
SELECT
    journal_id,
    context_id,
    category_id,
    user_id,
    resource_instance_id,
    status,
    entry_timestamp
FROM (
    SELECT
        aj.id AS journal_id,
        aj.context_id,
        aj.category_id,
        aj.user_id,
        aj.resource_instance_id,
        aj.status,
        aj.entry_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY aj.context_id, aj.resource_instance_id
            ORDER BY aj.id DESC
        ) AS rn
    FROM AllocationJournal aj
) latest
WHERE latest.rn = 1
  AND latest.status NOT IN ('cancelled', 'completed');

-- View to get allocation history for audit purposes
CREATE OR REPLACE VIEW AllocationHistory AS
SELECT 
    aj.id,
    aj.context_id,
    ac.context_identifier,
    aj.category_id,
    rc.name as category_name,
    aj.user_id,
    u.name as user_name,
    aj.resource_instance_id,
    ri.instance_identifier,
    aj.status,
    aj.entry_timestamp
FROM AllocationJournal aj
JOIN AllocationContext ac ON aj.context_id = ac.id
JOIN ResourceCategory rc ON aj.category_id = rc.id
JOIN Users u ON aj.user_id = u.id
LEFT JOIN ResourceInstance ri ON aj.resource_instance_id = ri.id
ORDER BY aj.entry_timestamp ASC;

-- View to get the schedule of a resource across all contexts (for shared allocation mode).
-- Shows only active allocations (excludes cancelled/completed) with their time intervals.
CREATE OR REPLACE VIEW ResourceSchedule AS
SELECT 
    ca.resource_instance_id,
    ri.instance_identifier,
    ca.context_id,
    ac.context_identifier,
    ac.start_date AS context_start,
    ac.end_date AS context_end,
    ca.status,
    ca.user_id,
    ca.category_id
FROM CurrentAllocations ca
JOIN AllocationContext ac ON ca.context_id = ac.id
JOIN ResourceInstance ri ON ca.resource_instance_id = ri.id
WHERE ca.resource_instance_id IS NOT NULL
  AND ca.status NOT IN ('cancelled', 'completed');

-- View for Available Substitutions
-- Calculates substitution type (upgrade/downgrade) based on hierarchy
CREATE OR REPLACE VIEW AvailableSubstitutions AS
SELECT 
    cs.id AS substitution_id,
    cs.from_category_id,
    rc_from.name AS from_category_name,
    rc_from.hierarchy_level AS from_hierarchy,
    rc_from.base_price AS from_base_price,
    cs.to_category_id,
    rc_to.name AS to_category_name,
    rc_to.hierarchy_level AS to_hierarchy,
    rc_to.base_price AS to_base_price,
    CASE 
        WHEN rc_to.hierarchy_level < rc_from.hierarchy_level THEN 'upgrade'
        WHEN rc_to.hierarchy_level > rc_from.hierarchy_level THEN 'downgrade'
        ELSE 'lateral'
    END AS substitution_type,
    cs.cost_adjustment,
    cs.priority,
    cs.is_allowed,
    cs.auto_offer,
    cs.requires_approval
FROM CategorySubstitution cs
JOIN ResourceCategory rc_from ON cs.from_category_id = rc_from.id
JOIN ResourceCategory rc_to ON cs.to_category_id = rc_to.id
WHERE cs.is_allowed = 'Y'
  AND (cs.valid_from IS NULL OR cs.valid_from <= SYSDATE)
  AND (cs.valid_until IS NULL OR cs.valid_until >= SYSDATE)
ORDER BY cs.from_category_id, cs.priority;

-- View for Context-Aware Substitutions
-- Shows which substitutions have available capacity for a given context
CREATE OR REPLACE VIEW SubstitutionAvailability AS
SELECT 
    avs.*,
    c.context_id,
    ac.context_identifier,
    (c.total_capacity - c.active_count) AS to_category_available
FROM AvailableSubstitutions avs
JOIN Capacity c ON c.category_id = avs.to_category_id
JOIN AllocationContext ac ON c.context_id = ac.id
WHERE (c.total_capacity - c.active_count) > 0;

COMMIT;
/
