///|
priv struct IpAdmission {
  connect : @budget.Bucket
  auth : @budget.Bucket
  ingress : @budget.Bucket
  metadata : @budget.Ticket
  mut live : Int
  mut refs : Int
  mut last_ms : Int64
}

///|
priv struct AcceptedTransport {
  ip : IpAdmission
  control : @budget.Bucket
  metadata : @budget.Ticket
  mut registered : Bool
  mut released : Bool
}

///|
priv struct PublishAdmission {
  messages : @budget.Bucket
  bytes : @budget.Bucket
  metadata : @budget.Ticket
}

///|
pub struct AdmissionState {
  priv config : ServerConfig
  priv limits : @budget.Limits
  priv ledger : @budget.Ledger
  priv clock : () -> Int64
  priv ips : Map[String, IpAdmission]
  priv transports : Map[ConnectionId, AcceptedTransport]
  priv publishers : Map[@session.ClientId, PublishAdmission]
  priv connect : @budget.Bucket
  priv auth : @budget.Bucket
  priv ingress : @budget.Bucket
  priv publish_messages : @budget.Bucket
  priv publish_bytes : @budget.Bucket
  priv rejections : Map[String, Int64]
  priv mut live : Int
  priv mut cleanup_cursor : Int
}

///|
fn rate_bucket(
  limits : @budget.Limits,
  rate : String,
  burst : String,
  now : Int64,
) -> @budget.Bucket {
  @budget.Bucket::new(
    limits.get(rate),
    limits.get(burst),
    if now < 0L {
      0L
    } else {
      now
    },
  ).unwrap()
}

///|
fn AdmissionState::new(
  config : ServerConfig,
  ledger : @budget.Ledger,
  clock? : () -> Int64 = @budget.monotonic_ms,
) -> AdmissionState {
  let limits = config.broker_config().resources()
  let now = clock()
  {
    config,
    limits,
    ledger,
    clock,
    ips: Map([]),
    transports: Map([]),
    publishers: Map([]),
    rejections: Map([]),
    live: 0,
    cleanup_cursor: 0,
    connect: rate_bucket(
      limits, "connect_rate_total", "connect_burst_total", now,
    ),
    auth: rate_bucket(limits, "auth_rate_total", "auth_burst_total", now),
    ingress: rate_bucket(
      limits, "ingress_bytes_total", "ingress_bytes_burst_total", now,
    ),
    publish_messages: rate_bucket(
      limits, "publish_messages_total", "publish_messages_burst_total", now,
    ),
    publish_bytes: rate_bucket(
      limits, "publish_bytes_total", "publish_bytes_burst_total", now,
    ),
  }
}

///|
fn AdmissionState::rejected(self : AdmissionState, kind : String) -> Bool {
  let count = self.rejections.get(kind).unwrap_or(0L)
  self.rejections.set(
    kind,
    if count == 9223372036854775807L {
      count
    } else {
      count + 1L
    },
  )
  false
}

///|
fn AdmissionState::take_memory(
  self : AdmissionState,
  kind : @budget.ResourceKind,
  key : String,
  cost : Int64,
) -> @budget.Ticket? {
  let pool = self.ledger.pool(kind, self.limits.get(key)).unwrap()
  match pool.reserve(cost) {
    Err(_) => None
    Ok(t) => {
      t.commit().unwrap()
      Some(t)
    }
  }
}

