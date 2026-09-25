///|
priv struct WritePermit {
  frame : Bytes
  alias_proposal : OutboundAliasProposal
  authorization : OutboundAuthorization
  close_reason : CloseReason?
}

///|
fn report_offer_not_started(
  bus : EventBus?,
  owner : OutboundAuthorization,
  publish : @protocol.PublishV5,
) -> Bool {
  let packet_id = match publish.packet_id {
    Some(value) => value
    None => return false
  }
  let delivery_id = match owner.delivery_id {
    Some(value) if value > 0L => value
    _ => return false
  }
  let receipt : WriteNotStartedEvent = {
    connection_id: owner.connection_id,
    client_id: owner.client_id,
    session_incarnation: owner.session_incarnation,
    packet_id,
    delivery_id,
    qos: publish.qos,
  }
  match bus {
    Some(value) => value.post_write_not_started(receipt)
    None => false
  }
}

///|
async fn write_delivery_offer(
  connection : ConnectionTransport,
  sink : TransportSink,
  bus : EventBus?,
  offer : DeliveryOffer,
  timeout_ms : Int,
) -> CloseReason? {
  defer release_optional(offer.ticket)
  if sink.ws_closing {
    return Some(PeerEof)
  }
  if !sink.authorize(offer.authorization) {
    return Some(PolicyRevoked)
  }
  let publish = match offer.packet {
    @protocol.Publish5(value) => value
    _ => return Some(WriteFailure)
  }
  if offer.expiry_deadline is Some(deadline) &&
    !publish.dup &&
    deadline.remaining_at(@budget.monotonic_ms()) == 0L {
    if !report_offer_not_started(bus, offer.authorization, publish) {
      return Some(WriteFailure)
    }
    return offer.close_reason
  }
  let encode_mono_ms = @budget.monotonic_ms()
  let packet = match offer.expiry_deadline {
    Some(deadline) =>
      mqtt5_refresh_expiry_packet(offer.packet, deadline, encode_mono_ms)
    None => offer.packet
  }
  let updated = match packet {
    @protocol.Publish5(value) => value
    _ => return Some(WriteFailure)
  }
  let mut outgoing = packet
  let mut proposal = sink.propose_outbound_alias(
    updated.topic,
    offer.alias_limit,
    offer.alias_bytes,
  )
  match proposal {
    AliasDefine(id, _) | AliasReuse(id) => {
      let properties = updated.properties.copy()
      properties.push({ id: 0x23, value: @protocol.TwoByteValue(id) })
      outgoing = @protocol.Publish5({
        ..updated,
        topic: if proposal is AliasReuse(_) {
          ""
        } else {
          updated.topic
        },
        properties,
      })
    }
    AliasNone => ()
  }
  let initial = @protocol.encode_v5(
    outgoing,
    @protocol.ServerToClient,
    offer.peer_limit,
  )
  let encoded = match initial {
    Err(_) if proposal is AliasDefine(_, _) => {
      sink.outbound_alias_cancel(proposal)
      proposal = AliasNone
      outgoing = packet
      @protocol.encode_v5(packet, @protocol.ServerToClient, offer.peer_limit)
    }
    value => value
  }
  let mut frame = match encoded {
    Ok(value) => value
    Err(@protocol.WireLimitExceeded(_)) => {
      sink.outbound_alias_cancel(proposal)
      if !publish.dup {
        if !report_offer_not_started(bus, offer.authorization, publish) {
          return Some(WriteFailure)
        }
        return offer.close_reason
      }
      let disconnect = @protocol.encode_v5(
        @protocol.Disconnect5({ reason: 0x95, properties: [] }),
        @protocol.ServerToClient,
        offer.peer_limit,
      )
      if disconnect is Ok(value) {
        ignore(
          @async.with_timeout_opt(timeout_ms, () => connection.write(value)),
        ) catch {
          _ => ()
        }
      }
      return Some(PacketTooLarge)
    }
    Err(_) => {
      sink.outbound_alias_cancel(proposal)
      return Some(EncodeFailure)
    }
  }
  if offer.expiry_deadline is Some(deadline) {
    let write_mono_ms = @budget.monotonic_ms()
    if !publish.dup && deadline.remaining_at(write_mono_ms) == 0L {
      sink.outbound_alias_cancel(proposal)
      if !report_offer_not_started(bus, offer.authorization, publish) {
        return Some(WriteFailure)
      }
      return offer.close_reason
    }
    if mqtt5_remaining_expiry_seconds(deadline, write_mono_ms) !=
      mqtt5_remaining_expiry_seconds(deadline, encode_mono_ms) {
      let refreshed = mqtt5_refresh_expiry_packet(
        outgoing, deadline, write_mono_ms,
      )
      frame = match
        @protocol.encode_v5(
          refreshed,
          @protocol.ServerToClient,
          offer.peer_limit,
        ) {
        Ok(value) => value
        Err(_) => {
          sink.outbound_alias_cancel(proposal)
          return Some(EncodeFailure)
        }
      }
    }
  }
  let permit : WritePermit = {
    frame,
    alias_proposal: proposal,
    authorization: offer.authorization,
    close_reason: offer.close_reason,
  }
  let owner : OutboundAuthorization? = Some(permit.authorization)
  let gate : (() -> Bool)? = owner.map(value => () => sink.authorize(value))
  let written = @async.with_timeout_opt(timeout_ms, () => {
    connection.write(permit.frame, still_allowed?=gate)
  }) catch {
    PolicyWriteRevoked => {
      sink.outbound_alias_cancel(proposal)
      return Some(PolicyRevoked)
    }
    _ => {
      sink.outbound_alias_cancel(proposal)
      return Some(WriteFailure)
    }
  }
  if written is None {
    sink.outbound_alias_cancel(proposal)
    return Some(WriteFailure)
  }
  sink.outbound_alias_written(permit.alias_proposal)
  if bus is Some(value) && value.needs_promotion {
    value.post_tick(CheckDeadlines(@async.now()))
  }
  permit.close_reason
}
