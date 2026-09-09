/// Ephemeral TURN credential contracts.
///
/// The SDK keeps only the typed in-memory value and never creates an HTTP
/// client, secure-storage record, timer or native WebRTC object. App Shell
/// supplies [TurnCredentialProvider] and decides when direct ICE needs relay.

library;

export 'turn_credential_models.dart';
export 'turn_credential_provider.dart';
export 'turn_credential_store.dart';
