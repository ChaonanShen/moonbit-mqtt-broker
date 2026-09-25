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
  let mut selected = self.next_outbound_alias
  for free in self.free_outbound_aliases {
    if free < selected {
      selected = free
    }
  }
  if selected > maximum || selected > 65535 {
    return AliasNone
  }
  let bytes = 64 + @utf8.encode(topic).length()
  let mut pending_bytes = 0
  for _, value in self.pending_outbound_aliases {
    pending_bytes += 64 + @utf8.encode(value).length()
  }
  let mut inbound_bytes = 0
  if self.shared_inbound_aliases is Some(all) &&
    self.alias_connection_id is Some(connection_id) &&
    all.get(connection_id) is Some(table) {
    for _, value in table {
      inbound_bytes += 64 + @utf8.encode(value).length()
    }
  }
  if bytes >
    max_bytes - inbound_bytes - self.outbound_alias_bytes - pending_bytes {
    return AliasNone
  }
  if selected == self.next_outbound_alias {
    self.next_outbound_alias += 1
  } else {
    for index in 0..<self.free_outbound_aliases.length() {
      if self.free_outbound_aliases[index] == selected {
        ignore(self.free_outbound_aliases.remove(index))
        break
      }
    }
  }
  self.pending_outbound_aliases.set(selected, topic)
  AliasDefine(selected, topic)
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
        if self.shared_outbound_alias_bytes is Some(usage) &&
          self.alias_connection_id is Some(connection_id) {
          usage.set(connection_id, self.outbound_alias_bytes)
        }
      }
    _ => ()
  }
}

///|
fn TransportSink::outbound_alias_cancel(
  self : TransportSink,
  proposal : OutboundAliasProposal,
) -> Unit {
  if proposal is AliasDefine(id, topic) &&
    self.pending_outbound_aliases.get(id) == Some(topic) {
    self.pending_outbound_aliases.remove(id)
    self.free_outbound_aliases.push(id)
  }
}
