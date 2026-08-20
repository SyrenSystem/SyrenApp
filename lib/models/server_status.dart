class ServerStatus {
  final String sessionId;
  final String stateId;
  final bool online;
  final Set<String> connectedSpeakerIds;

  const ServerStatus({
    required this.sessionId,
    required this.stateId,
    required this.online,
    required this.connectedSpeakerIds,
  });
}
