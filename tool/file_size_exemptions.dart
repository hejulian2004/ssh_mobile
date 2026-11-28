/// Time-boxed exceptions for pre-existing responsibility-sized production
/// files. Each entry has an owner, a reason, a review date, and an expiry;
/// newly oversized files are never implicitly added to this list.
final class FileSizeExemption {
  const FileSizeExemption({
    required this.owner,
    required this.reason,
    required this.reviewedOn,
    required this.expiresOn,
  });

  final String owner;
  final String reason;
  final String reviewedOn;
  final String expiresOn;
}

const fileSizeExemptions = <String, FileSizeExemption>{
  'apps/ssh_mobile_full/lib/app/sftp_feature_adapters.dart': FileSizeExemption(
    owner: 'module-maintainer',
    reason: 'Existing adapter boundary; decompose by feature ownership.',
    reviewedOn: '2026-09-02',
    expiresOn: '2027-03-31',
  ),
  'apps/ssh_mobile_full/lib/app/system_admin_feature_adapters.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing adapter boundary; decompose by feature ownership.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'apps/ssh_mobile_full/lib/app/terminal_feature_adapters.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing adapter boundary; decompose by feature ownership.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'apps/ssh_mobile_full/lib/features/home/views/home_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing screen composition; decompose by UI responsibility.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'apps/ssh_mobile_full/lib/features/home/views/widgets/server_connection_widgets.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing server widget group; decompose by presentation role.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'apps/ssh_mobile_full/lib/features/home/views/widgets/server_list_pane.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing server list pane; decompose by list responsibility.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'apps/ssh_mobile_full/lib/services/ai_storage/ai_settings_ops.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing storage operations; decompose by persistence concern.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'apps/ssh_mobile_full/lib/services/ai_storage_adapter.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing app-to-feature adapter; decompose by port ownership.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'apps/ssh_mobile_full/lib/services/app_settings.dart': FileSizeExemption(
    owner: 'module-maintainer',
    reason: 'Existing settings owner; decompose by settings domain.',
    reviewedOn: '2026-09-02',
    expiresOn: '2027-03-31',
  ),
  'apps/ssh_mobile_full/lib/services/app_strings.dart': FileSizeExemption(
    owner: 'module-maintainer',
    reason: 'Existing localization catalog; split by feature when edited.',
    reviewedOn: '2026-09-02',
    expiresOn: '2027-03-31',
  ),
  'apps/ssh_mobile_full/lib/services/background_service.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing lifecycle owner; decompose by background capability.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'apps/ssh_mobile_full/lib/services/client_system_tool_service.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing client tool owner; decompose by capability group.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/core/app_core/lib/src/telemetry/telemetry_client_upload.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing telemetry transport; decompose by upload concern.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/core/app_ui/lib/src/theme/app_theme_components.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing theme component catalog; split by component family.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/core/app_ui/lib/src/widgets/app_server_selector.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing shared selector; decompose pane/strip components.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/agent/multi_agent_coordinator.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing agent coordinator; split orchestration policies.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/pages/agent_trace_debug_page.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing diagnostics page; split trace sections by responsibility.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/services/llm_chat/llm_chat_types.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing provider type catalog; split by protocol family.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/services/llm_chat/llm_stream_handler.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing stream lifecycle; split transport and tool-loop roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/services/llm_chat/tool_loop_controller.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing tool-loop owner; split policy and state transitions.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/services/llm_chat/tool_loop_helpers.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing tool-loop helpers; split by validation concern.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/viewmodels/ai_chat_viewmodel_message_actions.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing chat mutation owner; split send/edit/regenerate flows.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/views/llm_chat_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing chat shell; split page sections by UI responsibility.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/views/widgets/ai_strings.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing AI localization catalog; split by screen when edited.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/views/widgets/chat_composer.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing composer; split input, attachment, and action regions.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/views/widgets/chat_slash_commands.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing slash command catalog; split command families.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/views/widgets/llm_settings_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing settings screen; split sections by provider concern.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/views/widgets/llm_settings_widgets.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing settings widgets; split reusable control families.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/views/widgets/message_todo_panel.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing TODO panel; split rendering and action sections.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/chat/views/widgets/prompt_customizer_dialog.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing prompt editor; split form and validation sections.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/domain/ai_ports.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing AI port catalog; split ports by lifecycle domain.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/llm/provider/anthropic_messages_provider.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing provider adapter; split encoding and streaming concerns.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/llm/provider/openai_chat_provider.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing provider adapter; split request and response concerns.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/llm/provider/openai_responses_provider.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing provider adapter; split response event handling.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/tools/ai_tool_approval.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing approval state owner; split validation and presentation.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/tools/ai_tool_service.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing tool registry; split capability families.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/tools/ai_tool_types.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing tool type catalog; split by execution domain.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/tools/security_policy.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing AI security policy; split policy families.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/tools/server_tools.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing server tool catalog; split read/write tool groups.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_ai/lib/src/tools/tools/client_tools_schemas.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing client schema catalog; split by capability family.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/features/lan_share/services/lan_relay_coordinator.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing relay coordinator; split lifecycle and transport roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/features/lan_share/viewmodels/lan_share_viewmodel.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing LAN state owner; split transfer and session state.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/features/lan_share/views/lan_chat_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing LAN chat shell; split message and transfer regions.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/features/lan_share/views/lan_pairing_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing pairing screen; split enrollment and verification UI.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/features/lan_share/views/lan_preview_viewer_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing preview viewer; split media and transfer states.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/features/lan_share/views/lan_share_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing LAN share shell; split navigation and content regions.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/features/lan_share/views/lan_share_settings_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing LAN settings; split security and transfer sections.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/features/lan_share/views/widgets/lan_share_dialogs.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing LAN dialog catalog; split dialog responsibilities.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/services/lan_share/lan_discovery_service.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing discovery service; split protocol and lifecycle concerns.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/services/lan_share/lan_native_transfer_coordinator.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing native transfer coordinator; split chunk and retry roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/services/lan_share/lan_pairing_crypto.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing pairing crypto service; split protocol stages.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/services/lan_share/lan_security_service.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing LAN security owner; split validation and policy roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/services/lan_share/lan_share_models.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing LAN model catalog; split by protocol aggregate.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/services/lan_share/lan_transfer_client.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing transfer client; split transport and persistence roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/services/lan_share/lan_transfer_service.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing transfer service; split state machine and IO roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/services/lan_share/lan_web_share_request_handler.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing web-share handler; split request and validation roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/lib/src/services/lan_share/lan_web_share_server.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing web-share server; split routing and response roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_lan_share/tool/lan_web_share_tls_process.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing TLS helper; split process and certificate lifecycle.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_mcp/lib/src/application/mcp_server_controller.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing MCP server controller; split lifecycle and routing.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_mcp/lib/src/features/mcp_console/views/mcp_console_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing MCP console; split server and message sections.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_monitoring/lib/src/application/monitoring_service.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing monitoring service; split collection and alert roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_monitoring/lib/src/domain/server_status_probe.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing status probe; split protocol and result normalization.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_playbook/lib/src/application/playbook_service.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing playbook service; split persistence and execution roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_playbook/lib/src/features/playbook/views/widgets/execution_dashboard.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing execution dashboard; split summary and task views.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_sftp/lib/src/presentation/sftp_entry_list.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing SFTP entry list; split row and loading states.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_sftp/lib/src/presentation/sftp_file_viewer_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing SFTP viewer; split loading, editing, and preview roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_sftp/lib/src/presentation/widgets/sftp_file_preview_renderers.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing preview renderer catalog; split MIME families.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_system_admin/lib/src/presentation/viewmodels/system_admin_viewmodel.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing admin state owner; split tab and connection state.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_system_admin/lib/src/presentation/views/details_views.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing admin detail views; split by resource section.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_system_admin/lib/src/presentation/views/monitor_config.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing monitor configuration; split forms and validation.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_system_admin/lib/src/presentation/views/services_tab.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing services tab; split list and action sections.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_system_admin/lib/src/presentation/views/system_admin_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing admin shell; split navigation and content regions.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_system_admin/lib/src/presentation/views/system_admin_server_pane.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing admin server pane; split selector and tile bindings.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_system_admin/lib/src/presentation/views/users_tab.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing users tab; split table and form sections.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_terminal/lib/src/application/terminal_session_viewmodel.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing terminal session owner; split lifecycle and input state.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_terminal/lib/src/domain/terminal_keyboard_models.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing keyboard model catalog; split layout and command models.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_terminal/lib/src/presentation/terminal_copy_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing copy screen; split selection and export states.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_terminal/lib/src/presentation/terminal_history_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing terminal history; split list and search states.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_terminal/lib/src/presentation/terminal_screen.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing terminal shell; split toolbar and workspace regions.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_terminal/lib/src/presentation/terminal_shortcut_panel.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing shortcut panel; split layout and command sections.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_terminal/lib/src/presentation/terminal_view_area.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing terminal view area; split renderer and overlay roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_terminal/lib/src/presentation/widgets/terminal_custom_keyboard.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing custom keyboard; split rows and key actions.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_terminal/lib/src/presentation/widgets/terminal_windows_content.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing Windows terminal content; split panes and controls.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/features/feature_webview/lib/src/services/client_webview_service.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing WebView lifecycle owner; split navigation and session roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/infrastructure/network_sdk/lib/src/network_http_clients.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing HTTP client catalog; split transport and policy roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'packages/infrastructure/network_sdk/lib/src/network_v2.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing protocol facade; split envelope and stream roles.',
        reviewedOn: '2026-09-02',
        expiresOn: '2027-03-31',
      ),
  'tool/check_agent_docs.dart': FileSizeExemption(
    owner: 'module-maintainer',
    reason: 'Existing governance checker; split rule families in a follow-up.',
    reviewedOn: '2026-09-02',
    expiresOn: '2027-03-31',
  ),
  'apps/ssh_mobile_full/lib/app/screen_share_media_coordinator.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason:
            'Existing operation coordinator; split capture and readiness roles.',
        reviewedOn: '2026-11-26',
        expiresOn: '2027-03-31',
      ),
  'packages/infrastructure/ssh_mobile_network_native/lib/src/native_protocol_command_encoder.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing native command encoder; split by command family.',
        reviewedOn: '2026-11-26',
        expiresOn: '2027-03-31',
      ),
  'packages/infrastructure/ssh_mobile_network_native/lib/src/native_realtime_event_decoder.dart':
      FileSizeExemption(
        owner: 'module-maintainer',
        reason: 'Existing realtime event decoder; split by event family.',
        reviewedOn: '2026-11-26',
        expiresOn: '2027-03-31',
      ),
};
