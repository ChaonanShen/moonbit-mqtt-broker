///|
fn checkpoint_error(error : Error) -> PersistenceError {
  match error {
    InvalidConfiguration(message) => InvalidConfiguration(message)
    SnapshotTooLarge(actual~, limit~) => SnapshotTooLarge(actual~, limit~)
    LimitExceeded(resource~, actual~, limit~) =>
      LimitExceeded(resource~, actual~, limit~)
    InvalidValue(field~, offset~) => InvalidValue(field~, offset~)
    FileSystem(operation~, path~) => FileSystem(operation~, path~)
    DurabilityUncertain(path) => DurabilityUncertain(path)
    _ => FileSystem(operation="wal-checkpoint-encode", path="checkpoint")
  }
}

///|
async fn checkpoint_yield(preempt : () -> Bool) -> Unit raise PersistenceError {
  if preempt() {
    raise FileSystem(operation="wal-checkpoint-preempted", path="checkpoint")
  }
  @async.sleep(1) catch {
    _ => raise FileSystem(operation="wal-checkpoint-yield", path="checkpoint")
  }
}

///|
async fn BinaryWriter::write_raw_sliced(
  self : BinaryWriter,
  value : BytesView,
  preempt : () -> Bool,
) -> Unit raise PersistenceError {
  self.require_capacity(value.length())
  let mut copied = 0
  for byte in value {
    self.bytes.push(byte)
    copied += 1
    if copied % 1048576 == 0 {
      checkpoint_yield(preempt)
    }
  }
}

///|
async fn BinaryWriter::write_bytes_sliced(
  self : BinaryWriter,
  value : Bytes,
  preempt : () -> Bool,
) -> Unit raise PersistenceError {
  self.write_u32(value.length(), "bytes-length")
  self.write_raw_sliced(value, preempt)
}

///|
async fn crc32_sliced(data : BytesView, preempt : () -> Bool) -> UInt {
  let mut crc = 0xffffffffU
  let mut processed = 0
  for byte in data {
    let index = ((crc ^ byte.to_uint()) & 0xffU).reinterpret_as_int()
    crc = crc32_table[index] ^ (crc >> 8)
    processed += 1
    if processed % 1048576 == 0 {
      checkpoint_yield(preempt)
    }
  }
  crc ^ 0xffffffffU
}

///|
async fn encode_wal_message_sliced(
  writer : BinaryWriter,
  message : @router.SnapshotMessageV3,
  preempt : () -> Bool,
) -> Unit raise PersistenceError {
  if message.qos < 1 || message.qos > 2 {
    raise InvalidValue(field="message-qos", offset=writer.bytes.length())
  }
  writer.write_string(message.topic)
  writer.write_bytes_sliced(message.payload, preempt)
  writer.write_u8(if message.retain { 1 } else { 0 }, "message-retain")
  writer.write_u8(message.qos, "message-qos")
}