///|
fn AdmissionState::accept(
  self : AdmissionState,
  id : ConnectionId,
  ip : String,
) -> Bool {
  let now = (self.clock)()
  if now < 0L ||
    self.live >= self.config.max_connections() ||
    self.transports.length() >= self.config.max_connections() ||
    self.transports.contains(id) {
    return self.rejected("connection")
  }
  if self.limits.rates_enabled() && self.connect.available_at(now) < 1L {
    return self.rejected("connect_rate")
  }
  self.cleanup_ips(now)
  let entry = match self.ips.get(ip) {
    Some(entry) => entry
    None => {
      if self.ips.length().to_int64() >= self.limits.get("max_ip_buckets") {
        return self.rejected("ip_table")
      }
      let metadata = match
        self.take_memory(
          LimiterMetadata,
          "max_limiter_metadata_bytes_total",
          512L,
        ) {
        Some(t) => t
        None => return self.rejected("memory")
      }
      let entry = IpAdmission::{
        connect: rate_bucket(
          self.limits,
          "connect_rate_per_ip",
          "connect_burst_per_ip",
          now,
        ),
        auth: rate_bucket(
          self.limits,
          "auth_rate_per_ip",
          "auth_burst_per_ip",
          now,
        ),
        ingress: rate_bucket(
          self.limits,
          "ingress_bytes_per_ip",
          "ingress_bytes_burst_per_ip",
          now,
        ),
        metadata,
        live: 0,
        refs: 0,
        last_ms: now,
      }
      self.ips.set(ip, entry)
      entry
    }
  }
  if self.limits.per_ip_enabled() &&
    entry.live.to_int64() >= self.limits.get("max_connections_per_ip") {
    return self.rejected("connection_ip")
  }
  if self.limits.rates_enabled() {
    let keys = [(self.connect, 1L)]
    if self.limits.per_ip_enabled() {
      keys.push((entry.connect, 1L))
    }
    if @budget.admit(keys, now) is Err(_) {
      return self.rejected("connect_rate")
    }
  }
  let metadata = match
    self.take_memory(
      ConnectionMetadata,
      "max_connection_metadata_bytes_total",
      512L,
    ) {
    Some(t) => t
    None => return self.rejected("memory")
  }
  self.transports.set(id, {
    ip: entry,
    metadata,
    control: rate_bucket(
      self.limits,
      "control_packets_per_connection",
      "control_packets_burst_per_connection",
      now,
    ),
    registered: false,
    released: false,
  })
  entry.live += 1
  entry.refs += 1
  entry.last_ms = now
  self.live += 1
  true
}

///|
fn AdmissionState::registered(self : AdmissionState, id : ConnectionId) -> Unit {
  if self.transports.get(id) is Some(record) {
    record.registered = true
  }
}

///|
fn AdmissionState::release(self : AdmissionState, id : ConnectionId) -> Unit {
  if self.transports.get(id) is Some(record) && !record.released {
    record.released = true
    record.metadata.release().unwrap()
    record.ip.live -= 1
    self.live -= 1
    record.ip.last_ms = (self.clock)()
    if !record.registered {
      self.forget(id)
    }
  }
}

///|
fn AdmissionState::forget(self : AdmissionState, id : ConnectionId) -> Unit {
  if self.transports.get(id) is Some(record) {
    if !record.released {
      self.release(id)
    }
    // release may already remove an unregistered record.
    if self.transports.contains(id) {
      record.ip.refs -= 1
      self.transports.remove(id)
    }
  }
}

///|
fn AdmissionState::admit_auth(self : AdmissionState, id : ConnectionId) -> Bool {
  if !self.limits.rates_enabled() {
    return true
  }
  let now = (self.clock)()
  let keys = [(self.auth, 1L)]
  if self.transports.get(id) is Some(record) {
    record.ip.last_ms = now
    if self.limits.per_ip_enabled() {
      keys.push((record.ip.auth, 1L))
    }
  }
  if @budget.admit(keys, now) is Err(_) {
    self.rejected("auth_rate")
  } else {
    true
  }
}

///|
fn AdmissionState::admit_ingress(
  self : AdmissionState,
  id : ConnectionId,
  bytes : Int64,
) -> Bool {
  if !self.limits.rates_enabled() {
    return true
  }
  let now = (self.clock)()
  let keys = [(self.ingress, bytes)]
  if self.transports.get(id) is Some(record) {
    record.ip.last_ms = now
    if self.limits.per_ip_enabled() {
      keys.push((record.ip.ingress, bytes))
    }
  }
  if @budget.admit(keys, now) is Err(_) {
    self.rejected("ingress_rate")
  } else {
    true
  }
}

///|
fn AdmissionState::admit_control(
  self : AdmissionState,
  id : ConnectionId,
) -> Bool {
  if !self.limits.rates_enabled() {
    return true
  }
  match self.transports.get(id) {
    Some(record) =>
      if @budget.admit([(record.control, 1L)], (self.clock)()) is Err(_) {
        self.rejected("control_rate")
      } else {
        true
      }
    None => true
  }
}

