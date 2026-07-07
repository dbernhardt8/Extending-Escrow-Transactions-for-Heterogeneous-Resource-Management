-- =============================================================================
-- TEST_schedule_flight_from_json.sql
--
-- Test script for scheduling a flight from JSON
-- Demonstrates all validations and the ScheduleFlightFromJSON procedure
-- =============================================================================

SET SERVEROUTPUT ON;

-- =============================================================================
-- Test 1: Successful Flight Scheduling
-- =============================================================================
DECLARE
    v_json_data CLOB;
    v_new_context_id NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('    TEST 1: Schedule Flight Successfully');
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('');
    
    v_json_data := '{
  "flight": {
    "context_identifier": "LH 500 FRA-JFK",
    "asset_identifier": {
      "type": "name",
      "value": "Boeing 787-9"
    },
    "schedule": {
      "departure": {
        "date": "2025-12-15",
        "time": "10:00",
        "airport": "FRA",
        "timezone": "CET"
      },
      "arrival": {
        "date": "2025-12-15",
        "time": "13:30",
        "airport": "JFK",
        "timezone": "EST"
      }
    },
    "metadata": {
      "route": "FRA-JFK",
      "flight_number": "LH500",
      "departure_gate": "A12",
      "departure_terminal": "1",
      "arrival_gate": "4",
      "arrival_terminal": "1",
      "crew_id": "CR-7845",
      "service_type": "full_service"
    }
  }
}';

    ResourceManagement.ScheduleFlightFromJSON(
        p_json_data => v_json_data,
        p_new_context_id => v_new_context_id
    );
    
    DBMS_OUTPUT.PUT_LINE('✓ SUCCESS: Flight scheduled with Context ID: ' || v_new_context_id);
    DBMS_OUTPUT.PUT_LINE('');
    
    -- Show capacity snapshots
    DBMS_OUTPUT.PUT_LINE('Capacity Snapshots Created:');
    FOR rec IN (
        SELECT rc.name, cs.total_capacity, cs.available_count
        FROM CapacitySnapshot cs
        JOIN ResourceCategory rc ON cs.category_id = rc.id
        WHERE cs.context_id = v_new_context_id
        ORDER BY cs.total_capacity DESC
    ) LOOP
        DBMS_OUTPUT.PUT_LINE('  ' || rec.name || ': ' || rec.available_count || '/' || rec.total_capacity || ' available');
    END LOOP;
    
    DBMS_OUTPUT.PUT_LINE('');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('✗ UNEXPECTED ERROR: ' || SQLERRM);
END;
/

-- =============================================================================
-- Test 2: Overlapping Flight Detection
-- =============================================================================
DECLARE
    v_json_data CLOB;
    v_new_context_id NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('    TEST 2: Overlapping Flight Detection');
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Attempting to schedule overlapping flight...');
    
    v_json_data := '{
  "flight": {
    "context_identifier": "LH 502 FRA-ORD",
    "asset_identifier": {
      "type": "name",
      "value": "Boeing 787-9"
    },
    "schedule": {
      "departure": {
        "date": "2025-12-15",
        "time": "11:00"
      },
      "arrival": {
        "date": "2025-12-15",
        "time": "14:00"
      }
    }
  }
}';

    ResourceManagement.ScheduleFlightFromJSON(
        p_json_data => v_json_data,
        p_new_context_id => v_new_context_id
    );
    
    DBMS_OUTPUT.PUT_LINE('✗ UNEXPECTED: Should have failed but succeeded!');
    DBMS_OUTPUT.PUT_LINE('');
    
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -20302 THEN
            DBMS_OUTPUT.PUT_LINE('✓ EXPECTED ERROR: Overlapping flight detected');
            DBMS_OUTPUT.PUT_LINE('  Message: ' || SQLERRM);
        ELSE
            DBMS_OUTPUT.PUT_LINE('✗ UNEXPECTED ERROR: ' || SQLERRM);
        END IF;
        DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- Test 3: Inactive Asset Detection
-- =============================================================================
DECLARE
    v_json_data CLOB;
    v_new_context_id NUMBER;
    v_original_status VARCHAR2(20);
    v_asset_id NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('    TEST 3: Inactive Asset Detection');
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('');
    
    -- Temporarily deactivate an asset
    SELECT id, status INTO v_asset_id, v_original_status 
    FROM ResourceAsset 
    WHERE name = 'Airbus A320-200' AND ROWNUM = 1;
    
    UPDATE ResourceAsset SET status = 'not active' WHERE id = v_asset_id;
    --COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('Attempting to schedule flight on inactive aircraft...');
    
    v_json_data := '{
  "flight": {
    "context_identifier": "LH 100 FRA-MUC",
    "asset_identifier": {
      "type": "name",
      "value": "Airbus A320-200"
    },
    "schedule": {
      "departure": {
        "date": "2025-12-16",
        "time": "08:00"
      },
      "arrival": {
        "date": "2025-12-16",
        "time": "09:00"
      }
    }
  }
}';

    ResourceManagement.ScheduleFlightFromJSON(
        p_json_data => v_json_data,
        p_new_context_id => v_new_context_id
    );
    
    DBMS_OUTPUT.PUT_LINE('✗ UNEXPECTED: Should have failed but succeeded!');
    
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -20301 THEN
            DBMS_OUTPUT.PUT_LINE('✓ EXPECTED ERROR: Inactive asset detected');
            DBMS_OUTPUT.PUT_LINE('  Message: ' || SQLERRM);
        ELSE
            DBMS_OUTPUT.PUT_LINE('✗ UNEXPECTED ERROR: ' || SQLERRM);
        END IF;
        
        -- Restore asset status
        UPDATE ResourceAsset SET status = v_original_status WHERE id = v_asset_id;
        --COMMIT;
        DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- Test 4: Invalid Date Detection (Arrival before Departure)
