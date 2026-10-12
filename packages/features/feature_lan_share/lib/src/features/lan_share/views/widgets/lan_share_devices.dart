part of '../lan_share_screen.dart';

extension _LanShareDevices on _LanShareScreenState {
  Widget _buildRadarView(
    BuildContext context,
    LanShareStrings strings,
    LanShareViewModel vm,
  ) {
    final peers = vm.peerStates;
    if (peers.isEmpty) {
      if (vm.isScanning) {
        return AppEmptyState(
          icon: Icons.radar_rounded,
          title: strings.lanShareNoDevices,
          message: strings.lanShareRadarHint,
        );
      } else if (vm.lastScanError != null) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.wifi_off_rounded,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    strings.lanShareNoDevices,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2.0),
                        child: Icon(
                          Icons.error_rounded,
                          color: Colors.red,
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          strings.lanShareNoDevicesRefreshHint,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.red, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => vm.startScanning(),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(strings.isEnglish ? 'Rescan' : '重新搜索'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      } else {
        return AppEmptyState(
          icon: Icons.radar_rounded,
          title: strings.lanShareNoDevices,
          message: strings.lanShareRadarStoppedHint,
        );
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: peers.length,
      itemBuilder: (context, index) {
        final state = peers[index];
        final device = state.discovery;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: LanPeerDeviceCard(
            key: ValueKey(state.peerId),
            peer: state,
            strings: strings,
            isConnecting: vm.isPairingConnecting(state.peerId),
            onCancel: () => vm.cancelPairingConnection(state.peerId),
            onUnpair: state.isTrusted
                ? () async {
                    if (!await confirmLanPeerUnpair(context, state, strings) ||
                        !context.mounted) {
                      return;
                    }
                    final result = await vm.forgetDevice(state.peerId);
                    if (result is NetworkFailure<void> && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(strings.lanDeviceUnpairFailed)),
                      );
                    }
                  }
                : null,
            onTap: () async {
              if (state.isTrusted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LanShareFeatureScope(
                      child: LanChatScreen(
                        targetDeviceId: state.peerId,
                        initialAlias: state.displayAlias,
                      ),
                    ),
                  ),
                );
              } else if (device != null) {
                await _requestPairingWithFeedback(context, vm, device, strings);
              }
            },
          ),
        );
      },
    );
  }
}
