/// The chat routes currently on the navigator, topmost last.
///
/// Claim and release stay synchronous. A chat route calls them while Flutter
/// is building or disposing that route, so this list does not notify listeners.
final class LanVisibleChat {
  final List<String> _peers = <String>[];

  String? get peerId => _peers.isEmpty ? null : _peers.last;

  void claim(String peerId) {
    if (peerId.isEmpty) return;
    _peers.add(peerId);
  }

  void release(String peerId) {
    final index = _peers.lastIndexOf(peerId);
    if (index < 0) return;
    _peers.removeAt(index);
  }
}
