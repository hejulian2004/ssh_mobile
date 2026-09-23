// LAN Share Feature 的稳定公共入口。
//
// App Shell 只应依赖本文件导出的 Module、Port、Coordinator 和路由组件，
// 不跨 Package 引用 `src/`；Feature 内部服务仍保持私有实现边界。

export 'src/application/lan_share_module.dart';
export 'src/data/database/lan_share_database.dart';
export 'src/data/repositories/lan_share_history_repository.dart';
export 'src/domain/lan_share_ports.dart';
export 'src/features/lan_share/lan_share_feature_scope.dart';
export 'src/features/lan_share/services/lan_relay_coordinator.dart'
    show LanRelayStatus;
export 'src/features/lan_share/services/lan_receiver_coordinator.dart';
export 'src/features/lan_share/services/lan_native_peer_registry.dart';
export 'src/features/lan_share/viewmodels/lan_relay_settings_viewmodel.dart';
export 'src/features/lan_share/viewmodels/lan_share_viewmodel.dart';
export 'src/features/lan_share/views/lan_chat_screen.dart';
export 'src/features/lan_share/views/lan_pairing_navigation_host.dart';
export 'src/features/lan_share/views/lan_pairing_screen.dart';
export 'src/features/lan_share/views/lan_preview_viewer_screen.dart';
export 'src/features/lan_share/views/lan_qr_scanner_screen.dart';
export 'src/features/lan_share/views/lan_share_screen.dart';
export 'src/features/lan_share/views/lan_share_settings_screen.dart';
export 'src/features/lan_share/views/lan_text_selection_screen.dart';
export 'src/features/lan_share/views/network_incoming_transfer_host.dart';
export 'src/features/lan_share/utils/lan_platform_capabilities.dart';
export 'src/features/lan_share/utils/lan_preview_safety.dart';
export 'src/features/lan_share/utils/lan_text_action_helper.dart';
export 'src/services/lan_share/lan_network_models.dart';
export 'src/services/lan_share/lan_local_address_selection.dart';
export 'src/services/lan_share/lan_web_share_url.dart';
export 'src/services/lan_share/lan_peer_trust.dart';
export 'src/services/lan_share/lan_pairing_crypto.dart';
export 'src/services/lan_share/lan_multicast_lock.dart';
export 'src/services/lan_share/lan_discovery_service.dart';
export 'src/services/lan_share/lan_security_service.dart';
export 'src/services/lan_share/lan_share_models.dart';
export 'src/services/lan_share/lan_storage_service.dart';
export 'src/services/lan_share/lan_native_transfer_coordinator.dart';
export 'src/services/lan_share/lan_transfer_protocol.dart';
export 'src/services/lan_share/lan_transfer_service.dart';
export 'src/services/relay/relay_enrollment_service.dart';
