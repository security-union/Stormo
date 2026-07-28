/// Stromo presents one unified namespace: the sans-I/O protocol layer
/// (DD-6: `ProtocolEngine`, `Signal`, `PeerID`, `Delivery`, `Recipients`,
/// `StromoError`, `SignalCodec`) is re-exported so app code only ever
/// writes `import Stromo`.
@_exported import StromoProtocol
