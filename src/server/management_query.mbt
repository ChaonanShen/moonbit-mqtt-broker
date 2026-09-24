///|
pub(all) struct ManagementConnectionView {
  connection_id : Int64
  phase : String
  client_id : String?
  principal : String?
  closing : Bool
} derive(Eq, Debug)

///|
/// Enable only after startup has reserved B index capacity and before accept.
pub fn RouterDriver::enable_management_connection_index(
  self : RouterDriver,
  max_connections : Int,
) -> Bool {
  if self.management_connections is Some(_) {
    return false
  }
  let index = @slot_index.SlotIndex::new(max_connections)
  for id, _ in self.sinks {
    if index.put(id.value().to_string()) is @slot_index.Full {
      self.management_connections_available = false
    }
  }
  self.management_connections = Some(index)
  self.management_connections_available
}

///|
pub fn RouterDriver::management_connection_index_available(
  self : RouterDriver,
) -> Bool {
  self.management_connections is Some(_) &&
  self.management_connections_available
}

///|
pub fn RouterDriver::management_connection_page(
  self : RouterDriver,
  start : Int,
  scan_limit : Int,
  limit : Int,
  accept : (ManagementConnectionView) -> Bool,
) -> @slot_index.SlotPage? {
  if !self.management_connection_index_available() {
    return None
  }
  let index = self.management_connections.unwrap()
  Some(
    index.page(start, scan_limit, limit, fn(key) {
      let id = @string.parse_int64(key) catch { _ => return false }
      match self.management_connection_view(id) {
        Some(view) => accept(view)
        None => false
      }
    }),
  )
}

///|
/// The index holds only ConnectionId strings. Live phase and principal come
/// from runtime at the single-writer read point.
pub fn RouterDriver::management_connection_view(
  self : RouterDriver,
  id : Int64,
) -> ManagementConnectionView? {
  if !self.management_connection_index_available() {
    return None
  }
  let connection_id = ConnectionId::new(id)
  if self.management_connections.unwrap().get(id.to_string()) is None {
    return None
  }
  let meta = match self.runtime.connections.get(connection_id) {
    Some(value) => value
    None => return None
  }
  let (phase, client_id) = match meta.phase {
    AwaitConnect => ("await_connect", None)
    Authenticating(_) => ("authenticating", None)
    Active(client_id) => ("active", Some(client_id.value()))
  }
  Some({
    connection_id: id,
    phase,
    client_id,
    principal: meta.principal.map(value => value.storage_value()),
    closing: self.management_closing.contains(connection_id),
  })
}

///|
fn management_query_error(
  status : @http_transport.HttpStatus,
  code : String,
) -> ManagementQueryReply {
  let error : Map[String, Json] = Map([("code", code.to_json())])
  let body : Map[String, Json] = Map([("error", error.to_json())])
  { status, body: @utf8.encode(body.to_json().stringify()) }
}

///|
fn management_session_json(
  view : @router.AdminSessionView,
  boot_id : String,
) -> Json {
  let row : Map[String, Json] = Map([
    ("handle", view.handle.to_string().to_json()),
    ("client_id", view.client_id.to_json()),
    ("mode", view.mode.to_json()),
    ("attached", view.attached.to_json()),
    ("lifecycle_version", view.lifecycle_version.to_string().to_json()),
    ("owner", view.owner.to_json()),
    ("detached_at_ms", @management.optional_decimal_json(view.detached_at_ms)),
    ("subscription_count", view.subscription_count.to_json()),
    ("inflight_count", view.inflight_count.to_json()),
    ("pending_count", view.pending_count.to_json()),
    ("inbound_qos2_count", view.inbound_qos2_count.to_json()),
    ("inflight_bytes", view.inflight_bytes.to_string().to_json()),
    ("pending_bytes", view.pending_bytes.to_string().to_json()),
    ("inbound_bytes", view.inbound_bytes.to_string().to_json()),
    ("subscription_bytes", view.subscription_bytes.to_string().to_json()),
    (
      "etag",
      @management.session_etag(boot_id, view.handle, view.lifecycle_version).to_json(),
    ),
  ])
  row.to_json()
}

