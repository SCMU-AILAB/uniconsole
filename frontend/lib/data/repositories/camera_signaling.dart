/// Camera signaling uses the authenticated robot connection, never a second WS.
abstract interface class CameraSignaling {
  bool get connected;
  Stream<bool> watchConnection();
  Future<List<Map<String, dynamic>>> cameraIceServers();
  Stream<Map<String, dynamic>> cameraSignals(String deviceId, String sessionId);
  void cameraOffer(String deviceId, String sessionId, String sdp);
  void cameraIce(
    String deviceId,
    String sessionId,
    Map<String, dynamic> candidate,
  );
  void cameraClose(String deviceId, String sessionId);
}
