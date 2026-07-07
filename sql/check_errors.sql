-- Script to check compilation errors
SET SERVEROUTPUT ON;
SET LINESIZE 200;
SET PAGESIZE 1000;

PROMPT ===============================================================================
PROMPT Checking Package Compilation Errors
PROMPT ===============================================================================
PROMPT

PROMPT --- ResourceManagement_Data Package Body Errors ---
SELECT line, position, text
FROM user_errors
WHERE name = 'RESOURCEMANAGEMENT_DATA'
  AND type = 'PACKAGE BODY'
ORDER BY sequence;

PROMPT
PROMPT --- ResourceManagement Package Body Errors ---
SELECT line, position, text
FROM user_errors
WHERE name = 'RESOURCEMANAGEMENT'
  AND type = 'PACKAGE BODY'
ORDER BY sequence;

PROMPT
PROMPT --- Package Status ---
SELECT object_name, object_type, status
FROM user_objects
WHERE object_name IN ('RESOURCEMANAGEMENT', 'RESOURCEMANAGEMENT_DATA')
ORDER BY object_name, object_type;