///|
fn management_connection_json(
  view : ManagementConnectionView,
  boot_id : String,
) -> Json {
  let row : Map[String, Json] = Map([
    ("connection_id", view.connection_id.to_string().to_json()),
    ("boot_id", boot_id.to_json()),
    ("phase", view.phase.to_json()),
    ("client_id", @management.optional_string_json(view.client_id)),
    ("principal", @management.optional_string_json(view.principal)),
    ("closing", view.closing.to_json()),
    (
      "connection_etag",
      @management.connection_etag(boot_id, view.connection_id).to_json(),
    ),
  ])
  row.to_json()
}

///|
/// Exact byte length of a JSON string under the standard encoder's escaping
/// rules, before constructing a potentially large Json/String copy.
fn management_json_string_bytes(value : String) -> Int {
  let mut count = 2
  for byte in @utf8.encode(value) {
    let code = byte.to_int()
    if code == 34 ||
      code == 92 ||
      code == 8 ||
      code == 9 ||
      code == 10 ||
      code == 12 ||
      code == 13 {
      count += 2
    } else if code < 32 {
      count += 6
    } else {
      count += 1
    }
  }
  count
}

///|
fn management_row_key_too_large(
  kind : @management.QueryKind,
  key : String,
  state : @router.BrokerState,
  driver : RouterDriver,
  boot_id : String,
  max_bytes : Int,
) -> Bool {
  let size = match kind {
    @management.Connections => {
      let id = @string.parse_int64(key) catch { _ => return false }
      let view = match driver.management_connection_view(id) {
        Some(value) => value
        None => return false
      }
      let blank : ManagementConnectionView = {
        ..view,
        client_id: view.client_id.map(_ => ""),
        principal: view.principal.map(_ => ""),
      }
      let mut bytes = @utf8.encode(
        management_connection_json(blank, boot_id).stringify(),
      ).length()
      if view.client_id is Some(value) {
        bytes += management_json_string_bytes(value) - 2
      }
      if view.principal is Some(value) {
        bytes += management_json_string_bytes(value) - 2
      }
      bytes
    }
    @management.Sessions => {
      let handle = @string.parse_int64(key) catch { _ => return false }
      let view = match state.admin_session_view(handle) {
        Some(value) => value
        None => return false
      }
      let blank : @router.AdminSessionView = {
        ..view,
        client_id: "",
        owner: "",
      }
      @utf8.encode(management_session_json(blank, boot_id).stringify()).length() -
      4 +
      management_json_string_bytes(view.client_id) +
      management_json_string_bytes(view.owner)
    }
    @management.Subscriptions => {
      let view = match state.admin_subscription_view(key) {
        Some(value) => value
        None => return false
      }
      let blank : Map[String, Json] = Map([
        ("filter", "".to_json()),
        ("qos", "".to_json()),
      ])
      @utf8.encode(blank.to_json().stringify()).length() -
      4 +
      management_json_string_bytes(view.filter) +
      management_json_string_bytes(view.qos)
    }
    @management.Retained => {
      let view = match state.admin_retained_view(key) {
        Some(value) => value
        None => return false
      }
      let blank : Map[String, Json] = Map([
        ("topic", "".to_json()),
        ("qos", view.qos.to_json()),
        ("payload_bytes", view.payload_bytes.to_string().to_json()),
      ])
      @utf8.encode(blank.to_json().stringify()).length() -
      2 +
      management_json_string_bytes(view.topic)
    }
    _ => 0
  }
  size > max_bytes
}

///|
fn management_query_kind_name(kind : @management.QueryKind) -> String {
  match kind {
    Connections => "connections"
    Sessions => "sessions"
    Subscriptions => "subscriptions"
    Retained => "retained"
    _ => "detail"
  }
}