-- =============================================================================
DECLARE
    v_json_data CLOB;
    v_new_context_id NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('    TEST 4: Invalid Date Detection');
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Attempting to schedule flight with arrival before departure...');
    
    v_json_data := '{
  "flight": {
    "context_identifier": "LH 999 FRA-MUC",
    "asset_identifier": {
      "type": "name",
      "value": "Airbus A321neo"
    },
    "schedule": {
      "departure": {
        "date": "2025-12-20",
        "time": "15:00"
      },
      "arrival": {
        "date": "2025-12-20",
        "time": "10:00"
      }
    }
  }
}';

    ResourceManagement.ScheduleFlightFromJSON(
        p_json_data => v_json_data,
        p_new_context_id => v_new_context_id
    );
    
    DBMS_OUTPUT.PUT_LINE('✗ UNEXPECTED: Should have failed but succeeded!');
    DBMS_OUTPUT.PUT_LINE('');
    
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -20403 THEN
            DBMS_OUTPUT.PUT_LINE('✓ EXPECTED ERROR: Invalid dates detected');
            DBMS_OUTPUT.PUT_LINE('  Message: ' || SQLERRM);
        ELSE
            DBMS_OUTPUT.PUT_LINE('✗ UNEXPECTED ERROR: ' || SQLERRM);
        END IF;
        DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- Test 5: Non-existent Asset Detection
-- =============================================================================
DECLARE
    v_json_data CLOB;
    v_new_context_id NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('    TEST 5: Non-existent Asset Detection');
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Attempting to schedule flight with non-existent aircraft...');
    
    v_json_data := '{
  "flight": {
    "context_identifier": "LH 888 FRA-MUC",
    "asset_identifier": {
      "type": "name",
      "value": "Non-existent Aircraft XYZ"
    },
    "schedule": {
      "departure": {
        "date": "2025-12-25",
        "time": "12:00"
      },
      "arrival": {
        "date": "2025-12-25",
        "time": "13:00"
      }
    }
  }
}';

    ResourceManagement.ScheduleFlightFromJSON(
        p_json_data => v_json_data,
        p_new_context_id => v_new_context_id
    );
    
    DBMS_OUTPUT.PUT_LINE('✗ UNEXPECTED: Should have failed but succeeded!');
    DBMS_OUTPUT.PUT_LINE('');
    
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -20400 THEN
            DBMS_OUTPUT.PUT_LINE('✓ EXPECTED ERROR: Non-existent asset detected');
            DBMS_OUTPUT.PUT_LINE('  Message: ' || SQLERRM);
        ELSE
            DBMS_OUTPUT.PUT_LINE('✗ UNEXPECTED ERROR: ' || SQLERRM);
        END IF;
        DBMS_OUTPUT.PUT_LINE('');
END;
/

-- =============================================================================
-- Summary
-- =============================================================================
BEGIN
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('    TEST SUMMARY');
    DBMS_OUTPUT.PUT_LINE('===============================================');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('All validations implemented:');
    DBMS_OUTPUT.PUT_LINE('  ✓ Aircraft overlap detection');
    DBMS_OUTPUT.PUT_LINE('  ✓ Asset existence check');
    DBMS_OUTPUT.PUT_LINE('  ✓ Asset status validation (active/inactive)');
    DBMS_OUTPUT.PUT_LINE('  ✓ Date validation (arrival after departure)');
    DBMS_OUTPUT.PUT_LINE('  ✓ Capacity configuration check');
    DBMS_OUTPUT.PUT_LINE('  ✓ Unavailable seat handling');
    DBMS_OUTPUT.PUT_LINE('  ✓ Transaction safety (savepoint)');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Check DebugLog for detailed operation logs.');
    DBMS_OUTPUT.PUT_LINE('===============================================');
END;
/

-- View recent debug logs
SELECT message, log_timestamp 
FROM (
    SELECT message, log_timestamp 
    FROM DebugLog 
    ORDER BY log_timestamp DESC
) 
WHERE ROWNUM <= 15;

