/// PeerMesh presents one unified namespace: the sans-I/O protocol layer
/// (DD-6: `ProtocolEngine`, `Signal`, `PeerID`, `Delivery`, `Recipients`,
/// `PeerMeshError`, `SignalCodec`) is re-exported so app code only ever
/// writes `import PeerMesh`.
@_exported import PeerMeshProtocol
