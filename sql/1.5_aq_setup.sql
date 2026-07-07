SET SERVEROUTPUT ON;
-- Queue and callback are created in the CURRENT USER's schema so that enqueue
-- (ResourceManagement uses queue name 'WF_USER_EVENTS_Q' without schema) and
-- notification registration refer to the same queue. See docs/AQ_CALLBACK_ANALYSIS.md.
-- REQUIRED: job_queue_processes > 0 for callback to run when delayed messages become READY.
declare
    l_user_schema            varchar2(32)           := user;

    c_wf_user_events_qc      constant varchar2(32)    := 'WF_USER_EVENTS_QC'; -- Queue consumer
    c_wf_user_events_qt      constant varchar2(32)    := 'WF_USER_EVENTS_QT'; -- Queue table
    c_wf_user_events_q       constant varchar2(32)    := 'WF_USER_EVENTS_Q';  -- Queue name

    c_queue_payload_type     constant varchar2(32)    := 'SYS.AQ$_JMS_TEXT_MESSAGE';

begin

    -- Create Queue Table for User Events Queue.
    -- IMPORTANT: Set multiple_consumers => TRUE to properly support subscribers
    dbms_aqadm.create_queue_table (
        queue_table        => l_user_schema || '.' || c_wf_user_events_qt,
        queue_payload_type => c_queue_payload_type,
        multiple_consumers => TRUE);
    dbms_output.put_line('-- User Events Queue Table created with multiple_consumers=TRUE.');

    -- Create Queue for User Events Queue.
    dbms_aqadm.create_queue (
        queue_name            => l_user_schema || '.' || c_wf_user_events_q,
        queue_table           => l_user_schema || '.' || c_wf_user_events_qt,
        queue_type            => dbms_aqadm.normal_queue,
        max_retries           => 0,
        retry_delay           => 0,
        retention_time        => 0,
        dependency_tracking   => false,
        comment               => 'Workflow User Events Queue.');
    dbms_output.put_line('-- User Events Queue created.');

    dbms_aqadm.start_queue(l_user_schema || '.' || c_wf_user_events_q);
    dbms_output.put_line('-- User Events Queue started.');

    -- Add subscriber (required for multi-consumer queue with callbacks)
    dbms_aqadm.add_subscriber(
        queue_name => l_user_schema || '.' || c_wf_user_events_q,
        subscriber => sys.aq$_agent(
                          c_wf_user_events_qc,
                          l_user_schema || '.' || c_wf_user_events_q,
                          0));
    dbms_output.put_line('-- User Events Queue subscriber "' || c_wf_user_events_qc || '" added.');
    
    -- Register the callback to our ResourceManagement package
    -- This tells Oracle AQ to automatically invoke the PL/SQL procedure when messages arrive
    dbms_aq.register(
        reg_list   => sys.aq$_reg_info_list(
            sys.aq$_reg_info(
                l_user_schema || '.' || c_wf_user_events_q || ':' || c_wf_user_events_qc,
                dbms_aq.namespace_aq,
                'plsql://' || l_user_schema || '.ResourceManagement.user_events_callback' || '?PR=0',
                hextoraw('FF'))),
        reg_count  => 1);
    dbms_output.put_line('-- Callback registered to: ' || l_user_schema || '.ResourceManagement.user_events_callback');
    dbms_output.put_line('');
    dbms_output.put_line('*** AQ SETUP COMPLETE ***');
    dbms_output.put_line('Queue: ' || l_user_schema || '.' || c_wf_user_events_q);
    dbms_output.put_line('Subscriber: ' || c_wf_user_events_qc);
    dbms_output.put_line('Callback: ' || l_user_schema || '.ResourceManagement.user_events_callback');
    dbms_output.put_line('');
    dbms_output.put_line('NOTE: For timeout callbacks to run when messages become READY, set job_queue_processes > 0:');
    dbms_output.put_line('  ALTER SYSTEM SET job_queue_processes = 10 SCOPE = BOTH;  (requires DBA)');

exception
    when others then
        dbms_output.put_line('!! Failed to create/start User Events Queue: \n' ||sqlerrm);
end;
/

show err;