///|
fn AdmissionState::admit_publish(
  self : AdmissionState,
  id : @session.ClientId,
  bytes : Int64,
) -> Bool {
  if !self.limits.rates_enabled() {
    return true
  }
  let now = (self.clock)()
  let entry = match self.publishers.get(id) {
    Some(entry) => entry
    None => {
      let metadata = match
        self.take_memory(
          LimiterMetadata,
          "max_limiter_metadata_bytes_total",
          256L,
        ) {
        Some(t) => t
        None => return self.rejected("memory")
      }
      let entry = PublishAdmission::{
        messages: rate_bucket(
          self.limits,
          "publish_messages_per_session",
          "publish_messages_burst_per_session",
          now,
        ),
        bytes: rate_bucket(
          self.limits,
          "publish_bytes_per_session",
          "publish_bytes_burst_per_session",
          now,
        ),
        metadata,
      }
      self.publishers.set(id, entry)
      entry
    }
  }
  let keys = [
    (self.publish_messages, 1L),
    (self.publish_bytes, bytes),
    (entry.messages, 1L),
    (entry.bytes, bytes),
  ]
  if @budget.admit(keys, now) is Err(_) {
    self.rejected("publish_rate")
  } else {
    true
  }
}

///|
fn AdmissionState::prune_publishers(
  self : AdmissionState,
  state : @router.BrokerState,
) -> Unit {
  let removed : Array[@session.ClientId] = []
  for id, _ in self.publishers {
    if !state.has_session(id) {
      removed.push(id)
    }
  }
  for id in removed {
    self.publishers.get(id).unwrap().metadata.release().unwrap()
    self.publishers.remove(id)
  }
}

///|
fn AdmissionState::cleanup_ips(self : AdmissionState, now : Int64) -> Unit {
  if now < 0L || self.ips.is_empty() {
    return
  }
  let pool = self.ledger
    .pool(ControlWork, self.limits.get("control_reserve_bytes"))
    .unwrap()
  let scratch = match pool.reserve(self.ips.length().to_int64() * 16L) {
    Ok(t) => t
    Err(_) => return
  }
  defer scratch.release().unwrap()
  let keys = self.ips.keys().collect()
  let start = self.cleanup_cursor % keys.length()
  let count = if keys.length() < 32 { keys.length() } else { 32 }
  for step in 0..<count {
    let key = keys[(start + step) % keys.length()]
    let entry = self.ips.get(key).unwrap()
    if entry.refs == 0 &&
      entry.live == 0 &&
      now >= entry.last_ms &&
      now - entry.last_ms >= self.limits.get("idle_ttl_ms") &&
      entry.connect.full_at(now) &&
      entry.auth.full_at(now) &&
      entry.ingress.full_at(now) {
      entry.metadata.release().unwrap()
      self.ips.remove(key)
    }
  }
  self.cleanup_cursor = (start + count) % keys.length()
}

///|
fn AdmissionState::close(self : AdmissionState) -> Unit {
  for _, record in self.transports {
    if !record.released {
      record.metadata.release().unwrap()
    }
  }
  self.transports.clear()
  self.live = 0
  for _, entry in self.ips {
    entry.metadata.release().unwrap()
  }
  self.ips.clear()
  for _, entry in self.publishers {
    entry.metadata.release().unwrap()
  }
  self.publishers.clear()
}

///|
fn parse_hex_word(value : String) -> Int {
  let mut result = 0
  for character in value {
    let code = character.to_int()
    let digit = if code >= 48 && code <= 57 {
      code - 48
    } else if code >= 97 && code <= 102 {
      code - 87
    } else {
      -1
    }
    if digit < 0 || result > 4095 {
      return -1
    }
    result = result * 16 + digit
  }
  result
}

///|
fn canonical_ip(peer : @socket.Addr) -> String {
  let text = peer.to_string()
  if !peer.is_ipv6() {
    return text.split(":").to_array()[0].to_owned()
  }
  let address = text.split("]").to_array()[0].to_owned()
  let address = address[1:].to_owned()
  if address.has_prefix("::ffff:") {
    let tail = address[7:].to_owned()
    if tail.contains(".") {
      return tail
    }
    let words = tail.split(":").to_array()
    if words.length() == 2 {
      let a = parse_hex_word(words[0].to_owned())
      let b = parse_hex_word(words[1].to_owned())
      if a >= 0 && b >= 0 {
        return (a >> 8).to_string() +
          "." +
          (a & 255).to_string() +
          "." +
          (b >> 8).to_string() +
          "." +
          (b & 255).to_string()
      }
    }
  }
  address
}

///|
fn AdmissionState::reset_publisher(
  self : AdmissionState,
  id : @session.ClientId,
) -> Unit {
  if self.publishers.get(id) is Some(entry) {
    entry.metadata.release().unwrap()
    self.publishers.remove(id)
  }
}