///|
async fn encode_snapshot_sliced(
  snapshot : @router.BrokerSnapshotV3,
  max_snapshot_bytes : Int,
  preempt : () -> Bool,
) -> Result[Bytes, PersistenceError] {
  try {
    if snapshot.version != 3 || max_snapshot_bytes < 24 {
      raise InvalidConfiguration("WAL checkpoint requires Disk V3")
    }
    let payload = BinaryWriter::new(max_bytes=max_snapshot_bytes - 24)
    payload.write_u32(3, "snapshot-model-version")
    payload.write_u32(snapshot.sessions.length(), "session-count")
    let mut items = 0
    for session in snapshot.sessions {
      payload.write_string(session.client_id)
      payload.write_string(session.owner_principal)
      if session.detached_at_ms < 0L {
        raise InvalidValue(
          field="detached-at-ms",
          offset=payload.bytes.length(),
        )
      }
      payload.write_string(session.detached_at_ms.to_string())
      if session.next_packet_id < 1 || session.next_packet_id > 65535 {
        raise InvalidValue(
          field="next-packet-id",
          offset=payload.bytes.length(),
        )
      }
      payload.write_u16(session.next_packet_id, "next-packet-id")
      payload.write_u32(session.subscriptions.length(), "subscription-count")
      for subscription in session.subscriptions {
        payload.write_string(subscription.filter)
        if subscription.qos < 0 || subscription.qos > 2 {
          raise InvalidValue(
            field="subscription-qos",
            offset=payload.bytes.length(),
          )
        }
        payload.write_u8(subscription.qos, "subscription-qos")
        items += 1
        if items % 16 == 0 {
          checkpoint_yield(preempt)
        }
      }
      payload.write_u32(session.inbound_qos2.length(), "inbound-qos2-count")
      for id in session.inbound_qos2 {
        if id < 1 || id > 65535 {
          raise InvalidValue(
            field="inbound-packet-id",
            offset=payload.bytes.length(),
          )
        }
        payload.write_u16(id, "inbound-packet-id")
        items += 1
        if items % 16 == 0 {
          checkpoint_yield(preempt)
        }
      }
      payload.write_u32(session.inflight.length(), "inflight-count")
      for item in session.inflight {
        if item.packet_id < 1 || item.packet_id > 65535 {
          raise InvalidValue(field="packet-id", offset=payload.bytes.length())
        }
        payload.write_u16(item.packet_id, "packet-id")
        if item.phase < 1 || item.phase > 3 {
          raise InvalidValue(
            field="outbound-phase",
            offset=payload.bytes.length(),
          )
        }
        payload.write_u8(item.phase, "outbound-phase")
        match item.message {
          Some(message) => {
            if item.phase == 3 || message.qos != item.phase {
              raise InvalidValue(
                field="phase-message",
                offset=payload.bytes.length(),
              )
            }
            encode_wal_message_sliced(payload, message, preempt)
          }
          None =>
            if item.phase != 3 {
              raise InvalidValue(
                field="missing-message",
                offset=payload.bytes.length(),
              )
            }
        }
        items += 1
        if items % 16 == 0 {
          checkpoint_yield(preempt)
        }
      }
      payload.write_u32(session.pending.length(), "pending-count")
      for message in session.pending {
        encode_wal_message_sliced(payload, message, preempt)
        items += 1
        if items % 16 == 0 {
          checkpoint_yield(preempt)
        }
      }
    }
    payload.write_u32(snapshot.retained.length(), "retained-count")
    for retained in snapshot.retained {
      payload.write_string(retained.topic)
      payload.write_bytes_sliced(retained.payload, preempt)
      if retained.qos < 0 || retained.qos > 2 {
        raise InvalidValue(field="retained-qos", offset=payload.bytes.length())
      }
      payload.write_u8(retained.qos, "retained-qos")
      items += 1
      if items % 16 == 0 {
        checkpoint_yield(preempt)
      }
    }
    let encoded_payload = payload.finish()
    let checksum = crc32_sliced(encoded_payload, preempt)
    let writer = BinaryWriter::new(max_bytes=max_snapshot_bytes)
    writer.write_raw(disk_magic)
    writer.write_u16(3, "envelope-version")
    writer.write_u16(0, "flags")
    writer.write_u64_length(encoded_payload.length())
    writer.write_u32_bits(checksum)
    writer.write_raw_sliced(encoded_payload, preempt)
    Ok(writer.finish())
  } catch {
    error => Err(checkpoint_error(error))
  }
}

///|
pub async fn encode_wal_checkpoint_sliced(
  checkpoint : WalCheckpoint,
  max_checkpoint_bytes? : Int = 134217728,
  max_snapshot_bytes? : Int = 67108864,
  preempt? : () -> Bool = () => false,
) -> Result[Bytes, PersistenceError] {
  try {
    validate_wal_checkpoint(checkpoint)
    let snapshot = match
      encode_snapshot_sliced(checkpoint.snapshot, max_snapshot_bytes, preempt) {
      Ok(value) => value
      Err(error) => raise error
    }
    let writer = BinaryWriter::new(max_bytes=max_checkpoint_bytes)
    writer.write_raw(wal_checkpoint_magic)
    writer.write_u16(
      if checkpoint.policy is Some(_) {
        2
      } else {
        1
      },
      "wal-checkpoint-version",
    )
    writer.write_u16(
      if checkpoint.policy is Some(_) {
        4
      } else {
        3
      },
      "wal-logical-schema",
    )
    writer.write_positive_i64(
      checkpoint.generation,
      "wal-checkpoint-generation",
    )
    writer.write_positive_i64(checkpoint.lsn, "wal-checkpoint-lsn")
    writer.write_u32(checkpoint.identities.length(), "wal-identity-count")
    for identity in checkpoint.identities {
      writer.write_string(identity.client_id)
      writer.write_positive_i64(identity.generation, "wal-session-generation")
    }
    if checkpoint.policy is Some(policy) {
      writer.write_positive_i64(policy.sequence, "wal-policy-sequence")
      writer.write_raw(policy.fingerprint)
      writer.write_u8(
        if policy.reconcile_pending {
          1
        } else {
          0
        },
        "wal-policy-pending",
      )
    }
    writer.write_bytes_sliced(snapshot, preempt)
    let prefix = writer.finish()
    let checksum = crc32_sliced(prefix, preempt)
    writer.write_u32_bits(checksum)
    Ok(writer.finish())
  } catch {
    error => Err(checkpoint_error(error))
  }
}
