///|
/// Reject packets that are not legal in the specified network direction.
pub fn validate_direction(
  packet : Packet,
  direction : PacketDirection,
) -> Result[Unit, CodecError] {
  let allowed = match (packet, direction) {
    (Connect(_), ClientToServer) => true
    (Connack(_), ServerToClient) => true
    (Publish(_), _) => true
    (Puback(_), _) => true
    (Subscribe(_), ClientToServer) => true
    (Suback(_), ServerToClient) => true
    (Unsubscribe(_), ClientToServer) => true
    (Unsuback(_), ServerToClient) => true
    (Pingreq, ClientToServer) => true
    (Pingresp, ServerToClient) => true
    (Disconnect, ClientToServer) => true
    _ => false
  }
  if allowed {
    Ok(())
  } else {
    Err(InvalidDirection("packet is not valid in this direction"))
  }
}
