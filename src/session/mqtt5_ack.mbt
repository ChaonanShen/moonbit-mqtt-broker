///|
pub(all) enum V5OutboundAckKind {
  V5Puback
  V5Pubrec
  V5Pubcomp
} derive(Eq, Debug)

///|
pub(all) enum V5AckTransition {
  V5UnknownPacketId
  V5Terminal
  V5SendPubrel
} derive(Eq, Debug)

///|
pub fn ClientSession::apply_v5_outbound_ack(
  self : ClientSession,
  packet_id : SessionPacketId,
  kind : V5OutboundAckKind,
  negative : Bool,
) -> Result[V5AckTransition, SessionError] {
  let mut found : OutboundInflight? = None
  for value in self.inflight {
    if value.packet_id == packet_id {
      found = Some(value)
    }
  }
  let item = match found {
    Some(value) => value
    None => return Ok(V5UnknownPacketId)
  }
  let expected = match kind {
    V5Puback => AwaitPuback
    V5Pubrec => AwaitPubrec
    V5Pubcomp => AwaitPubcomp
  }
  if item.phase != expected {
    return Err(InvalidAcknowledgement)
  }
  if kind == V5Pubrec && !negative {
    ignore(self.pubrec(packet_id).unwrap())
    return Ok(V5SendPubrel)
  }
  self.inflight = self.inflight.filter(value => value.packet_id != packet_id)
  self.inflight_cost -= item.cost()
  self.bump_policy_revision()
  Ok(V5Terminal)
}