///|
fn RouterDriver::management_query_result(
  self : RouterDriver,
  spec : @management.QuerySpec,
  active : ManagementRuntime,
) -> ManagementQueryReply {
  let state = self.runtime.broker_state()
  let boot_id = active.context.boot_id
  if spec.kind == @management.Operation {
    if active.operations is None ||
      (!active.config.operations_enabled() && self.reload_service is None) {
      return management_query_error(
        @http_transport.ServiceUnavailable,
        "operations_disabled",
      )
    }
    let parts = spec.target.split(".").to_array()
    if parts.length() != 2 || parts[0].length() != 32 || parts[1] == "" {
      return management_query_error(@http_transport.BadRequest, "bad_request")
    }
    if parts[0] != boot_id {
      return management_query_error(
        @http_transport.Expired,
        "expired_operation",
      )
    }
    let sequence = @string.parse_int64(parts[1].to_owned()) catch {
      _ =>
        return management_query_error(@http_transport.BadRequest, "bad_request")
    }
    if sequence < 1L || sequence.to_string() != parts[1].to_owned() {
      return management_query_error(@http_transport.BadRequest, "bad_request")
    }
    let table = active.operations.unwrap()
    let record = match table.get(spec.target, spec.actor_token_id) {
      Some(value) => value
      None =>
        match table.get_internal(spec.target) {
          Some(value) if value.actor_token_id == "local_signal" &&
            active.http.tokens.token_has_scope(
              spec.actor_token_id,
              @management.ConfigAdmin,
            ) => value
          _ =>
            return management_query_error(@http_transport.NotFound, "not_found")
        }
    }
    if !active.config.operations_enabled() && record.kind != @management.Reload {
      return management_query_error(@http_transport.NotFound, "not_found")
    }
    let bytes = @utf8.encode(record.to_json().stringify())
    if bytes.length() > active.config.max_response_bytes() {
      return management_query_error(
        @http_transport.Unprocessable,
        "result_too_large",
      )
    }
    return { status: @http_transport.Ok, body: bytes }
  }
  if spec.kind == @management.Audit {
    if !active.config.operations_enabled() ||
      active.audit is None ||
      active.cursor_table is None {
      return management_query_error(
        @http_transport.ServiceUnavailable,
        "operations_disabled",
      )
    }
    let cursor_table = active.cursor_table.unwrap()
    let now = @budget.monotonic_ms()
    let after = match spec.cursor {
      None => 0L
      Some(cursor) =>
        match
          cursor_table.lookup(
            cursor,
            spec.actor_token_id,
            "audit",
            "",
            "",
            1L,
            now,
          ) {
          Ok(record) => record.audit_after_sequence.unwrap_or(0L)
          Err(@management.InvalidCursor) =>
            return management_query_error(
              @http_transport.BadRequest,
              "bad_request",
            )
          Err(@management.CursorForbidden) =>
            return management_query_error(
              @http_transport.Forbidden,
              "forbidden",
            )
          _ =>
            return management_query_error(
              @http_transport.Expired,
              "expired_cursor",
            )
        }
    }
    let page = active.audit
      .unwrap()
      .page(
        spec.actor_token_id,
        after,
        spec.limit,
        active.config.query_scan_limit(),
      )
    let items : Array[Json] = []
    let mut used = 256
    let mut next_after = page.next_after_sequence
    for item in page.items {
      let encoded = item.to_json()
      let bytes = @utf8.encode(encoded.stringify()).length()
      if used + bytes > active.config.max_response_bytes() {
        if items.is_empty() {
          return management_query_error(
            @http_transport.Unprocessable,
            "result_too_large",
          )
        }
        next_after = Some(item.sequence - 1L)
        break
      }
      items.push(encoded)
      used += bytes + 1
    }
    let next_cursor = if next_after is Some(sequence) {
      let record : @management.CursorRecord = {
        actor_token_id: spec.actor_token_id,
        route: "audit",
        filters: "",
        session_handle: "",
        next_slot: 0,
        audit_after_sequence: Some(sequence),
        index_generation: 1L,
        expires_monotonic_ms: 0L,
      }
      match cursor_table.issue(record, now) {
        Ok(value) => Some(value)
        Err(@management.CursorCapacity) =>
          return management_query_error(
            @http_transport.TooManyRequests,
            "capacity_exhausted",
          )
        _ =>
          return management_query_error(
            @http_transport.ServiceUnavailable,
            "unavailable",
          )
      }
    } else {
      None
    }
    let fields : Map[String, Json] = Map([
      ("api_version", "1".to_json()),
      ("boot_id", boot_id.to_json()),
      ("items", items.to_json()),
      ("next_cursor", @management.optional_string_json(next_cursor)),
      (
        "oldest_available_sequence",
        page.oldest_available_sequence.to_string().to_json(),
      ),
      ("audit_overwritten_total", page.overwritten_total.to_string().to_json()),
      ("gap", page.gap.to_json()),
      ("consistency", "per_page".to_json()),
    ])
    let bytes = @utf8.encode(fields.to_json().stringify())
    if bytes.length() > active.config.max_response_bytes() {
      return management_query_error(
        @http_transport.Unprocessable,
        "result_too_large",
      )
    }
    return { status: @http_transport.Ok, body: bytes }
  }
  if !active.config.details_enabled() ||
    !state.management_index_available() ||
    !self.management_connection_index_available() {
    return management_query_error(
      @http_transport.ServiceUnavailable,
      "details_unavailable",
    )
  }
  let index = state.management_index().unwrap()
  let max_bytes = active.config.max_response_bytes()
  let observed_at_ms = @async.now()
  let revision = state.snapshot_revision()
  if spec.kind == @management.Listeners {
    let items : Array[Json] = []
    let mqtt : Map[String, Json] = Map([
      ("id", "mqtt".to_json()),
      ("transport", "tcp".to_json()),
      ("address", active.mqtt_listener_address.to_json()),
      ("status", "listening".to_json()),
    ])
    let management : Map[String, Json] = Map([
      ("id", "management".to_json()),
      ("transport", "http".to_json()),
      ("address", active.config.listen().to_json()),
      ("status", "listening".to_json()),
    ])
    items.push(mqtt.to_json())
    items.push(management.to_json())
    return management_query_page_reply(
      boot_id,
      observed_at_ms,
      revision,
      items,
      None,
      max_bytes,
    )
  }
  if spec.kind == @management.Config {
    let config : Map[String, Json] = Map([
      ("api_version", "1".to_json()),
      ("boot_id", boot_id.to_json()),
      ("details_enabled", active.config.details_enabled().to_json()),
      ("operations_enabled", active.config.operations_enabled().to_json()),
      ("max_connections", self.runtime.config.max_connections().to_json()),
      ("max_sessions", state.config().max_sessions().to_json()),
      (
        "max_subscriptions_total",
        state.config().max_subscriptions_total().to_json(),
      ),
      (
        "max_retained_messages",
        state.config().max_retained_messages().to_json(),
      ),
      ("default_page_size", active.config.default_page_size().to_json()),
      ("max_page_size", active.config.max_page_size().to_json()),
      ("query_scan_limit", active.config.query_scan_limit().to_json()),
      ("max_response_bytes", max_bytes.to_json()),
    ])
    let bytes = @utf8.encode(config.to_json().stringify())
    if bytes.length() > max_bytes {
      return management_query_error(
        @http_transport.Unprocessable,
        "result_too_large",
      )
    }
    return { status: @http_transport.Ok, body: bytes }
  }
  if spec.kind == @management.Connection {
    let id = @string.parse_int64(spec.target) catch {
      _ =>
        return management_query_error(@http_transport.BadRequest, "bad_request")
    }
    let view = match self.management_connection_view(id) {
      Some(value) => value
      None =>
        return management_query_error(@http_transport.NotFound, "not_found")
    }
    if management_row_key_too_large(
        @management.Connections,
        spec.target,
        state,
        self,
        boot_id,
        max_bytes,
      ) {
      return management_query_error(
        @http_transport.Unprocessable,
        "result_too_large",
      )
    }
    let bytes = @utf8.encode(
      management_connection_json(view, boot_id).stringify(),
    )
    if bytes.length() > max_bytes {
      return management_query_error(
        @http_transport.Unprocessable,
        "result_too_large",
      )
    }
    return { status: @http_transport.Ok, body: bytes }
  }
  if spec.kind == @management.Session {
    let handle = @string.parse_int64(spec.target) catch {
      _ =>
        return management_query_error(@http_transport.BadRequest, "bad_request")
    }
    let view = match state.admin_session_view(handle) {
      Some(value) => value
      None =>
        return management_query_error(@http_transport.NotFound, "not_found")
    }
    if management_row_key_too_large(
        @management.Sessions,
        spec.target,
        state,
        self,
        boot_id,
        max_bytes,
      ) {
      return management_query_error(
        @http_transport.Unprocessable,
        "result_too_large",
      )
    }
    let bytes = @utf8.encode(management_session_json(view, boot_id).stringify())
    if bytes.length() > max_bytes {
      return management_query_error(
        @http_transport.Unprocessable,
        "result_too_large",
      )
    }
    return { status: @http_transport.Ok, body: bytes }
  }
  let route = management_query_kind_name(spec.kind)
  let session_handle = if spec.kind == @management.Subscriptions {
    spec.target
  } else {
    ""
  }
  let generation = index.generation()
  let cursor_table = match active.cursor_table {
    Some(value) => value
    None =>
      return management_query_error(
        @http_transport.ServiceUnavailable,
        "details_unavailable",
      )
  }
  let now = @budget.monotonic_ms()
  let start = match spec.cursor {
    None => 0
    Some(cursor) =>
      match
        cursor_table.lookup(
          cursor,
          spec.actor_token_id,
          route,
          spec.filters,
          session_handle,
          generation,
          now,
        ) {
        Ok(record) => record.next_slot
        Err(@management.InvalidCursor) =>
          return management_query_error(
            @http_transport.BadRequest,
            "bad_request",
          )
        Err(@management.CursorForbidden) =>
          return management_query_error(@http_transport.Forbidden, "forbidden")
        Err(@management.CursorMismatch) =>
          return management_query_error(
            @http_transport.BadRequest,
            "bad_request",
          )
        _ =>
          return management_query_error(
            @http_transport.Expired,
            "expired_cursor",
          )
      }
  }
  let page = match spec.kind {
    @management.Connections =>
      match
        self.management_connection_page(
          start,
          active.config.query_scan_limit(),
          spec.limit,
          fn(view) {
            spec.filters == "" || spec.filters == "phase=" + view.phase
          },
        ) {
        Some(value) => value
        None =>
          return management_query_error(
            @http_transport.ServiceUnavailable,
            "details_unavailable",
          )
      }
    @management.Sessions =>
      index.page(start, active.config.query_scan_limit(), spec.limit, fn(
        identity,
      ) {
        match state.admin_session_view(identity.handle) {
          None => false
          Some(view) =>
            spec.filters == "" ||
            spec.filters == "attached=" + view.attached.to_string() ||
            spec.filters == "mode=" + view.mode ||
            spec.filters ==
            "attached=" + view.attached.to_string() + "&mode=" + view.mode
        }
      })
    @management.Subscriptions => {
      let handle = @string.parse_int64(spec.target) catch {
        _ =>
          return management_query_error(
            @http_transport.BadRequest,
            "bad_request",
          )
      }
      let identity = match index.identity_for_handle(handle) {
        Some(value) => value
        None =>
          return management_query_error(
            if spec.cursor is Some(_) {
              @http_transport.Expired
            } else {
              @http_transport.NotFound
            },
            if spec.cursor is Some(_) {
              "expired_cursor"
            } else {
              "not_found"
            },
          )
      }
      index.subscription_page(
        identity.client_id,
        start,
        active.config.query_scan_limit(),
        spec.limit,
      )
    }
    @management.Retained =>
      index.retained_page(start, active.config.query_scan_limit(), spec.limit)
    _ => return management_query_error(@http_transport.NotFound, "not_found")
  }
  let items : Array[Json] = []
  let empty : @management.QueryEnvelope = {
    boot_id,
    observed_at_ms,
    state_revision: revision,
    items: [],
    next_cursor: None,
  }
  let base_without_cursor = @utf8.encode(empty.to_json().stringify()).length()
  let base_with_cursor = @utf8.encode(
    {
      ..empty,
      next_cursor: Some(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      ),
    }
    .to_json()
    .stringify(),
  ).length()
  let mut item_bytes = 0
  let mut next_slot = page.next_slot
  let mut has_more = page.has_more
  for offset in 0..<page.keys.length() {
    let key = page.keys[offset]
    if management_row_key_too_large(
        spec.kind,
        key,
        state,
        self,
        boot_id,
        max_bytes,
      ) {
      return management_query_error(
        @http_transport.Unprocessable,
        "result_too_large",
      )
    }
    let row : Json? = match spec.kind {
      @management.Connections => {
        let id = @string.parse_int64(key) catch { _ => continue }
        self
        .management_connection_view(id)
        .map(view => management_connection_json(view, boot_id))
      }
      @management.Sessions => {
        let handle = @string.parse_int64(key) catch { _ => continue }
        state
        .admin_session_view(handle)
        .map(view => management_session_json(view, boot_id))
      }
      @management.Subscriptions =>
        state
        .admin_subscription_view(key)
        .map(view => {
          let fields : Map[String, Json] = Map([
            ("filter", view.filter.to_json()),
            ("qos", view.qos.to_json()),
          ])
          fields.to_json()
        })
      @management.Retained =>
        state
        .admin_retained_view(key)
        .map(view => {
          let fields : Map[String, Json] = Map([
            ("topic", view.topic.to_json()),
            ("qos", view.qos.to_json()),
            ("payload_bytes", view.payload_bytes.to_string().to_json()),
          ])
          fields.to_json()
        })
      _ => None
    }
    if row is Some(value) {
      let size = @utf8.encode(value.stringify()).length()
      let comma = if items.length() > 0 { 1 } else { 0 }
      let needs_cursor = page.has_more || offset + 1 < page.keys.length()
      let base = if needs_cursor {
        base_with_cursor
      } else {
        base_without_cursor
      }
      if base + item_bytes + size + comma > max_bytes {
        if items.is_empty() {
          return management_query_error(
            @http_transport.Unprocessable,
            "result_too_large",
          )
        }
        next_slot = page.positions[offset]
        has_more = true
        break
      }
      items.push(value)
      item_bytes += size + comma
    }
  }
  let next_cursor = if has_more {
    let record : @management.CursorRecord = {
      actor_token_id: spec.actor_token_id,
      route,
      filters: spec.filters,
      session_handle,
      next_slot,
      audit_after_sequence: None,
      index_generation: generation,
      expires_monotonic_ms: 0L,
    }
    match cursor_table.issue(record, now) {
      Ok(value) => Some(value)
      Err(@management.CursorCapacity) =>
        return management_query_error(
          @http_transport.TooManyRequests,
          "capacity_exhausted",
        )
      _ =>
        return management_query_error(
          @http_transport.ServiceUnavailable,
          "unavailable",
        )
    }
  } else {
    None
  }
  management_query_page_reply(
    boot_id, observed_at_ms, revision, items, next_cursor, max_bytes,
  )
}

///|
fn management_query_page_reply(
  boot_id : String,
  observed_at_ms : Int64,
  revision : Int64,
  items : Array[Json],
  next_cursor : String?,
  max_bytes : Int,
) -> ManagementQueryReply {
  let page : @management.QueryEnvelope = {
    boot_id,
    observed_at_ms,
    state_revision: revision,
    items,
    next_cursor,
  }
  let bytes = @utf8.encode(page.to_json().stringify())
  if bytes.length() > max_bytes {
    management_query_error(@http_transport.Unprocessable, "result_too_large")
  } else {
    { status: @http_transport.Ok, body: bytes }
  }
}

///|
fn RouterDriver::handle_management_query(
  self : RouterDriver,
  event : ManagementQueryEvent,
) -> Unit {
  if self.management is Some(active) && active.query_mailbox is Some(mailbox) {
    if !mailbox.valid(event.ticket) {
      return
    }
    mailbox.produce(
      event.ticket,
      self.management_query_result(event.spec, active),
    )
  }
}
