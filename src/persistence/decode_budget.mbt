///|
pub struct DecodeWorkspace {
  priv ticket : @budget.Ticket
  priv pool : @budget.Pool
  priv mut bytes : Int64
}

///|
pub fn DecodeWorkspace::new(
  pool : @budget.Pool,
  initial_bytes : Int64,
) -> Result[DecodeWorkspace, PersistenceError] {
  match pool.reserve(initial_bytes) {
    Err(_) =>
      Err(
        LimitExceeded(
          resource="snapshot-work-bytes",
          actual=initial_bytes,
          limit=pool.limit(),
        ),
      )
    Ok(ticket) => Ok({ ticket, pool, bytes: initial_bytes })
  }
}

///|
fn DecodeWorkspace::charge(
  self : DecodeWorkspace,
  cost : Int64,
) -> Unit raise PersistenceError {
  let extra = match @budget.checked_mul(cost, 4L) {
    Ok(n) => n
    Err(_) =>
      raise LimitExceeded(
        resource="snapshot-work-bytes",
        actual=cost,
        limit=self.pool.limit(),
      )
  }
  let bytes = match @budget.checked_add(self.bytes, extra) {
    Ok(n) => n
    Err(_) =>
      raise LimitExceeded(
        resource="snapshot-work-bytes",
        actual=cost,
        limit=self.pool.limit(),
      )
  }
  match self.ticket.replace([self.pool.allocation(bytes)]) {
    Err(_) =>
      raise LimitExceeded(
        resource="snapshot-work-bytes",
        actual=bytes,
        limit=self.pool.limit(),
      )
    Ok(_) => self.bytes = bytes
  }
}

///|
pub fn DecodeWorkspace::release(self : DecodeWorkspace) -> Unit {
  self.ticket.release().unwrap()
}

///|
priv struct DecodeBudget {
  limits : @budget.Limits
  workspace : DecodeWorkspace?
  totals : Map[String, Int64]
  per_session : Map[String, Int64]
  mut total : Int64
  mut session_state : Int64
}

///|
fn DecodeBudget::new(
  limits : @budget.Limits,
  workspace : DecodeWorkspace?,
) -> DecodeBudget {
  {
    limits,
    workspace,
    totals: Map([]),
    per_session: Map([]),
    total: 0L,
    session_state: 0L,
  }
}

///|
fn DecodeBudget::new_session(self : DecodeBudget) -> Unit {
  self.per_session.clear()
  self.session_state = 0L
}

///|
fn decode_cap(
  used : Int64,
  cost : Int64,
  limit : Int64,
  label : String,
) -> Unit raise PersistenceError {
  if cost < 0L || used > limit || cost > limit - used {
    raise LimitExceeded(
      resource=label,
      actual=if cost > 9223372036854775807L - used {
        9223372036854775807L
      } else {
        used + cost
      },
      limit~,
    )
  }
}

///|
fn DecodeBudget::charge(
  self : DecodeBudget,
  kind : String,
  cost : Int64,
) -> Unit raise PersistenceError {
  let (global_key, session_key, state) = match kind {
    "inflight" =>
      ("max_inflight_bytes_total", Some("max_inflight_bytes_per_session"), true)
    "pending" =>
      ("max_pending_bytes_total", Some("max_pending_bytes_per_session"), true)
    "inbound" => ("max_managed_bytes_total", None, true)
    "subscription" =>
      (
        "max_subscription_bytes_total",
        Some("max_subscription_bytes_per_session"),
        false,
      )
    "identity" => ("max_session_metadata_bytes_total", None, false)
    _ => ("max_retained_bytes_total", None, false)
  }
  let used = self.totals.get(kind).unwrap_or(0L)
  decode_cap(used, cost, self.limits.get(global_key), global_key)
  decode_cap(
    self.total,
    cost,
    self.limits.get("max_managed_bytes_total") -
    self.limits.get("control_reserve_bytes"),
    "managed-state-bytes",
  )
  if session_key is Some(key) {
    decode_cap(
      self.per_session.get(kind).unwrap_or(0L),
      cost,
      self.limits.get(key),
      key,
    )
  }
  if state {
    decode_cap(
      self.session_state,
      cost,
      self.limits.get("max_session_state_bytes"),
      "session-state-bytes",
    )
  }
  if kind == "pending" {
    decode_cap(
      0L,
      cost,
      self.limits.get("max_inflight_bytes_per_session"),
      "pending-must-fit-inflight",
    )
  }
  if kind == "retained" {
    decode_cap(
      0L,
      cost - 96L,
      self.limits.get("max_retained_message_bytes"),
      "retained-message-bytes",
    )
  }
  if self.workspace is Some(workspace) {
    workspace.charge(cost)
  }
  self.totals.set(kind, used + cost)
  self.total += cost
  self.per_session.set(kind, self.per_session.get(kind).unwrap_or(0L) + cost)
  if state {
    self.session_state += cost
  }
}

///|
fn BinaryReader::peek_u32(
  self : BinaryReader,
  relative : Int,
) -> Int raise PersistenceError {
  if relative < 0 || relative > self.remaining() - 4 {
    raise Truncated(
      offset=self.position(),
      needed=4,
      remaining=self.remaining(),
    )
  }
  let i = self.offset + relative
  let value = (self.data[i].to_uint() << 24) |
    (self.data[i + 1].to_uint() << 16) |
    (self.data[i + 2].to_uint() << 8) |
    self.data[i + 3].to_uint()
  if value > 2147483647U {
    raise LimitExceeded(
      resource="length",
      actual=2147483648L,
      limit=2147483647L,
    )
  }
  value.reinterpret_as_int()
}

///|
fn BinaryReader::peek_string_bytes(
  self : BinaryReader,
  relative? : Int = 0,
) -> Int raise PersistenceError {
  let length = self.peek_u32(relative)
  if length > 65535 {
    raise LimitExceeded(
      resource="string-bytes",
      actual=length.to_int64(),
      limit=65535L,
    )
  }
  if length > self.remaining() - relative - 4 {
    raise Truncated(
      offset=self.position(),
      needed=length,
      remaining=self.remaining(),
    )
  }
  length
}

///|
fn BinaryReader::peek_message_cost(
  self : BinaryReader,
  max_payload : Int,
) -> Int64 raise PersistenceError {
  let topic = self.peek_string_bytes()
  let payload = self.peek_u32(4 + topic)
  if payload > max_payload {
    raise LimitExceeded(
      resource="message-payload-bytes",
      actual=payload.to_int64(),
      limit=max_payload.to_int64(),
    )
  }
  if payload > self.remaining() - 8 - topic {
    raise Truncated(
      offset=self.position(),
      needed=payload,
      remaining=self.remaining(),
    )
  }
  topic.to_int64() + payload.to_int64() + 96L
}
