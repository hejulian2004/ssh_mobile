import '../viewmodels/lan_share_viewmodel.dart';
import '../../../services/lan_share/lan_share_models.dart';

/// History and alias a notification click may use. Both are already loaded.
final class LanNotificationClickContext {
  const LanNotificationClickContext({
    required this.history,
    required this.alias,
  });

  final List<LanMessage> history;
  final String alias;
}

/// Reads the click context from the current view model without message text.
LanNotificationClickContext readLanNotificationClickContext(
  LanShareViewModel? viewModel,
  String peerId,
) {
  if (viewModel == null) {
    return const LanNotificationClickContext(
      history: <LanMessage>[],
      alias: '',
    );
  }
  return LanNotificationClickContext(
    history: viewModel.history,
    alias: viewModel.peerStateFor(peerId)?.displayAlias ?? '',
  );
}
