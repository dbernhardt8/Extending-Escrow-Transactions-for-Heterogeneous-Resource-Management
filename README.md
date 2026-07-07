# Journal-Based Resource Planning System

> **Master Thesis Project**  
> *From Escrow to Event Sourcing: Journal-Based Resource Planning for Heterogeneous Allocation*  
> Dominik Bernhardt | Humboldt-Universität zu Berlin | 2025

A database-native resource planning system that extends traditional aggregate-based escrow mechanisms to support **heterogeneous resource management** with individual state tracking, workflow integration, and complete audit trails.

---

## Table of Contents

- [Executive Summary](#executive-summary)
- [Motivation](#motivation)
- [Scope](#scope)
- [System Architecture](#system-architecture)
- [Key Innovations](#key-innovations)
- [Getting Started](#getting-started)
- [Usage Examples](#usage-examples)
- [Project Structure](#project-structure)
- [Documentation](#documentation)
- [Troubleshooting](#troubleshooting)

---

## Executive Summary

**Problem:** Traditional database systems manage resources through aggregate counters (escrow transactions), which work well for homogeneous items like inventory stock. However, they fail when resources are *heterogeneous*—possessing unique identities, varying properties, and complex lifecycles (e.g., airline seats, conference rooms, specialized equipment).

**Solution:** This project implements a **journal-based resource planning system** where:
- Every resource instance has a unique identity and trackable state
- All state changes are recorded in an immutable audit journal
- Resources integrate natively with workflow engines through event-driven mechanisms
- Compensation (undo) operations are systematically paired with every state change

**Use Case:** Airline seat reservation demonstrating the full lifecycle: `reserve → confirm → check-in → board`, with automatic timeout handling, flight cancellation sagas, and type-based seat substitution.

---

## Motivation

### The Gap in Current Systems

```
Traditional Escrow (Aggregate)          This System (Individual + Journal)
─────────────────────────────           ─────────────────────────────────
Economy seats: 290 available            Seat 14A: reserved by User 42
Economy seats: 289 available  ← UPDATE  Seat 14A: confirmed at 10:32 AM
Economy seats: 288 available            Seat 14A: checked-in at 14:15 PM
(history lost)                          (complete audit trail preserved)
```

**Current systems fail when:**
- Individual resources have unique properties (window vs. aisle seat)
- Regulatory compliance requires audit trails (who had which seat?)
- Complex state machines govern resource lifecycles
- Long-running workflows need compensation on failure

**This system addresses these gaps by:**
1. **Treating resources as first-class database objects** with intrinsic behavior
2. **Recording all state changes** in an append-only journal (event sourcing)
3. **Integrating with workflow engines** through Oracle Transactional Event Queues
4. **Providing systematic compensation** for every operation

### Research Context

This project builds on the research proposal *"Foundations of Resource Planning Systems"* by Prof. Matthias Weidlich, Ralf Müller, and Dr. Dieter Gawlick, which identified the need for database systems to support:
- Resource type hierarchies with substitution
- Temporal perspectives (future reservations)
- Lifecycle models with workflow integration

---

## Scope

### In Scope

| Feature | Description |
|---------|-------------|
| **Individual Resource Tracking** | Each seat, room, or asset has a unique ID and state |
| **State Lifecycle Management** | Defined transitions: reserved → confirmed → checked-in → boarded |
| **Compensating Transactions** | Every operation has an inverse (reserve ↔ cancel, confirm ↔ unconfirm) |
| **Event-Driven Timeouts** | Automatic cancellation of unpaid reservations via Oracle AQ |
| **Workflow Integration** | Oracle Workflow Service integration via Transactional Event Queues |
| **Immutable Audit Journal** | Complete history for compliance and debugging |
| **Type Substitution** | Cost-based upgrades when preferred category unavailable |
| **Delay Detection** | Identify affected allocations when schedules slip |

### Out of Scope (Future Work)

- Optimization algorithms for resource scheduling (uses first-fit allocation)
- Automatic delay propagation and cascading rescheduling
- Multi-context operations (e.g., atomic round-trip bookings)

---

## System Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Business Workflows                                │
│                    (Reservations, Check-ins, Payments)                   │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ Events (TxEventQ)
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     Oracle Database 23ai                                 │
├─────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │           ResourceManagement Package (Business Logic)            │   │
│  │  • MakeReservation (optional timeout) • CancelFlight (Saga)    │   │
│  │  • ConfirmReservation           • CheckInUser / BoardUser       │   │
│  │  • Type Substitution Logic      • Delay Detection               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                     │
│  ┌─────────────────────────────────┴───────────────────────────────┐   │
│  │           ResourceManagement_Data Package (Data Layer)           │   │
│  │  • CRUD Operations              • Lock-free capacity counters   │   │
│  │  • Autonomous journal writes    • Capacity reconciliation       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                     │
│  ┌─────────────────────────────────┴───────────────────────────────┐   │
│  │                    Data Model                                    │   │
│  │  ResourceCategory → ResourceAsset → ResourceInstance             │   │
│  │  AllocationContext (temporal) → AllocationJournal (immutable)   │   │
│  │  Capacity (RESERVABLE counters for lock-free updates)           │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                     │
│  ┌─────────────────────────────────┴───────────────────────────────┐   │
│  │           Oracle Advanced Queue (Timeout & Events)               │   │
│  │  • Delayed message delivery for reservation timeouts             │   │
│  │  • Callback-triggered compensation                               │   │
│  │  • Workflow event emission                                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

### Data Model

```
ResourceCategory          ResourceAsset              ResourceInstance
(Economy, Business)  ───▶ (Aircraft A350)  ───────▶ (Seat 14A, 14B, ...)
                               │
                               ▼
                     AllocationContext
                     (Flight LH710, Dec 25)
                               │
                               ▼
                     AllocationJournal (Immutable)
                     ├─ User 42 reserved Seat 14A at 10:00
                     ├─ User 42 confirmed Seat 14A at 10:15
                     └─ User 42 checked-in Seat 14A at 14:30
```

### Two-State Model

A key innovation is separating **intrinsic states** from **allocation states**:

| State Type | Examples | Purpose |
|------------|----------|---------|
| **Intrinsic** (Physical) | available, under_maintenance, blocked | Can this resource be used? |
| **Allocation** (Business) | reserved, confirmed, checked-in, boarded | Who is using it and when? |

This separation enables scenarios like: *"Seat 14A is under maintenance for cleaning, but User 42's confirmed booking for tomorrow remains valid."*

---

## Key Innovations

### 1. Journal-Based State Management
```sql
-- State is NEVER updated in place. Every change is a new journal entry:
INSERT INTO AllocationJournal (status, ...) VALUES ('reserved', ...);
INSERT INTO AllocationJournal (status, ...) VALUES ('confirmed', ...);
-- Current state = latest journal entry for each resource+context
```

### 2. Systematic Compensation
Every procedure has an inverse:
| Forward | Inverse |
|---------|---------|
| `MakeReservation` | `CancelReservation` |
| `ConfirmReservation` | `UnconfirmReservation` |
| `CheckInUser` | `CancelCheckIn` |
| `BoardUser` | `OffboardUser` |

### 3. Lock-Free Capacity Counters
Using Oracle 23ai `RESERVABLE` columns for high-concurrency updates without row locks:
```sql
-- Multiple transactions can update simultaneously
UPDATE Capacity SET available_count = available_count - 1 WHERE id = :id;
UPDATE Capacity SET reserved_count = reserved_count + 1 WHERE id = :id;
```

### 4. Event-Driven Timeouts (Saga Pattern)
```
T₀: User reserves seat
    └─ Enqueue timeout message (delay = 15 minutes)

T₀+15min: Oracle AQ fires callback
    └─ If still 'reserved' → CancelReservation()
    └─ If already 'confirmed' → Ignore (user paid)
```

---

## Getting Started

### Prerequisites
- **Podman** & **Podman Compose** (or Docker)
- **SQL*Plus** or compatible Oracle client

### 1. Start Database Container
```bash
podman compose up -d
```

### 2. Connect to Database
```bash
podman exec -it semesterprojekt-oraclefree-1 bash
sqlplus DEV_SCHEMA/1234@//localhost:1521/FREEPDB1
```

### 3. Install System
```sql
-- Complete installation (schema + packages + queue + mock data)
@sql/0_complete_system_setup.sql
```

### 4. Verify Installation
```sql
-- Expected output: "✓ SETUP COMPLETE - ALL CHECKS PASSED"
```

### Database Credentials

| Role | Username | Password | Connection |
|------|----------|----------|------------|
| Admin | `SYS` | `1234` | Connect as SYSDBA |
| Application | `DEV_SCHEMA` | `1234` | `localhost:1521/FREEPDB1` |

---

## Usage Examples

### Reserve Seats with Timeout
```sql
DECLARE
  v_journal_ids SYS.ODCINUMBERLIST;
BEGIN
  ResourceManagement.MakeReservation(
    p_context_identifier => 'LH 710 MUC-HND',
    p_category_name      => 'Business Class',
    p_user_id            => 1,
    p_quantity           => 2,
    p_timeout_minutes    => 15,
    p_new_journal_ids    => v_journal_ids
  );
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Reserved seats. Journal IDs: ' || v_journal_ids(1));
END;
/
```

### Confirm Reservation (Payment Received)
```sql
BEGIN
  ResourceManagement.ConfirmReservation(p_journal_id => 2001);
  COMMIT;
END;
/
```

### Cancel Entire Flight (Saga)
```sql
BEGIN
  ResourceManagement.CancelFlight(
    p_context_identifier => 'LH 710 MUC-HND',
    p_reason             => 'Weather conditions'
  );
  COMMIT;
  -- All reservations cancelled, notifications triggered
END;
/
```

### View Current Capacity
```sql
SELECT ac.context_identifier AS flight, 
       rc.name AS class,
       c.total_capacity,
       c.available_count, 
       c.reserved_count, 
       c.confirmed_count
FROM Capacity c
JOIN AllocationContext ac ON c.context_id = ac.id
JOIN ResourceCategory rc ON c.category_id = rc.id
WHERE ac.context_identifier = 'LH 710 MUC-HND';
```

---

## Testing (utPLSQL)

The **ResourceManagement** package is covered by a utPLSQL test suite in `tests/`. Tests are self-contained (Arrange–Act–Assert + Teardown) and use literal expectations only.

**Connection (local DB container):**
```bash
sql dominikbernhardt/apex@localhost:2309/main
```

**Setup:** Install [utPLSQL](https://github.com/utPLSQL/utPLSQL/releases) into your schema, then install the test packages:
```bash
sql dominikbernhardt/apex@localhost:2309/main @tests/ut_resource_management.pks
sql dominikbernhardt/apex@localhost:2309/main @tests/ut_resource_management.pkb
```

**Run the suite:**
```sql
BEGIN ut.run('ut_resource_management'); END;
/
```

See **[tests/README_utplsql.md](tests/README_utplsql.md)** for full install and run instructions, and **docs/instruction_utplsql_setup.md** for the test design context.

---

## Project Structure

```
├── sql/                              # Database installation scripts
│   ├── 0_cleanup_all.sql             # Complete cleanup
│   ├── 0_complete_system_setup.sql   # One-command setup
│   ├── 1_database_model.sql          # Schema (tables, views, sequences)
│   ├── 1.5_aq_setup.sql              # Oracle Advanced Queue setup
│   ├── 2.1_database_specification.pks # Business logic package spec
│   ├── 2.2_database_body.pkb         # Business logic implementation
│   ├── 3.1_crud_specification.pks    # Data layer package spec
│   ├── 3.2_crud_body.pkb             # Data layer implementation
│   └── 4_insert_mock_data_extensive.sql
│
├── tests/                            # utPLSQL test suite
│   ├── README_utplsql.md             # Install & run instructions
│   ├── ut_resource_management.pks    # Test suite spec
│   └── ut_resource_management.pkb    # Test suite body (unit + workflow tests)
│
├── docs/                             # Project planning documents
│   ├── MASTER_THESIS_OUTLINE.md      # Detailed thesis outline
│   ├── project overview.txt          # Original research proposal
│   └── Resource Planning System - Formal Problem Definition.txt
│
└── compose.yaml                      # Podman/Docker compose file
```

---

## Documentation

| Document | Description |
|----------|-------------|
| [SHOWCASE.md](SHOWCASE.md) | Implementation overview and design principles |
| [SETUP_AND_RESET_GUIDE.md](SETUP_AND_RESET_GUIDE.md) | Detailed setup and troubleshooting |
| [docs/MASTER_THESIS_OUTLINE.md](expose/MASTER_THESIS_OUTLINE.md) | Complete thesis structure and status |
| [docs/PROCEDURE_FLOW_ANALYSIS.md](expose/PROCEDURE_FLOW_ANALYSIS.md) | Detailed procedure documentation |

---

## Troubleshooting

### Check Package Compilation
```sql
SELECT object_name, object_type, status 
FROM user_objects 
WHERE object_name LIKE 'RESOURCEMANAGEMENT%'
ORDER BY object_name, object_type;
```

### View Compilation Errors
```sql
SHOW ERRORS PACKAGE BODY ResourceManagement;
```

### Check Queue Status
```sql
SELECT name, enqueue_enabled, dequeue_enabled FROM user_queues;
```

### Reset Everything
```sql
@sql/0_cleanup_all.sql
@sql/0_complete_system_setup.sql
```

### Container Management
```bash
podman compose up -d      # Start
podman compose down       # Stop
podman compose down -v    # Stop and delete volumes (full reset)
```

---

## Technical Stack

- **Database:** Oracle Database 23ai Free
- **Queuing:** Oracle Advanced Queuing (AQ) / Transactional Event Queues
- **Language:** PL/SQL
- **Containerization:** Podman / Docker
- **Documentation:** LaTeX

---

## Contact

**Author:** Dominik Bernhardt  
**Supervisors:** Prof. Dr. Matthias Weidlich, Prof. Dr. Ralf Müller, Dr. Dieter Gawlick  
**Institution:** Humboldt-Universität zu Berlin

---

*This project is part of a Master's thesis exploring journal-based resource planning systems with workflow integration.*

Oracle Setup Recommendation:

Schema:           RPS
Password:         <your-secure-password>
Tablespace:       RPS_DATA
Temp Tablespace:  TEMP

APEX Workspace:   RPS_WS
APEX App Name:    Resource Planning System
APEX App Alias:   rps
APEX Admin User:  RPS_ADMIN

Queue:            RPS_EVENTS_Q
Consumer:         RPS_EVENTS_QC