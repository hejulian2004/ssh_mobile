import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const first = LanShareLocalIpv4Candidate(
    address: '192.168.1.20',
    interfaceName: 'Wi-Fi',
    interfaceIndex: 4,
  );
  const second = LanShareLocalIpv4Candidate(
    address: '10.0.0.8',
    interfaceName: 'Ethernet',
    interfaceIndex: 2,
  );

  group('LanShareSingleCandidateLocalAddressSelection', () {
    const selector = LanShareSingleCandidateLocalAddressSelection();

    test('selects the sole eligible candidate', () async {
      final result = await selector.selectPreferredIpv4([first]);

      expect(result, isA<LanShareLocalAddressSelected>());
      expect((result as LanShareLocalAddressSelected).candidate, first);
    });

    test('does not choose by input or sorted order when ambiguous', () async {
      final forward = await selector.selectPreferredIpv4([first, second]);
      final reversed = await selector.selectPreferredIpv4([second, first]);

      expect(forward, isA<LanShareLocalAddressAmbiguous>());
      expect(reversed, isA<LanShareLocalAddressAmbiguous>());
      expect(
        (forward as LanShareLocalAddressAmbiguous).candidates.map(
          (candidate) => candidate.address,
        ),
        ['10.0.0.8', '192.168.1.20'],
      );
      expect(
        (reversed as LanShareLocalAddressAmbiguous).candidates.map(
          (candidate) => candidate.address,
        ),
        ['10.0.0.8', '192.168.1.20'],
      );
    });

    test('reports unavailable when no eligible IPv4 exists', () async {
      final result = await selector.selectPreferredIpv4(const []);

      expect(result, isA<LanShareLocalAddressUnavailable>());
    });
  });

  group('LanShareLocalAddressResolver', () {
    test('explicit override wins when its address is still present', () async {
      final selector = _RecordingSelector(
        const LanShareLocalAddressSelected(first),
      );
      final resolver = LanShareLocalAddressResolver(
        candidateSource: _FakeCandidateSource([first, second]),
        selectionPort: selector,
      );

      final result = await resolver.resolve(override: second.address);

      expect(result, const LanShareLocalAddressSelected(second));
      expect(selector.calls, 0);
    });

    test('stale explicit override fails without automatic fallback', () async {
      final selector = _RecordingSelector(
        const LanShareLocalAddressSelected(first),
      );
      final resolver = LanShareLocalAddressResolver(
        candidateSource: _FakeCandidateSource([first]),
        selectionPort: selector,
      );

      final result = await resolver.resolve(override: '192.0.2.44');

      expect(result, isA<LanShareLocalAddressStaleOverride>());
      expect(selector.calls, 0);
    });

    test('candidate enumeration failure fails closed as unavailable', () async {
      final resolver = LanShareLocalAddressResolver(
        candidateSource: _FakeCandidateSource([], fail: true),
        selectionPort: _RecordingSelector(
          const LanShareLocalAddressSelected(first),
        ),
      );

      expect(await resolver.resolve(), isA<LanShareLocalAddressUnavailable>());
    });
  });
}

final class _FakeCandidateSource implements LanShareLocalIpv4CandidateSource {
  _FakeCandidateSource(this.candidates, {this.fail = false});

  final List<LanShareLocalIpv4Candidate> candidates;
  final bool fail;

  @override
  Future<List<LanShareLocalIpv4Candidate>> loadCandidates() async {
    if (fail) throw StateError('candidate source failed');
    return candidates;
  }
}

final class _RecordingSelector implements LanShareLocalAddressSelectionPort {
  _RecordingSelector(this.result);

  final LanShareLocalAddressSelectionResult result;
  int calls = 0;

  @override
  Future<LanShareLocalAddressSelectionResult> selectPreferredIpv4(
    List<LanShareLocalIpv4Candidate> candidates,
  ) async {
    calls++;
    return result;
  }
}
