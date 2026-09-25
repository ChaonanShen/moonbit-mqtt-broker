///|
pub(all) enum OutboundAliasProposal {
  AliasNone
  AliasDefine(Int, String)
  AliasReuse(Int)
} derive(Eq, Debug)

///|
fn TransportSink::propose_outbound_alias(
  self : TransportSink,
  topic : String,
  maximum : Int,
  max_bytes : Int,
) -> OutboundAliasProposal {
  if maximum < 1 || max_bytes < 1 {
    return AliasNone
  }
  if self.outbound_aliases.get(topic) is Some(id) {
    return AliasReuse(id)
  }
  for _, pending in self.pending_outbound_aliases {
    if pending == topic {
      return AliasNone
    }
  }
  if self.next_outbound_alias > maximum || self.next_outbound_alias > 65535 {
    return AliasNone
  }
  let bytes = 64 + @utf8.encode(topic).length()
  let mut pending_bytes = 0
  for _, value in self.pending_outbound_aliases {
    pending_bytes += 64 + @utf8.encode(value).length()
  }
  if bytes > max_bytes - self.outbound_alias_bytes - pending_bytes {
    return AliasNone
  }
  let id = self.next_outbound_alias
  self.next_outbound_alias += 1
  self.pending_outbound_aliases.set(id, topic)
  AliasDefine(id, topic)
}

///|
fn TransportSink::outbound_alias_written(
  self : TransportSink,
  proposal : OutboundAliasProposal,
) -> Unit {
  match proposal {
    AliasDefine(id, topic) =>
      if self.pending_outbound_aliases.get(id) == Some(topic) {
        self.pending_outbound_aliases.remove(id)
        self.outbound_aliases.set(topic, id)
        self.outbound_alias_bytes += 64 + @utf8.encode(topic).length()
      }
    _ => ()
  }
}

///|
fn TransportSink::outbound_alias_cancel(
  self : TransportSink,
  proposal : OutboundAliasProposal,
) -> Unit {
  if proposal is AliasDefine(id, _) {
    self.pending_outbound_aliases.remove(id)
  }
}
